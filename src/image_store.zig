const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const Memory = @import("Memory.zig");
const L = win32.L;

/// Result of a load request, use to access a stored image
pub const Handle = packed struct {
    idx: Int = 0, // Index is valid only if gen > 0
    gen: Int = 0, // Generation identifier, 0 means null handle.

    pub inline fn toInt(handle: Handle) usize {
        return @as(usize, @bitCast(handle));
    }

    pub inline fn fromInt(int: usize) Handle {
        return @as(Handle, @bitCast(int));
    }
};

/// Represent a stored image
pub const Image = union(enum) {
    None,
    Pending: struct { file: win32.HANDLE, block: []u8 },
    Canceled: win32.HANDLE,
    Loaded: *gdip.Image,
};

/// Loads and stores a fixed number of images.
/// Image slots are recycled, do not hold reference to an image but use 'Handle'
/// instead.
/// Loading may happen asynchronously; the state is reflected by the 'Image' union
pub const ImageStore = @This();

nodes: [size]Node = [_]Node{.{}} ** size,
count: Int = 0,
mutex: std.Thread.Mutex = .{},
thread: std.Thread,
iocp: win32.HANDLE,
pending: Int = 0,
main_id: u32,
arena: Memory,
scope: Memory.ScratchScope = undefined,

const size: Int = 16;

const Int = std.meta.Int(.unsigned, @divExact(@bitSizeOf(usize), 2));

const Node = struct {
    gen: Int = 0,
    val: Image = .None,
    ovp: win32.OVERLAPPED,
};

comptime {
    assert(@bitSizeOf(Handle) == @bitSizeOf(usize));
}

pub fn init(self: *ImageStore) !void {
    self.* = .{
        .iocp = try win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, null, 0, 0),
        .thread = try std.Thread.spawn(.{}, threadFn, self),
        .main_id = win32.kernel32.GetCurrentThreadId(),
    };
}

pub fn request(self: *ImageStore, file_name: []const u8) Handle {
    _ = file_name;

    for (self.nodes) |*node| {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = node;
    }

    return .{};
}

pub fn get(self: *ImageStore, handle: Handle) ?*gdip.Image {
    if (handle.gen != 0) {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node = &self.nodes[handle.idx];
        if (node.gen == handle.gen) {
            switch (node.val) {
                .Loaded => |image| return image,
                else => {},
            }
        }
    }

    return null;
}

pub fn clear(self: *ImageStore) void {
    for (self.nodes) |*node| {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (node.val) {
            .Loaded => |image| gdip.checkStatus(gdip.disposeImage(image)) catch unreachable,
            .Pending => |data| node.val = .Canceled{data.file},
            .None => {},
            else => unreachable,
        }
    }

    while (self.pending > 0) {
        // NOTE (Matteo): This should not spin too much
        self.process(1);
    }
}

fn process(self: *ImageStore, timeout_ms: u32) void {
    var ovp: ?*win32.OVERLAPPED = undefined;
    var bytes: u32 = undefined;
    var key: usize = undefined;

    switch (win32.GetQueuedCompletionStatus(self.iocp, &bytes, &key, &ovp, timeout_ms)) {
        .Normal => {},
        else => unreachable,
    }

    self.mutex.lock();
    defer self.mutex.unlock();

    var node = @fieldParentPtr(Node, "ovp", ovp orelse unreachable);

    switch (node.val) {
        .Pending => |data| {
            defer win32.CloseHandle(data.file);

            assert(data.block.len == bytes);

            if (loadImage(data.block)) |image| {
                node.val = .Loaded{image};
            } else {
                node.val = .None;
            }
        },
        .Canceled => |file| {
            win32.CloseHandle(file);
            node.val = .None;
        },
        else => return,
    }

    self.pending -= 1;
    if (self.pending == 0) {
        self.arena.endScratch(self.scope);
    }
}

fn loadImage(block: []u8) !*gdip.Image {
    var new_image: *gdip.Image = undefined;

    const status = gdip.createImageFromStream(
        try win32.createMemStream(block),
        &new_image,
    );
    try gdip.checkStatus(status);

    return new_image;
}

fn threadFn(self: *ImageStore) void {
    while (true) {
        self.process(win32.INFINITE);
        postMessage(self.main_id);
    }
}

fn postMessage(thread_id: u32) void {
    _ = thread_id;
    @compileError("Not implemented");
}
