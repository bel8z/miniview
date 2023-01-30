/// Provides the entire memory layout for the application (with the exception
/// of decoded images which are handled internally by GDI+)
const Memory = @This();

const std = @import("std");
const win32 = @import("win32.zig");
const assert = std.debug.assert;

//== Data ==//

// TODO (Matteo): 1GB should be enough, or not?
const capacity: usize = 1024 * 1024 * 1024;

bytes: [*]u8,

volatile_start: usize = 0,
volatile_end: usize = 0,

string_start: usize = capacity,

scratch_stack: usize = 0,

pub fn init() !Memory {
    // Allocate block
    var self = Memory{ .bytes = @ptrCast([*]u8, try win32.VirtualAlloc(
        null,
        capacity,
        win32.MEM_RESERVE,
        win32.PAGE_NOACCESS,
    )) };

    assert(std.mem.isAligned(@ptrToInt(self.bytes), std.mem.page_size));
    assert(std.mem.alignForward(self.volatile_end, std.mem.page_size) == 0);

    return self;
}

//=== Persistent ===//

/// Persistent allocation are kept at the bottom of the stack and never
/// freed, so they must be performed before any volatile  ones
pub fn persistentAlloc(self: *Memory, comptime T: type, count: usize) ![]T {
    if (self.volatile_end > self.volatile_start) return error.OutOfMemory;

    const mem = try self.alloc(T, count);
    self.volatile_start = self.volatile_end;

    return mem;
}

//=== Volatile ===//

pub fn clear(self: *Memory) void {
    assert(self.scratch_stack == 0);

    self.shrinkTo(self.volatile_start);

    if (self.string_start < capacity) {
        const string_commit = std.mem.alignBackward(self.string_start, std.mem.page_size);

        win32.VirtualFree(
            @ptrCast(win32.LPVOID, self.bytes + string_commit),
            capacity - string_commit,
            win32.MEM_DECOMMIT,
        );

        self.string_start = capacity;
    }
}

/// Volatile allocation
pub fn alloc(self: *Memory, comptime T: type, count: usize) ![]align(@alignOf(T)) T {
    return self.allocAlign(T, @alignOf(T), count);
}

/// Volatile aligned allocation
pub fn allocAlign(self: *Memory, comptime T: type, comptime alignment: u29, count: usize) ![]align(alignment) T {
    const size = count * @sizeOf(T);

    const mem_start = std.mem.alignForward(self.volatile_end, alignment);
    const mem_end = mem_start + size;

    const avail = self.string_start - mem_start;
    if (avail < size) return error.OutOfMemory;

    try self.commit(
        std.mem.alignForward(self.volatile_end, std.mem.page_size),
        std.mem.alignForward(mem_end, std.mem.page_size),
    );

    self.volatile_end = mem_end;

    assert(@divExact(mem_end - mem_start, @sizeOf(T)) == count);

    const ptr = @ptrCast([*]T, @alignCast(alignment, self.bytes + mem_start));
    return ptr[0..count];
}

/// Resize allocation, if top of the volatile stack
pub fn resize(self: *Memory, comptime T: type, mem: *[]T, count: usize) !void {
    if (!self.isLastAlloc(T, mem.*)) return error.NotLastAlloc;

    if (count < mem.len) {
        self.volatile_end -= @sizeOf(T) * (mem.len - count);
    } else {
        const size = @sizeOf(T) * (count - mem.len);
        const avail = self.string_start - self.volatile_end;
        if (avail < size) return error.OutOfMemory;

        const next_pos = self.volatile_end + size;

        try self.commit(
            std.mem.alignForward(self.volatile_end, std.mem.page_size),
            std.mem.alignForward(next_pos, std.mem.page_size),
        );

        self.volatile_end = next_pos;
    }

    mem.len = count;
}

pub fn isLastAlloc(self: *Memory, comptime T: type, mem: []T) bool {
    const size = mem.len * @sizeOf(T);
    return @ptrToInt(self.bytes + self.volatile_end) - size == @ptrToInt(mem.ptr);
}

//=== Strings ===//

/// Storage stack dedicated to variable length strings, grows from the bottom
/// of the memory block - this specialization is useful to allow the volatile
/// storage to be used for dynamic arrays of homogenous structs, and using
/// the minimum required space for strings
pub fn stringAlloc(self: *Memory, size: usize) ![]u8 {
    const avail = self.string_start - self.volatile_end;
    if (avail < size) return error.OutOfMemory;

    const end = self.string_start;
    const start = end - size;

    try self.commit(
        std.mem.alignBackward(start, std.mem.page_size),
        std.mem.alignBackward(end, std.mem.page_size),
    );

    self.string_start = start;
    return self.bytes[start..end];
}

//=== Scratch ===//

/// Helper struct used to handle temporary (scratch) usage of volatile allocations
const ScratchScope = struct { id: usize, pos: usize };

/// Begin temporary allocation scope (save the stack pointer)
pub fn beginScratch(self: *Memory) ScratchScope {
    self.scratch_stack += 1;
    return .{ .id = self.scratch_stack, .pos = self.volatile_end };
}

/// Complete temporary allocation scope (restore the stack pointer)
pub fn endScratch(self: *Memory, scope: ScratchScope) void {
    assert(scope.id == self.scratch_stack);
    assert(scope.id > 0);
    self.scratch_stack = scope.id - 1;
    // TODO (Matteo): Do not always decommit, I suspect that many syscalls can be
    // a problem for performance
    self.shrinkTo(scope.pos);
}

//=== Usage info ===//

pub inline fn persistentSize(self: *const Memory) usize {
    return self.volatile_start;
}

pub inline fn volatileSize(self: *const Memory) usize {
    return self.volatile_end - self.volatile_start;
}

pub inline fn stringSize(self: *const Memory) usize {
    return capacity - self.string_start;
}

pub inline fn committedSize(self: *const Memory) usize {
    const volatile_commit = std.mem.alignForward(self.volatile_end, std.mem.page_size);
    const string_commit = std.mem.alignBackward(self.string_start, std.mem.page_size);

    return volatile_commit + capacity - string_commit;
}

//=== Internals ===//

fn shrinkTo(self: *Memory, pos: usize) void {
    assert(pos <= self.volatile_end);

    // Decommit excess to catch rogue memory usage
    const curr_commit = std.mem.alignForward(self.volatile_end, std.mem.page_size);
    const next_commit = std.mem.alignForward(pos, std.mem.page_size);

    if (next_commit < curr_commit) {
        win32.VirtualFree(
            @ptrCast(win32.LPVOID, self.bytes + next_commit),
            curr_commit - next_commit,
            win32.MEM_DECOMMIT,
        );
    }

    self.volatile_end = pos;
}

fn commit(self: *Memory, low: usize, high: usize) !void {
    if (high > low) {
        _ = try win32.VirtualAlloc(
            @ptrCast(win32.LPVOID, self.bytes + low),
            high - low,
            win32.MEM_COMMIT,
            win32.PAGE_READWRITE,
        );
    }
}
