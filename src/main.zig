const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const Memory = @import("Memory.zig");

const L = win32.L;

const app_name = L("MiniView");

// TODO (Matteo):
// - Implement image cache
// - Implement async loading
// - Cleanup string management (UTF8 <=> UTF16)
// - Cleanup memory management
// - Cleanup panic handling and error reporting in general

//=== Infrastructure ===//

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below.
    app.main() catch unreachable;
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
            writer.print("\n\nGetLastError() =  {x}: {s}", .{
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
    _ = win32.messageBox(
        null,
        std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), buf.readableSlice(0)) catch unreachable,
        app_name,
        win32.MB_ICONERROR | win32.MB_OK,
    ) catch unreachable;

    // TODO (Matteo): Use ret_addr for better diagnostics
    _ = ret_addr;

    // Spinning required because the function is 'noreturn'
    while (builtin.mode == .Debug) @breakpoint();

    // Abort in non-debug builds.
    std.os.abort();
}

fn RingBuffer(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Slice);
}

//=== Actual application ===//

const app = struct {
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

    const FileInfo = struct {
        name: []u8,
    };

    const Command = enum(u32) {
        Open = 1,
    };

    var memory: Memory = undefined;

    var files: []FileInfo = &[_]FileInfo{};
    var file_index: usize = 0;

    var image: ?*gdip.Image = null;

    var debug_buf: []u8 = &[_]u8{};

    pub fn main() anyerror!void {
        // Init memory block
        memory = try Memory.init();

        if (builtin.mode == .Debug) {
            debug_buf = try memory.persistentAlloc(u8, 4096);
        }

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

        _ = try win32.registerClassEx(&win_class);

        // Init buffered painting
        try win32.initBufferedPaint();

        // Init GDI+
        try gdip.init();

        // Create window
        const menu = try win32.createMenu();
        try win32.appendMenu(
            menu,
            .{ .String = .{ .id = @enumToInt(Command.Open), .str = L("Open") } },
            0,
        );

        const win_flags = win32.WS_OVERLAPPEDWINDOW;
        const win = try win32.createWindowEx(
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

        // Handle command line
        {
            const args = win32.getArgs();
            defer win32.freeArgs(args);

            if (args.len > 1) {
                var path8: [max_path_size]u8 = undefined;
                const path16 = args[1][0..std.mem.len(args[1])];
                const len = try std.unicode.utf16leToUtf8(&path8, path16);

                try load(win, path8[0..len]);
                try updateFiles(path8[0..len]);
            }
        }

        // Main loop
        defer disposeImage() catch unreachable;

        var msg: win32.MSG = undefined;

        while (true) {
            win32.getMessage(&msg, null, 0, 0) catch |err| switch (err) {
                error.Quit => break,
                else => return err,
            };

            _ = win32.translateMessage(&msg);
            _ = win32.dispatchMessage(&msg);
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
            win32.defWindowProc(win, msg, wparam, lparam);
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
                const pb = try win32.beginBufferedPaint(win);
                defer win32.endBufferedPaint(win, pb) catch unreachable;

                // The background is not erased since the given brush is null
                assert(pb.ps.fErase == win32.TRUE);

                try paint(pb);
            },
            win32.WM_COMMAND => {
                if (wparam & 0xffff0000 == 0) {
                    const command = @intToEnum(Command, wparam & 0xffff);
                    switch (command) {
                        .Open => try open(win),
                    }
                }
            },
            win32.WM_KEYDOWN => {
                if ((wparam == 0x25 and browsePrev()) or (wparam == 0x27 and browseNext())) {
                    assert(files.len > 1);
                    const file = &files[file_index];
                    try load(win, file.name);
                }
            },
            else => return false,
        }

        return true;
    }

    fn paint(pb: win32.PaintBuffer) !void {
        var gfx: *gdip.Graphics = undefined;
        try gdip.checkStatus(gdip.createFromHDC(pb.dc, &gfx));
        defer gdip.checkStatus(gdip.deleteGraphics(gfx)) catch unreachable;

        try gdip.checkStatus(gdip.graphicsClear(gfx, 0xFFF0F0F0));

        if (image) |bmp| {
            // Compute dimensions
            const bounds = pb.ps.rcPaint;
            const bounds_w = @intToFloat(f32, bounds.right - bounds.left);
            const bounds_h = @intToFloat(f32, bounds.bottom - bounds.top);
            var img_w: f32 = undefined;
            var img_h: f32 = undefined;
            try gdip.checkStatus(gdip.getImageDimension(bmp, &img_w, &img_h));

            // Downscale out-of-bounds images
            var scale = std.math.min(bounds_w / img_w, bounds_h / img_h);
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

        if (builtin.mode == .Debug) debugInfo(pb);
    }

    fn disposeImage() gdip.Error!void {
        if (image) |old_img| {
            try gdip.checkStatus(gdip.disposeImage(old_img));
        }
    }

    fn open(win: win32.HWND) !void {
        var buf16 = [_]u16{0} ** max_path_size;
        var buf8 = [_]u8{0} ** (2 * max_path_size);

        var ptr = @ptrCast([*:0]u16, &buf16[0]);
        var ofn = win32.OPENFILENAMEW{
            .hwndOwner = win,
            .lpstrFile = ptr,
            .nMaxFile = @intCast(u32, buf16.len),
            .lpstrFilter = L("Image files\x00") ++ filter ++ L("\x00"),
        };

        if (try win32.getOpenFileName(&ofn)) {
            const len = try std.unicode.utf16leToUtf8(&buf8, buf16[0..std.mem.len(ptr)]);
            const path = buf8[0..len];

            try load(win, path);

            try updateFiles(path);
        }
    }

    fn load(win: win32.HWND, file_name: []const u8) !void {
        const scratch = memory.beginScratch();
        defer memory.endScratch(scratch);

        const file = try std.fs.openFileAbsolute(file_name, .{});
        defer file.close();

        const info = try file.metadata();
        const block = try memory.alloc(u8, info.size());
        _ = try file.readAll(block);

        var stream = try win32.createMemStream(block);
        var new_image: *gdip.Image = undefined;

        if (gdip.createImageFromStream(stream, &new_image) != 0) {
            try messageBox(win, "Invalid image file: {s}", .{file_name});
        } else {
            try disposeImage();
            image = new_image;

            // Build title by composing app name and file path
            var buf = RingBuffer(u16).init(try memory.alloc(u16, max_path_size));
            try buf.write(app_name);
            try buf.write(L(" - "));
            const len = try std.unicode.utf8ToUtf16Le(buf.writableSlice(0), file_name);
            buf.update(len);
            try buf.writeItem(0);

            const title = buf.readableSlice(0)[0 .. buf.readableLength() - 1 :0];

            if (win32.InvalidateRect(win, null, win32.TRUE) == 0) return error.Unexpected;
            if (win32.setWindowText(win, title) == 0) return error.Unexpected;
        }
    }

    pub fn updateFiles(path: []const u8) !void {
        // Clear current list
        files.len = 0;
        file_index = 0;
        memory.clear();

        // Split path in file and directory names
        const sep = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return error.InvalidPath;
        const dirname = path[0 .. sep + 1];
        const filename = path[sep + 1 ..];

        // Iterate
        var dir = try std.fs.openIterableDirAbsolute(dirname, .{});
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .File and isSupported(entry.name)) {
                const index = files.len;

                // Push file to the list
                if (index == 0) {
                    files = try memory.alloc(FileInfo, 1);
                } else {
                    try memory.resize(FileInfo, &files, index + 1);
                }

                assert(files.len == index + 1);

                // Update browse index
                if (std.mem.eql(u8, entry.name, filename)) file_index = index;

                // Copy full path
                var file = &files[index];
                file.name = try memory.stringAlloc(dirname.len + entry.name.len);

                std.mem.copy(u8, file.name[0..dirname.len], dirname);
                std.mem.copy(u8, file.name[dirname.len..], entry.name);
            }
        }
    }

    fn isSupported(filename: []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return false;
        const ext = filename[dot..filename.len];

        if (ext.len == 0) return false;

        assert(ext[ext.len - 1] != 0);

        for (extensions) |token| {
            if (std.ascii.eqlIgnoreCase(token, ext)) return true;
        }

        return false;
    }

    pub fn browsePrev() bool {
        if (files.len > 1) {
            file_index = if (file_index == 0) files.len - 1 else file_index - 1;
            return true;
        }
        return false;
    }

    pub fn browseNext() bool {
        if (files.len > 1) {
            file_index = if (file_index == files.len - 1) 0 else file_index + 1;
            return true;
        }
        return false;
    }

    fn messageBox(win: ?win32.HWND, comptime fmt: []const u8, args: anytype) !void {
        const scratch = memory.beginScratch();
        defer memory.endScratch(scratch);
        var buf = try memory.alloc(u8, 4096);

        const out = try formatWstr(buf, fmt, args);
        _ = try win32.messageBox(win, out, app_name, 0);
    }

    fn debugInfo(pb: win32.PaintBuffer) void {
        var y: i32 = 0;
        y = debugText(pb, y, debug_buf, "Debug mode", .{});
        y = debugText(pb, y, debug_buf, "# files: {}", .{files.len});
        y = debugText(pb, y, debug_buf, "Persistent memory: {}", .{memory.persistentSize()});
        y = debugText(pb, y, debug_buf, "Volatile memory: {}", .{memory.volatileSize()});
        y = debugText(pb, y, debug_buf, "String memory: {}", .{memory.stringSize()});
        y = debugText(pb, y, debug_buf, "Total committed memory: {}", .{memory.committedSize()});
        y = debugText(pb, y, debug_buf, "Scratch stack: {}", .{memory.scratch_stack});
    }

    fn debugText(pb: win32.PaintBuffer, y: i32, buf: []u8, comptime fmt: []const u8, args: anytype) i32 {
        _ = win32.SetBkMode(pb.dc, .Transparent);

        const text = formatWstr(buf, fmt, args) catch return y;
        const text_len = @intCast(c_int, text.len);

        var cur_y = y + 1;
        _ = win32.ExtTextOutW(pb.dc, 1, cur_y, 0, null, text.ptr, text_len, null);

        var size: win32.SIZE = undefined;
        _ = win32.GetTextExtentPoint32W(pb.dc, text.ptr, text_len, &size);
        cur_y += size.cy;

        return cur_y;
    }

    fn formatWstr(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]const u16 {
        const str = try std.fmt.bufPrint(buf, fmt, args);

        var alloc = std.heap.FixedBufferAllocator.init(buf[str.len..]);
        return std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), str);
    }
};

inline fn argb(a: u8, r: u8, g: u8, b: u8) u32 {
    return @intCast(u32, a) << 24 | @intCast(u32, r) << 16 |
        @intCast(u32, g) << 8 | b;
}
