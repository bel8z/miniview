/// Provides the entire memory layout for the application (with the exception
/// of decoded images which are handled internally by GDI+)
const Memory = @This();

const std = @import("std");
const win32 = @import("win32.zig");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

//== Data ==//

bytes: []u8,
alloc_pos: usize = 0,
commit_pos: usize = 0,
scratch_stack: usize = 0,

pub fn rawReserve(capacity: usize) win32.VirtualAllocError![]u8 {
    const bytes = @ptrCast([*]u8, try win32.VirtualAlloc(
        null,
        capacity,
        win32.MEM_RESERVE,
        win32.PAGE_NOACCESS,
    ))[0..capacity];

    assert(std.mem.isAligned(@ptrToInt(bytes.ptr), std.mem.page_size));

    return bytes;
}

pub fn reserve(capacity: usize) win32.VirtualAllocError!Memory {
    return fromReserved(try rawReserve(capacity));
}

pub fn fromReserved(buf: []u8) Memory {
    return Memory{ .bytes = buf };
}

pub fn fromCommitted(buf: []u8) Memory {
    return Memory{ .bytes = buf, .commit_pos = buf.len };
}

pub fn clear(self: *Memory) void {
    assert(self.scratch_stack == 0);
    self.alloc_pos = 0;
}

pub fn decommitExcess(self: *Memory) void {
    const min_commit = std.mem.alignForward(self.alloc_pos, std.mem.page_size);

    if (min_commit < self.commit_pos) {
        win32.VirtualFree(
            @ptrCast(win32.LPVOID, self.bytes.ptr + min_commit),
            self.commit_pos - min_commit,
            win32.MEM_DECOMMIT,
        );

        self.commit_pos = min_commit;
    }
}

pub inline fn allocator(self: *Memory) Allocator {
    return Allocator.init(self, allocAlign, resize, free);
}

pub inline fn allocOne(self: *Memory, comptime T: type) Error!*T {
    return self.allocator().create(T);
}

pub inline fn alloc(self: *Memory, comptime T: type, count: usize) Error![]T {
    return self.allocator().alloc(T, count);
}

pub fn allocAlign(
    self: *Memory,
    size: usize,
    buf_align: u29,
    len_align: u29,
    return_address: usize,
) ![]u8 {
    _ = len_align;
    _ = return_address;

    const offset = std.mem.alignPointerOffset(self.bytes.ptr + self.alloc_pos, buf_align) orelse
        return error.OutOfMemory;

    const mem_start = self.alloc_pos + offset;
    const mem_end = mem_start + size;
    if (mem_end > self.bytes.len) return error.OutOfMemory;

    try self.commitVolatile(mem_end);
    self.alloc_pos = mem_end;

    return self.bytes[mem_start..mem_end];
}

pub inline fn isLastAllocation(self: *Memory, mem: []u8) bool {
    return (self.bytes.ptr + self.alloc_pos) == (mem.ptr + mem.len);
}

pub fn resize(
    self: *Memory,
    buf: []u8,
    buf_align: u29,
    new_size: usize,
    len_align: u29,
    return_address: usize,
) ?usize {
    _ = buf_align;
    _ = return_address;

    if (!self.isLastAllocation(buf)) {
        if (new_size > buf.len) return null;
        return std.mem.alignAllocLen(buf.len, new_size, len_align);
    }

    if (new_size <= buf.len) {
        const sub = buf.len - new_size;
        self.alloc_pos -= sub;
        return std.mem.alignAllocLen(new_size, new_size, len_align);
    }

    const add = new_size - buf.len;
    const next_pos = self.alloc_pos + add;
    if (next_pos > self.bytes.len) return null;
    self.commitVolatile(next_pos) catch return null;

    self.alloc_pos = next_pos;
    return new_size;
}

pub fn free(
    self: *Memory,
    buf: []u8,
    buf_align: u29,
    return_address: usize,
) void {
    _ = buf_align;
    _ = return_address;

    if (self.isLastAllocation(buf)) {
        self.alloc_pos -= buf.len;
    }
}

/// Helper struct used to handle temporary (scratch) usage of volatile allocations
const ScratchScope = struct { id: usize, pos: usize };

/// Begin temporary allocation scope (save the stack pointer)
pub fn beginScratch(self: *Memory) ScratchScope {
    self.scratch_stack += 1;
    return .{ .id = self.scratch_stack, .pos = self.alloc_pos };
}

/// Complete temporary allocation scope (restore the stack pointer)
pub fn endScratch(self: *Memory, scope: ScratchScope) void {
    assert(scope.id == self.scratch_stack);
    assert(scope.id > 0);
    self.scratch_stack = scope.id - 1;
    // TODO (Matteo): Decommit in debug builds?
    self.alloc_pos = scope.pos;
}

fn commitVolatile(self: *Memory, target: usize) Error!void {
    const min_commit = std.mem.alignForward(target, std.mem.page_size);

    if (min_commit > self.commit_pos) {
        _ = win32.VirtualAlloc(
            @ptrCast(win32.LPVOID, self.bytes.ptr + self.commit_pos),
            min_commit - self.commit_pos,
            win32.MEM_COMMIT,
            win32.PAGE_READWRITE,
        ) catch return error.OutOfMemory;

        self.commit_pos = min_commit;
    }
}
