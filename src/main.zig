const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
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
    var buf = TempBuf(u8).init(&static.buf);

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

fn TempBuf(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Slice);
}

fn getWStr(buf: *TempBuf(u16)) [:0]const u16 {
    buf.writeItem(0) catch unreachable;
    const s = buf.readableSlice(0);
    return s[0 .. s.len - 1 :0];
}

fn formatWstr(buf: *TempBuf(u8), comptime fmt: []const u8, args: anytype) ![:0]const u16 {
    var w = buf.writer();

    try w.print(fmt, args);

    var alloc = std.heap.FixedBufferAllocator.init(buf.writableSlice(0));
    return std.unicode.utf8ToUtf16LeWithNull(
        alloc.allocator(),
        buf.readableSlice(0),
    );
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

    /// Provides the entire memory layout for the application (with the exception
    /// of decoded images which are handled internally by GDI+)
    const Memory = struct {
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
            assert(std.mem.isAligned(@ptrToInt(self.bytes), @alignOf(FileInfo)));

            const curr_commit = std.mem.alignForward(self.volatile_end, std.mem.page_size);
            assert(curr_commit == 0);

            return self;
        }

        pub fn clear(self: *Memory) void {
            assert(self.scratch_stack == 0);

            // Decommit excess to catch rogue memory usage
            const curr_commit = std.mem.alignForward(self.volatile_end, std.mem.page_size);
            const next_commit = std.mem.alignForward(self.volatile_start, std.mem.page_size);

            if (next_commit < curr_commit) {
                win32.VirtualFree(
                    @ptrCast(win32.LPVOID, self.bytes + next_commit),
                    curr_commit - next_commit,
                    win32.MEM_DECOMMIT,
                );
            }

            self.volatile_end = self.volatile_start;

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

        // Persistent allocation are kept at the bottom of the stack and never
        // freed, so they must be performed before any volatile  ones
        pub fn persistentAlloc(self: *Memory, comptime T: type, size: usize) ![]T {
            if (self.volatile_end > self.volatile_start) return error.OutOfMemory;

            _ = size;
            @compileError("Not implemented");
        }

        // Volatile allocation
        pub fn alloc(self: *Memory, comptime T: type, count: usize) ![]align(@alignOf(T)) T {
            return self.allocAlign(T, @alignOf(T), count);
        }

        pub fn allocAlign(self: *Memory, comptime T: type, comptime alignment: u29, count: usize) ![]align(alignment) T {
            const size = count * @sizeOf(T);

            const mem_start = std.mem.alignForward(self.volatile_end, alignment);
            const mem_end = mem_start + size;

            const avail = self.string_start - mem_start;
            if (avail < size) return error.OutOfMemory;

            const curr_commit = std.mem.alignForward(self.volatile_end, std.mem.page_size);
            const next_commit = std.mem.alignForward(mem_end, std.mem.page_size);

            if (next_commit > curr_commit) {
                _ = try win32.VirtualAlloc(
                    @ptrCast(win32.LPVOID, self.bytes + curr_commit),
                    next_commit - curr_commit,
                    win32.MEM_COMMIT,
                    win32.PAGE_READWRITE,
                );
            }

            self.volatile_end = mem_end;

            assert(@divExact(mem_end - mem_start, @sizeOf(T)) == count);

            const ptr = @ptrCast([*]T, @alignCast(alignment, self.bytes + mem_start));
            return ptr[0..count];
        }

        pub fn isLastAlloc(self: *Memory, comptime T: type, mem: []T) bool {
            const size = mem.len * @sizeOf(T);
            return @ptrToInt(self.bytes + self.volatile_end) - size == @ptrToInt(mem.ptr);
        }

        pub fn resize(self: *Memory, comptime T: type, mem: *[]T, count: usize) !void {
            if (!self.isLastAlloc(T, mem.*)) return error.NotLastAlloc;

            if (count < mem.len) {
                self.volatile_end -= @sizeOf(T) * (mem.len - count);
            } else {
                const size = @sizeOf(T) * (count - mem.len);
                const avail = self.string_start - self.volatile_end;
                if (avail < size) return error.OutOfMemory;

                const next_pos = self.volatile_end + size;
                const curr_commit = std.mem.alignForward(self.volatile_end, std.mem.page_size);
                const next_commit = std.mem.alignForward(next_pos, std.mem.page_size);

                if (next_commit > curr_commit) {
                    _ = try win32.VirtualAlloc(
                        @ptrCast(win32.LPVOID, self.bytes + curr_commit),
                        next_commit - curr_commit,
                        win32.MEM_COMMIT,
                        win32.PAGE_READWRITE,
                    );
                }

                self.volatile_end = next_pos;
            }

            mem.len = count;
        }

        // Storage stack dedicated to variable length strings, grows from the bottom
        // of the memory block - this specialization is useful to allow the volatile
        // storage to be used for dynamic arrays of homogenous structs, and using
        // the minimum required space for strings
        pub fn stringAlloc(self: *Memory, size: usize) ![]u8 {
            const avail = self.string_start - self.volatile_end;
            if (avail < size) return error.OutOfMemory;

            const end = self.string_start;
            const start = end - size;

            const curr_commit = std.mem.alignBackward(end, std.mem.page_size);
            const next_commit = std.mem.alignBackward(start, std.mem.page_size);

            if (next_commit < curr_commit) {
                _ = try win32.VirtualAlloc(
                    @ptrCast(win32.LPVOID, self.bytes + next_commit),
                    curr_commit - next_commit,
                    win32.MEM_COMMIT,
                    win32.PAGE_READWRITE,
                );
            }

            self.string_start = start;
            return self.bytes[start..end];
        }

        // TODO (Matteo): Improve temporary allocation
        fn getTempBuf(self: *Memory, comptime T: type) TempBuf(T) {
            const bytes = self.allocAlign(u8, @alignOf(T), 1024 * 1024) catch unreachable;
            return TempBuf(T).init(std.mem.bytesAsSlice(T, bytes));
        }
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

    pub fn main() anyerror!void {
        // Init memory block
        memory = try Memory.init();

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

        if (builtin.mode == .Debug) {
            var y: i32 = 0;
            y = debugText(pb, y, "Debug mode", .{});
            y = debugText(pb, y, "# files: {}", .{files.len});
            y = debugText(pb, y, "File size: {}", .{@sizeOf(FileInfo)});
            y = debugText(pb, y, "Persistent memory: {}", .{memory.volatile_start});
            y = debugText(pb, y, "Volatile memory: {}", .{memory.volatile_end - memory.volatile_start});
            y = debugText(pb, y, "String memory: {}", .{Memory.capacity - memory.string_start});
        }
    }

    fn debugText(pb: win32.PaintBuffer, y: i32, comptime fmt: []const u8, args: anytype) i32 {
        _ = win32.SetBkMode(pb.dc, .Transparent);

        var buf = memory.getTempBuf(u8);
        const text = formatWstr(&buf, fmt, args) catch return y;
        const text_len = @intCast(c_int, text.len);

        var cur_y = y + 1;
        _ = win32.ExtTextOutW(pb.dc, 1, cur_y, 0, null, text.ptr, text_len, null);

        var size: win32.SIZE = undefined;
        _ = win32.GetTextExtentPoint32W(pb.dc, text.ptr, text_len, &size);
        cur_y += size.cy;

        return cur_y;
    }

    fn load(win: win32.HWND, file_name_utf8: []const u8) !void {
        // TODO (Matteo): Avoid some UTF8 <=> UTF16 conversion?

        var buf = memory.getTempBuf(u16);

        // Prepend string for composing the title
        try buf.write(app_name);
        try buf.write(L(" - "));
        const offset = buf.readableLength();

        // Append filename
        const len = try std.unicode.utf8ToUtf16Le(buf.writableSlice(0), file_name_utf8);
        buf.update(len);

        const title = getWStr(&buf);
        const file_name = title[offset.. :0];

        assert(len == file_name.len);

        var new_image: *gdip.Image = undefined;
        if (gdip.createImageFromFile(file_name, &new_image) != 0) {
            try invalidFile(win, file_name);
        } else {
            try disposeImage();
            image = new_image;

            if (win32.InvalidateRect(win, null, win32.TRUE) == 0) return error.Unexpected;
            if (win32.setWindowText(win, title) == 0) return error.Unexpected;
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

    fn disposeImage() gdip.Error!void {
        if (image) |old_img| {
            try gdip.checkStatus(gdip.disposeImage(old_img));
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

    fn invalidFile(win: win32.HWND, file_name: [:0]const u16) gdip.Error!void {
        var buf = memory.getTempBuf(u16);
        try buf.write(L("Invalid image file: "));
        try buf.write(file_name);
        const msg = getWStr(&buf);
        _ = try win32.messageBox(win, msg, app_name, 0);
    }

    fn messageBox(win: ?win32.HWND, comptime fmt: []const u8, args: anytype) !void {
        var buf = memory.getTempBuf(u8);
        const out = try formatWstr(&buf, fmt, args);
        _ = try win32.messageBox(win, out, app_name, 0);
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
};

inline fn argb(a: u8, r: u8, g: u8, b: u8) u32 {
    return @intCast(u32, a) << 24 | @intCast(u32, r) << 16 |
        @intCast(u32, g) << 8 | b;
}

//=== GDI+ wrapper ===//

const gdip = struct {
    pub const Error = win32.Error || error{
        GenericError,
        InvalidParameter,
        OutOfMemory,
        ObjectBusy,
        InsufficientBuffer,
        NotImplemented,
        WrongState,
        Aborted,
        FileNotFound,
        ValueOverflow,
        AccessDenied,
        UnknownImageFormat,
        FontFamilyNotFound,
        FontStyleNotFound,
        NotTrueTypeFont,
        UnsupportedGdiplusVersion,
        GdiplusNotInitialized,
        PropertyNotFound,
        PropertyNotSupported,
        ProfileNotFound,
    };

    pub const InterpolationMode = enum(c_int) {
        Invalid = -1,
        Default = 0,
        LowQuality = 1,
        HighQuality = 2,
        Bilinear = 3,
        Bicubic = 4,
        NearestNeighbor = 5,
        HighQualityBilinear = 6,
        HighQualityBicubic = 7,
    };

    pub const Status = c_int;
    pub const Image = opaque {};
    pub const Graphics = opaque {};

    const WINGDIPAPI = win32.WINAPI;

    const GdiplusStartupInput = extern struct {
        GdiplusVersion: u32 = 1,
        DebugEventCallback: ?*anyopaque = null,
        SuppressBackgroundThread: bool = false,
        SuppressExternalCodecs: bool = false,
    };

    const GdiplusStartupOutput = struct {
        NotificationHook: ?*anyopaque,
        NotificationUnhook: ?*anyopaque,
    };

    const GdiplusStartup = *const fn (
        token: *win32.ULONG_PTR,
        input: *const GdiplusStartupInput,
        output: *GdiplusStartupOutput,
    ) callconv(WINGDIPAPI) Status;

    const GdipCreateBitmapFromFile = *const fn (
        filename: win32.LPCWSTR,
        image: **Image,
    ) callconv(WINGDIPAPI) Status;

    const GdipCreateBitmapFromStream = *const fn (
        stream: *win32.IStream,
        image: **Image,
    ) callconv(WINGDIPAPI) Status;

    const GdipDisposeImage = *const fn (image: *Image) callconv(WINGDIPAPI) Status;

    const GdipGetImageDimension = *const fn (
        image: *Image,
        width: *f32,
        height: *f32,
    ) callconv(WINGDIPAPI) Status;

    const GdipCreateFromHDC = *const fn (
        hdc: win32.HDC,
        graphics: **Graphics,
    ) callconv(WINGDIPAPI) Status;

    const GdipDeleteGraphics = *const fn (graphics: *Graphics) callconv(WINGDIPAPI) Status;
    const GdipGraphicsClear = *const fn (graphics: *Graphics, color: u32) callconv(WINGDIPAPI) Status;

    const GdipDrawImageRect = *const fn (
        graphics: *Graphics,
        image: *Image,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    ) callconv(WINGDIPAPI) Status;

    const GdipSetInterpolationMode = *const fn (
        graphics: *Graphics,
        mode: InterpolationMode,
    ) callconv(WINGDIPAPI) Status;

    var dll: win32.HMODULE = undefined;
    var token: win32.ULONG_PTR = 0;
    var createImageFromFile: GdipCreateBitmapFromFile = undefined;
    var createImageFromStream: GdipCreateBitmapFromStream = undefined;
    var disposeImage: GdipDisposeImage = undefined;
    var getImageDimension: GdipGetImageDimension = undefined;
    var createFromHDC: GdipCreateFromHDC = undefined;
    var deleteGraphics: GdipDeleteGraphics = undefined;
    var graphicsClear: GdipGraphicsClear = undefined;
    var drawImageRect: GdipDrawImageRect = undefined;
    var setInterpolationMode: GdipSetInterpolationMode = undefined;

    pub fn init() Error!void {
        dll = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse return error.Unexpected;
        createImageFromFile = try win32.loadProc(GdipCreateBitmapFromFile, "GdipCreateBitmapFromFile", dll);
        createImageFromStream = try win32.loadProc(GdipCreateBitmapFromStream, "GdipCreateBitmapFromStream", dll);
        disposeImage = try win32.loadProc(GdipDisposeImage, "GdipDisposeImage", dll);
        getImageDimension = try win32.loadProc(GdipGetImageDimension, "GdipGetImageDimension", dll);
        createFromHDC = try win32.loadProc(GdipCreateFromHDC, "GdipCreateFromHDC", dll);
        deleteGraphics = try win32.loadProc(GdipDeleteGraphics, "GdipDeleteGraphics", dll);
        graphicsClear = try win32.loadProc(GdipGraphicsClear, "GdipGraphicsClear", dll);
        drawImageRect = try win32.loadProc(GdipDrawImageRect, "GdipDrawImageRect", dll);
        setInterpolationMode = try win32.loadProc(GdipSetInterpolationMode, "GdipSetInterpolationMode", dll);

        const startup = try win32.loadProc(GdiplusStartup, "GdiplusStartup", dll);
        const input = GdiplusStartupInput{};
        var output: GdiplusStartupOutput = undefined;
        const status = startup(&token, &input, &output);
        try checkStatus(status);
    }

    inline fn checkStatus(status: Status) Error!void {
        switch (status) {
            0 => return,
            1 => return error.GenericError,
            2 => return error.InvalidParameter,
            3 => return error.OutOfMemory,
            4 => return error.ObjectBusy,
            5 => return error.InsufficientBuffer,
            6 => return error.NotImplemented,
            7 => return error.Unexpected,
            8 => return error.WrongState,
            9 => return error.Aborted,
            10 => return error.FileNotFound,
            11 => return error.ValueOverflow,
            12 => return error.AccessDenied,
            13 => return error.UnknownImageFormat,
            14 => return error.FontFamilyNotFound,
            15 => return error.FontStyleNotFound,
            16 => return error.NotTrueTypeFont,
            17 => return error.UnsupportedGdiplusVersion,
            18 => return error.GdiplusNotInitialized,
            19 => return error.PropertyNotFound,
            20 => return error.PropertyNotSupported,
            21 => return error.ProfileNotFound,
            else => return error.Unexpected,
        }
    }
};
