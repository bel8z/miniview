const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const Memory = @import("Memory.zig");

const L = win32.L;

// TODO (Matteo):
// - Implement image cache
// - Implement async loading
// - Cleanup string management (UTF8 <=> UTF16)
// - Cleanup memory management
// - Cleanup panic handling and error reporting in general

//=== Constants ===//

const app_name = L("MiniView");

// TODO (Matteo): technically this should be win32.PATH_MAX_WIDE, which is
// 32767. This is quite large for static buffers, so we - temporarily - settle
// to a smaller limit
const max_path_size = 1024;

// NOTE (Matteo): This looks a bit strange but is a cool way to build the
// list of supported extensions and the dialog filter string at comptime
const filter = "*.bmp;*.png;*.jpg;*.jpeg;*.tiff";
const extensions = init: {
    comptime var temp: [5][]const u8 = undefined;
    comptime var tokens = std.mem.tokenize(u8, filter, ";*");
    comptime var index: usize = 0;
    inline while (tokens.next()) |token| {
        temp[index] = token;
        index += 1;
    }
    assert(index == temp.len);
    break :init temp;
};

// TODO (Matteo): Prefefetch asynchronously
const prefetch = false;

//=== Data structs ===//

fn RingBuffer(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Slice);
}

const ImageCache = struct {
    pub const Image = union(enum) { None, Loaded: *gdip.Image };
    pub const Handle = packed struct {
        idx: Int = 0,
        gen: Int = 0,

        pub inline fn toInt(handle: Handle) usize {
            return @as(usize, @bitCast(handle));
        }

        pub inline fn fromInt(int: usize) Handle {
            return @as(Handle, @bitCast(int));
        }
    };

    comptime {
        assert(@bitSizeOf(Handle) == @bitSizeOf(usize));
    }

    const Int = std.meta.Int(.unsigned, @divExact(@bitSizeOf(usize), 2));

    const Node = struct { gen: Int = 0, val: Image = .None };
    const Self = @This();
    const size: Int = 16;

    comptime {
        assert(std.math.isPowerOfTwo(size));
    }

    nodes: [size]Node = [_]Node{.{}} ** size,
    count: Int = 0,

    pub fn new(self: *Self) Handle {
        const idx = @atomicRmw(Int, &self.count, .Add, 1, .SeqCst) & (size - 1);

        var node = &self.nodes[idx];

        const handle = Handle{
            .idx = idx,
            .gen = if (node.gen == std.math.maxInt(Int)) 1 else node.gen + 1,
        };

        switch (node.val) {
            .Loaded => |ptr| gdip.checkStatus(gdip.disposeImage(ptr)) catch unreachable,
            else => {},
        }
        node.gen = handle.gen;
        node.val = .None;

        return handle;
    }

    pub fn get(self: *Self, handle: Handle) ?*Image {
        if (handle.gen == 0) return null;
        const node = &self.nodes[handle.idx];
        return if (node.gen == handle.gen) &node.val else null;
    }

    pub fn clear(self: *Self) void {
        for (&self.nodes) |*node| {
            switch (node.val) {
                .Loaded => |ptr| gdip.checkStatus(gdip.disposeImage(ptr)) catch unreachable,
                else => {},
            }
            node.val = .None;
            node.gen = 0;
        }
        self.count = 0;
    }
};

const FileInfo = struct {
    name: []u8,
    handle: ImageCache.Handle = .{},
};

const Command = enum(u32) {
    Open = 1,
};

//=== Application ===//

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below.
    innerMain() catch unreachable;
}

