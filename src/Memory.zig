/// Provides the entire memory layout for the application (with the exception
/// of decoded images which are handled internally by GDI+)
const Memory = @This();

const std = @import("std");
const win32 = @import("win32.zig");
const assert = std.debug.assert;
const safety = std.debug.runtime_safety;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

//== Data ==//

bytes: []u8,
alloc_pos: usize = 0,
commit_pos: usize = 0,
scratch_stack: usize = 0,

pub inline fn rawReserve(capacity: usize) win32.VirtualAllocError![]u8 {
    const bytes = @as([*]u8, @ptrCast(try win32.VirtualAlloc(
        null,
        capacity,
        win32.MEM_RESERVE,
        win32.PAGE_NOACCESS,
    )))[0..capacity];

    assert(std.mem.isAligned(@intFromPtr(bytes.ptr), std.mem.page_size));

    return bytes;
}

pub inline fn rawCommit(buf: []u8) win32.VirtualAllocError!void {
    const src = @as(win32.LPVOID, @ptrCast(buf.ptr));
    const dst = try win32.VirtualAlloc(src, buf.len, win32.MEM_COMMIT, win32.PAGE_READWRITE);
    assert(src == dst);
}

pub inline fn rawDecommit(buf: []u8) void {
    win32.VirtualFree(@as(win32.LPVOID, @ptrCast(buf.ptr)), buf.len, win32.MEM_DECOMMIT);
}

pub inline fn rawRelease(buf: []u8) void {
    win32.VirtualFree(@as(win32.LPVOID, @ptrCast(buf.ptr)), buf.len, win32.MEM_RELEASE);
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
    if (safety) self.decommitExcess();
}

pub fn decommitExcess(self: *Memory) void {
    const done = self.adjustCommitted(self.alloc_pos);
    assert(done);
}

fn adjustCommitted(self: *Memory, target: usize) bool {
    const min_commit = std.mem.alignForward(usize, target, std.mem.page_size);

    if (min_commit > self.commit_pos) {
        const buf = self.bytes[self.commit_pos..min_commit];
        rawCommit(buf) catch return false;
    } else if (min_commit < self.commit_pos) {
        const buf = self.bytes[min_commit..self.commit_pos];
        rawDecommit(buf);
    }

    self.commit_pos = min_commit;
    return true;
}

pub inline fn allocator(self: *Memory) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = allocImpl,
            .resize = resizeImpl,
            .free = freeImpl,
        },
    };
}

pub inline fn allocOne(self: *Memory, comptime T: type) Error!*T {
    return self.allocator().create(T);
}

pub inline fn alloc(self: *Memory, comptime T: type, count: usize) Error![]T {
    return self.allocator().alloc(T, count);
}

pub inline fn isLastAllocation(self: *Memory, mem: []u8) bool {
    return (self.bytes.ptr + self.alloc_pos) == (mem.ptr + mem.len);
}

inline fn selfCast(ptr: *anyopaque) *Memory {
    return @as(*Memory, @ptrCast(@alignCast(ptr)));
}

fn allocAlign(
    self: *Memory,
    size: usize,
    ptr_align: usize,
) ?[*]u8 {
    if (std.mem.alignPointerOffset(self.bytes.ptr + self.alloc_pos, ptr_align)) |offset| {
        const mem_start = self.alloc_pos + offset;
        const mem_end = mem_start + size;
        if (mem_end <= self.bytes.len and self.adjustCommitted(mem_end)) {
            self.alloc_pos = mem_end;
            return self.bytes.ptr + mem_start;
        }
    }

    return null;
}

inline fn free(self: *Memory, buf: []u8) bool {
    return self.resize(buf, 0);
}

fn resize(self: *Memory, buf: []u8, new_size: usize) bool {
    if (!self.isLastAllocation(buf)) return (new_size <= buf.len);

    if (new_size <= buf.len) {
        const sub = buf.len - new_size;
        self.alloc_pos -= sub;
        if (safety) self.decommitExcess();
        return true;
    }

    const next_pos = self.alloc_pos + new_size - buf.len;
    if (next_pos <= self.bytes.len and self.adjustCommitted(next_pos)) {
        self.alloc_pos = next_pos;
        return true;
    }

    return false;
}

fn allocImpl(
    ptr: *anyopaque,
    size: usize,
    ptr_align_log2: u8,
    return_address: usize,
) ?[*]u8 {
    _ = return_address;
    const ptr_align = @as(usize, 1) << @as(Allocator.Log2Align, @intCast(ptr_align_log2));
    return selfCast(ptr).allocAlign(size, ptr_align);
}

fn resizeImpl(
    ptr: *anyopaque,
    buf: []u8,
    ptr_align_log2: u8,
    new_size: usize,
    return_address: usize,
) bool {
    _ = ptr_align_log2;
    _ = return_address;
    return selfCast(ptr).resize(buf, new_size);
}

fn freeImpl(
    ptr: *anyopaque,
    buf: []u8,
    ptr_align_log2: u8,
    return_address: usize,
) void {
    _ = ptr_align_log2;
    _ = return_address;
    _ = selfCast(ptr).free(buf);
}

/// Helper struct used to handle temporary (scratch) usage of volatile allocations
pub const ScratchScope = struct { id: usize, pos: usize };

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
    self.alloc_pos = scope.pos;
    if (safety) self.decommitExcess();
}