pub fn panic(err: []const u8, maybe_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // NOTE (Matteo): Custom panic handler that reports the error via message box
    // This is because win32 apps don't have an associated console by default,
    // so stderr "is not visible".

    const static = struct {
        // NOTE (Matteo): Kept static to allow for growing it without risk of smashing the stack
        var buf: [8192]u8 align(@alignOf(usize)) = undefined;
    };
    var buf = RingBuffer(u8).init(&static.buf);

    {
        var writer = buf.writer();
        writer.print("{s}", .{err}) catch unreachable;

        const win_err = win32.GetLastError();
        if (win_err != 0) {
            var buf_utf8: [win32.ERROR_SIZE]u8 = undefined;
            writer.print("\n\nGetLastError() =  0x{x}: {s}", .{
                win_err,
                win32.formatError(win_err, &buf_utf8) catch unreachable,
            }) catch unreachable;
        }

        if (maybe_trace) |trace| writer.print("\n{}", .{trace}) catch unreachable;
    }

    // TODO (Matteo): When text is going back and forth between Zig's stdlib and
    // Win32 a lot of UTF8<->UTF16 conversions are involved; maybe we can mitigate
    // this a bit by fully embracing Win32 and UTF16.
    var alloc = std.heap.FixedBufferAllocator.init(buf.writableSlice(0));
    _ = win32.messageBoxW(
        null,
        std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), buf.readableSlice(0)) catch unreachable,
        app_name,
        win32.MB_ICONERROR | win32.MB_OK,
    ) catch unreachable;

    // TODO (Matteo): Use ret_addr for better diagnostics
    _ = ret_addr;

    // NOTE (Matteo): This breaks in debug builds on Windows
    std.os.abort();
}

var main_mem: Memory = undefined;
var string_mem: Memory = undefined;

var images: *ImageCache = undefined;
var files = std.ArrayListUnmanaged(FileInfo){};
var curr_file: usize = 0;
var curr_image: ?*gdip.Image = null;

var iocp: win32.HANDLE = undefined;

var debug_buf: []u8 = &[_]u8{};

fn innerMain() anyerror!void {
    // Init memory block
    // TODO (Matteo): 1GB should be enough, right? Mind that on x86 Windows the
    // available address space should be 2GB, but reserving that much failed...
    const reserved = try Memory.rawReserve(1024 * 1024 * 1024);
    main_mem = Memory.fromReserved(reserved[0 .. reserved.len / 2]);
    string_mem = Memory.fromReserved(reserved[reserved.len / 2 ..]);

    // Allocate persistent data
    if (builtin.mode == .Debug) debug_buf = try main_mem.alloc(u8, 4096);
    images = try main_mem.allocOne(ImageCache);
    images.* = .{};

    // Create IO completion port for async file reading
    iocp = try win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, null, 0, 0);

    // Register window class
    const hinst = win32.getCurrentInstance();

    const win_class = win32.WNDCLASSEXW{
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .hInstance = hinst,
        .lpszClassName = app_name,
        // Default arrow
        .hCursor = win32.getDefaultCursor(),
        // Don't erase background
        .hbrBackground = null,
        // No icons available
        .hIcon = null,
        .hIconSm = null,
        // No menu
        .lpszMenuName = null,
    };

    _ = try win32.registerClassExW(&win_class);

    // Init buffered painting
    try win32.BufferedPaint.init();

    // Init GDI+
    try gdip.init();

    // Create window
    const menu = try win32.createMenu();
    try win32.appendMenu(
        menu,
        .{ .String = .{ .id = @intFromEnum(Command.Open), .str = L("Open") } },
        0,
    );

    const win_flags = win32.WS_OVERLAPPEDWINDOW;
    const win = try win32.createWindowExW(
        0,
        app_name,
        app_name,
        win_flags,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        menu,
        hinst,
        null,
    );

    _ = win32.showWindow(win, win32.SW_SHOWDEFAULT);
    try win32.updateWindow(win);

    win32.dragAcceptFiles(win, true);

    // Handle command line
    {
        const args = win32.getArgs();
        defer win32.freeArgs(args);
        if (args.len > 1) try loadFile(win, args[1][0..std.mem.len(args[1]) :0]);
    }

    // Main loop
    defer images.clear();

    var msg: win32.MSG = undefined;

    while (true) {
        win32.getMessageW(&msg, null, 0, 0) catch |err| switch (err) {
            error.Quit => break,
            else => return err,
        };

        _ = win32.translateMessage(&msg);
        _ = win32.dispatchMessageW(&msg);
    }
}

fn wndProc(
    win: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(win32.WINAPI) win32.LRESULT {
    return if (processEvent(win, msg, wparam, lparam) catch unreachable)
        0
    else
        win32.defWindowProcW(win, msg, wparam, lparam);
}

fn processEvent(
    win: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) !bool {
    _ = lparam;

    switch (msg) {
        win32.WM_CLOSE => try win32.destroyWindow(win),
        win32.WM_DESTROY => win32.PostQuitMessage(0),
        win32.WM_PAINT => {
            const pb = try win32.BufferedPaint.begin(win);
            defer pb.end() catch unreachable;

            // The background is not erased since the given brush is null
            assert(pb.ps.fErase == win32.TRUE);

            try paint(pb.dc, pb.ps.rcPaint);
        },
        win32.WM_COMMAND => {
            if (wparam & 0xffff0000 == 0) {
                const command = @as(Command, @enumFromInt(wparam & 0xffff));
                switch (command) {
                    .Open => try open(win),
                }
            }
        },
        win32.WM_KEYDOWN => {
            const file_count = files.items.len;
            if (file_count < 2) return false;
            switch (wparam) {
                0x25 => curr_file = if (curr_file == 0) file_count - 1 else curr_file - 1, // Prev
                0x27 => curr_file = if (curr_file == file_count - 1) 0 else curr_file + 1, // Next
                else => return false,
            }

            try updateImage(win);
        },
        win32.WM_DROPFILES => {
            const drop: win32.HDROP = @ptrFromInt(wparam);
            defer win32.dragFinish(drop);

            var buf: [4096]u16 = undefined;
            const name = win32.dragQueryFile(drop, 0, &buf);
            try loadFile(win, name);

            return true;
        },
        else => return false,
    }

    return true;
}

fn paint(dc: win32.HDC, rect: win32.RECT) !void {
    var gfx: *gdip.Graphics = undefined;
    try gdip.checkStatus(gdip.createFromHDC(dc, &gfx));
    defer gdip.checkStatus(gdip.deleteGraphics(gfx)) catch unreachable;

    try gdip.checkStatus(gdip.graphicsClear(gfx, 0xFFF0F0F0));

    if (curr_image) |bmp| {
        // Compute dimensions
        const bounds = rect;
        const bounds_w = @as(f32, @floatFromInt(bounds.right - bounds.left));
        const bounds_h = @as(f32, @floatFromInt(bounds.bottom - bounds.top));
        var img_w: f32 = undefined;
        var img_h: f32 = undefined;
        try gdip.checkStatus(gdip.getImageDimension(bmp, &img_w, &img_h));

        // Downscale out-of-bounds images
        var scale = @min(bounds_w / img_w, bounds_h / img_h);
        if (scale < 1) {
            // Bicubic interpolation displays better results when downscaling
            try gdip.checkStatus(gdip.setInterpolationMode(gfx, .HighQualityBicubic));
        } else {
            // No upscaling and no interpolation
            scale = 1;
            try gdip.checkStatus(gdip.setInterpolationMode(gfx, .NearestNeighbor));
        }

        // Draw
        const draw_w = scale * img_w;
        const draw_h = scale * img_h;

        try gdip.checkStatus(gdip.drawImageRect(
            gfx,
            bmp,
            0.5 * (bounds_w - draw_w),
            0.5 * (bounds_h - draw_h),
            draw_w,
            draw_h,
        ));
    }

    if (builtin.mode == .Debug) debugInfo(dc);
}

/// Build title by composing app name and file path
fn setTitle(win: win32.HWND, file_name: []const u8) !void {
    const scratch = main_mem.beginScratch();
    defer main_mem.endScratch(scratch);

    const buf_size = app_name.len + file_name.len + 16;

    var buf = RingBuffer(u16).init(try main_mem.alloc(u16, buf_size));
    try buf.write(app_name);
    try buf.write(L(" - "));
    const len = try std.unicode.utf8ToUtf16Le(buf.writableSlice(0), file_name);
    buf.update(len);
    try buf.writeItem(0);

    const title = buf.readableSlice(0)[0 .. buf.readableLength() - 1 :0];

    if (!win32.setWindowText(win, title)) return error.Unexpected;
}

fn open(win: win32.HWND) !void {
    var buf16 = [_]u16{0} ** max_path_size;

    var ptr = @as([*:0]u16, @ptrCast(&buf16[0]));
    var ofn = win32.OPENFILENAMEW{
        .hwndOwner = win,
        .lpstrFile = ptr,
        .nMaxFile = @as(u32, @intCast(buf16.len)),
        .lpstrFilter = L("Image files\x00") ++ filter ++ L("\x00"),
    };

    if (try win32.getOpenFileName(&ofn)) {
        images.clear(); // Wipe cache
        try loadFile(win, ptr[0..std.mem.len(ptr) :0]);
    }
}

fn loadFile(win: win32.HWND, wpath: [:0]const u16) !void {
    var buf: [2 * max_path_size]u8 = undefined;
    const len = try std.unicode.utf16leToUtf8(&buf, wpath);
    const path = buf[0..len];

    if (!isSupported(path)) {
        try messageBox(win, "File not supported: {s}", .{path});
        return;
    }

    // Clear current list
    files.clearRetainingCapacity();
    curr_file = 0;
    assert(main_mem.scratch_stack == 0);

    // String storage is used only for the file list, so we can clear it as well
    string_mem.clear();

    // Split path in file and directory names
    const sep = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return error.InvalidPath;
    const dirname = path[0 .. sep + 1];
    const filename = path[sep + 1 ..];

    // Iterate
    var dir = try std.fs.openIterableDirAbsolute(dirname, .{});
    defer dir.close();

    var allocator = main_mem.allocator();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and isSupported(entry.name)) {
            // Push file to the list
            var file = try files.addOne(allocator);

            // Copy full path
            file.* = .{ .name = try string_mem.alloc(u8, dirname.len + entry.name.len) };

            std.mem.copy(u8, file.name[0..dirname.len], dirname);
            std.mem.copy(u8, file.name[dirname.len..], entry.name);

            // Update browse index
            const index = files.items.len - 1;
            if (std.mem.eql(u8, entry.name, filename)) curr_file = index;
        }
    }

    try updateImage(win);
}

fn updateImage(win: win32.HWND) !void {
    const file_count = files.items.len;
    if (file_count == 0) return;

    assert(curr_file >= 0);

    const file_name = files.items[curr_file].name;

    curr_image = loadInCache(curr_file) catch |err| switch (err) {
        error.InvalidParameter => {
            try messageBox(win, "Invalid image file: {s}", .{file_name});
            return;
        },
        else => return err,
    };

    if (!win32.invalidateRect(win, null, true)) return error.Unexpected;
    // try setTitle(win, file_name);

    // TODO (Matteo): Prefefetch asynchronously
    if (prefetch) {
        const prev_file = if (curr_file == 0) file_count - 1 else curr_file - 1;
        const next_file = if (curr_file == file_count - 1) 0 else curr_file + 1;
        _ = loadInCache(next_file) catch {};
        _ = loadInCache(prev_file) catch {};
    }
}

fn loadInCache(index: usize) !*gdip.Image {
    const file = &files.items[index];

    while (true) {
        if (images.get(file.handle)) |cached| {
            switch (cached.*) {
                .None => {
                    const image = try loadImageFile(file.name);
                    cached.* = .{ .Loaded = image };
                    return image;
                },
                .Loaded => |image| return image,
            }

            break;
        }

        file.handle = images.new();
    }
}

fn loadImageFile(file_name: []const u8) !*gdip.Image {
    const wide_path = try win32.sliceToPrefixedFileW(file_name);

    const file = win32.kernel32.CreateFileW(
        wide_path.span(),
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (file == win32.INVALID_HANDLE_VALUE) return error.Unexpected;

    defer win32.CloseHandle(file);

    // Read all file in a temporary block
    const scratch = main_mem.beginScratch();
    defer main_mem.endScratch(scratch);
    const size = @as(usize, @intCast(try win32.GetFileSizeEx(file)));
    const block = try main_mem.alloc(u8, size);

    // Emulate asyncronous read
    var ovp_in = std.mem.zeroInit(win32.OVERLAPPED, .{});
    var ovp_out: ?*win32.OVERLAPPED = undefined;
    var bytes: u32 = undefined;
    var key: usize = undefined;
    _ = try win32.CreateIoCompletionPort(file, iocp, 0, 0);
    if (win32.kernel32.ReadFile(
        file,
        block.ptr,
        @as(u32, @intCast(size)),
        null,
        &ovp_in,
    ) == 0) {
        const err = win32.GetLastError();
        switch (err) {
            997 => {}, // ERROR_IO_PENDING
            else => {
                // Restore error code and fail
                win32.SetLastError(err);
                return error.Unexpected;
            },
        }
    }
    switch (win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &ovp_out, win32.INFINITE)) {
        .Normal => {},
        else => return error.Unexpected,
    }
    assert(bytes == size);

    var new_image: *gdip.Image = undefined;
    const status = gdip.createImageFromStream(
        try win32.createMemStream(block),
        &new_image,
    );
    try gdip.checkStatus(status);

    return new_image;
}

fn isSupported(filename: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return false;
    const ext = filename[dot..filename.len];

    if (ext.len == 0) return false;

    assert(ext[ext.len - 1] != 0);

    for (extensions, 0..) |token, index| {
        _ = index;
        if (std.ascii.eqlIgnoreCase(token, ext)) return true;
    }

    return false;
}

fn messageBox(win: ?win32.HWND, comptime fmt: []const u8, args: anytype) !void {
    const scratch = main_mem.beginScratch();
    defer main_mem.endScratch(scratch);
    var buf = try main_mem.alloc(u8, 4096);

    const out = try formatWstr(buf, fmt, args);
    _ = try win32.messageBoxW(win, out, app_name, 0);
}

fn debugInfo(dc: win32.HDC) void {
    var y: i32 = 0;

    const total_commit = main_mem.commit_pos + string_mem.commit_pos;
    const total_used = main_mem.alloc_pos + string_mem.alloc_pos;

    y = debugText(dc, y, debug_buf, "Debug mode", .{});
    y = debugText(dc, y, debug_buf, "# files: {}", .{files.items.len});
    y = debugText(dc, y, debug_buf, "Memory usage", .{});
    y = debugText(dc, y, debug_buf, "   Total: {}", .{total_commit});
    y = debugText(dc, y, debug_buf, "      Committed: {}", .{total_commit});
    y = debugText(dc, y, debug_buf, "      Used: {}", .{total_used});
    y = debugText(dc, y, debug_buf, "      Waste: {}", .{total_commit - total_used});
    y = debugText(dc, y, debug_buf, "   Main:", .{});
    y = debugText(dc, y, debug_buf, "      Committed: {}", .{main_mem.commit_pos});
    y = debugText(dc, y, debug_buf, "      Used: {}", .{main_mem.alloc_pos});
    y = debugText(dc, y, debug_buf, "      Waste: {}", .{main_mem.commit_pos - main_mem.alloc_pos});
    y = debugText(dc, y, debug_buf, "   String", .{});
    y = debugText(dc, y, debug_buf, "      Committed: {}", .{string_mem.commit_pos});
    y = debugText(dc, y, debug_buf, "      Used: {}", .{string_mem.alloc_pos});
    y = debugText(dc, y, debug_buf, "      Waste: {}", .{string_mem.commit_pos - string_mem.alloc_pos});
}

fn debugText(dc: win32.HDC, y: i32, buf: []u8, comptime fmt: []const u8, args: anytype) i32 {
    _ = win32.SetBkMode(dc, .Transparent);

    const text = formatWstr(buf, fmt, args) catch return y;
    const text_len = @as(c_int, @intCast(text.len));

    var cur_y = y + 1;
    _ = win32.ExtTextOutW(dc, 1, cur_y, 0, null, text.ptr, text_len, null);

    var size: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32W(dc, text.ptr, text_len, &size);
    cur_y += size.cy;

    return cur_y;
}

fn formatWstr(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]const u16 {
    const str = try std.fmt.bufPrint(buf, fmt, args);

    var alloc = std.heap.FixedBufferAllocator.init(buf[str.len..]);
    return std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), str);
}

inline fn argb(a: u8, r: u8, g: u8, b: u8) u32 {
    return @as(u32, @intCast(a)) << 24 | @as(u32, @intCast(r)) << 16 |
        @as(u32, @intCast(g)) << 8 | b;
}
