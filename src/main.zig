const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
const L = win32.L;

const app_name = L("MiniView");

//=== Infrastructure ===//

// NOTE (Matteo): Kept static to allow for growing it without risk of smashing the stack
var temp_buffer: [8192]u8 align(@alignOf(usize)) = undefined;

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below.
    app.main() catch unreachable;
}

pub fn panic(err: []const u8, maybe_trace: ?*std.builtin.StackTrace) noreturn {
    // NOTE (Matteo): Custom panic handler that reports the error via message box
    // This is because win32 apps don't have an associated console by default,
    // so stderr "is not visible".
    var stream = std.io.fixedBufferStream(&temp_buffer);
    var w = stream.writer();

    w.print("{s}", .{err}) catch unreachable;

    const win_err = win32.GetLastError();
    if (win_err != 0) {
        var buf_utf8: [win32.ERROR_SIZE]u8 = undefined;
        w.print("\n\nGetLastError() =  {x}: {s}", .{
            win_err,
            win32.formatError(win_err, &buf_utf8) catch unreachable,
        }) catch unreachable;
    }

    if (maybe_trace) |trace| {
        w.print("\n{}", .{trace}) catch unreachable;
    }

    // TODO (Matteo): When text is going back and forth between Zig's stdlib and
    // Win32 a lot of UTF8<->UTF16 conversions are involved; maybe we can mitigate
    // this a bit by fully embracing Win32 and UTF16.
    var alloc = std.heap.FixedBufferAllocator.init(
        temp_buffer[stream.getPos() catch unreachable ..],
    );
    _ = win32.messageBoxW(
        null,
        std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), stream.getWritten()) catch unreachable,
        app_name,
        win32.MB_ICONERROR | win32.MB_OK,
    ) catch unreachable;

    // Spinning required because the function is 'noreturn'
    while (builtin.mode == .Debug) @breakpoint();

    // Abort in non-debug builds.
    std.os.abort();
}

//=== Actual application ===//

const extensions = L("*.bmp;*.png;*.jpg;*.jpeg;*.tiff");

fn List(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,
        committed_bytes: usize,

        const Self = @This();

        pub fn init() !Self {
            const size = 1024 * 1024 * 1024;
            const alignment = @alignOf(T);

            const ptr = try win32.VirtualAlloc(
                null,
                size,
                win32.MEM_RESERVE,
                win32.PAGE_NOACCESS,
            );

            if (!std.mem.isAligned(@ptrToInt(ptr), alignment)) return error.MisalignedAddress;

            var self: Self = undefined;
            self.capacity = size / @sizeOf(T);
            self.committed_bytes = 0;
            self.items.ptr = @ptrCast([*]FileInfo, @alignCast(alignment, ptr));
            self.items.len = 0;

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.capacity = 0;
            self.committed_bytes = 0;
            win32.VirtualFree(@ptrCast(win32.LPVOID, self.items.ptr), 0, win32.MEM_RELEASE);
        }

        pub fn clear(self: *Self) void {
            self.items.len = 0;
        }

        pub fn add(self: *Self, item: T) !void {
            const request = self.items.len + 1;

            if (self.capacity < request) return error.OutOfMemory;

            const to_commit = std.mem.alignForward(request * @sizeOf(T), std.mem.page_size);

            if (to_commit > self.committed_bytes) {
                assert(to_commit <= self.capacity * @sizeOf(T));

                _ = try win32.VirtualAlloc(
                    @intToPtr(win32.LPVOID, @ptrToInt(self.items.ptr) + self.committed_bytes),
                    to_commit - self.committed_bytes,
                    win32.MEM_COMMIT,
                    win32.PAGE_READWRITE,
                );

                self.committed_bytes = to_commit;
            }

            self.items.len = request;
            self.items[request - 1] = item;
        }
    };
}

const FileInfo = struct {
    buf: [win32.MAX_PATH]u16,
    len: usize,

    fn init(file_name: *const [win32.MAX_PATH]u16) FileInfo {
        var self: FileInfo = undefined;

        self.len = std.mem.indexOfScalar(u16, file_name, 0) orelse unreachable;
        assert(self.len <= self.buf.len);

        std.mem.copy(u16, self.buf[0..self.len], file_name[0..self.len]);
        assert(self.buf[self.len - 1] != 0);

        return self;
    }

    fn name(self: FileInfo) []const u16 {
        return self.buf[0..self.len];
    }

    fn supported(self: FileInfo) !bool {
        const dot = std.mem.lastIndexOfScalar(u16, self.buf[0..self.len], '.') orelse return false;
        const ext = self.buf[dot..self.len];

        if (ext.len == 0) return false;

        assert(ext[ext.len - 1] != 0);

        // TODO (Matteo): Store tokens at startup
        var tokens = std.mem.tokenize(u16, extensions, L(";*"));
        while (tokens.next()) |token| {
            if (token.len == ext.len) {
                const cmp = try win32.compareStringOrdinal(ext, token, true);
                if (cmp == .eq) return true;
            }
        }

        return false;
    }
};

const app = struct {
    const Command = enum(u32) {
        Open = 1,
    };

    const extensions = L("*.bmp;*.png;*.jpg;*.jpeg;*.tiff");

    var image: ?*gdip.Image = null;
    var dir_buffer: [256:0]u16 = undefined;
    var dir_len: usize = 0;
    var files: List(FileInfo) = undefined;
    var file_index: usize = 0;

    pub fn main() anyerror!void {
        // Init memory block
        files = try List(FileInfo).init();
        defer files.deinit();

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
        try win32.initBufferedPaint();
        defer win32.deinitBufferedPaint();

        // Init GDI+
        try gdip.init();
        defer gdip.deinit();

        // Create window
        const menu = try win32.createMenu();
        try win32.appendMenu(
            menu,
            .{ .String = .{ .id = @enumToInt(Command.Open), .str = L("Open") } },
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

        // Handle command line
        {
            const args = win32.getArgs();
            defer win32.freeArgs(args);
            if (args.len > 1) {
                const filename = args[1][0..std.mem.len(args[1]) :0];
                try load(win, filename);
            }
        }

        // Main loop
        defer disposeImage() catch unreachable;

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
                const count = files.items.len;

                if (count > 1) {
                    if (wparam == 0x25) {
                        file_index = if (file_index == 0) count - 1 else file_index - 1;
                    } else if (wparam == 0x27) {
                        file_index = if (file_index == count - 1) 0 else file_index + 1;
                    }

                    const name = files.items[file_index].name();
                    const full_len = name.len + dir_len;

                    std.mem.copy(u16, dir_buffer[dir_len..], name);
                    dir_buffer[full_len] = 0;

                    const full_name = dir_buffer[0..full_len :0];

                    try load(win, full_name);
                }
            },
            else => return false,
        }

        return true;
    }

    fn paint(pb: win32.PaintBuffer) gdip.Error!void {
        var gfx: *gdip.Graphics = undefined;
        try gdip.checkStatus(gdip.createFromHDC(pb.dc, &gfx));
        defer gdip.checkStatus(gdip.deleteGraphics(gfx)) catch unreachable;

        try gdip.checkStatus(gdip.graphicsClear(gfx, 0xff000000));

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
    }

    fn load(win: win32.HWND, file_name: [:0]u16) gdip.Error!void {
        var new_image: *gdip.Image = undefined;
        if (gdip.createImageFromFile(file_name, &new_image) != 0) {
            try invalidFile(win, file_name);
        } else {
            try disposeImage();
            image = new_image;

            if (win32.InvalidateRect(win, null, win32.TRUE) == 0) return error.Unexpected;

            const buf = std.mem.bytesAsSlice(u16, &temp_buffer);
            const sep = L(" - ");
            std.mem.copy(u16, buf[0..], app_name);
            std.mem.copy(u16, buf[app_name.len..], sep);
            std.mem.copy(u16, buf[app_name.len + sep.len ..], file_name);
            buf[app_name.len + sep.len + file_name.len] = 0;
            const title = buf[0 .. app_name.len + sep.len + file_name.len :0];

            if (win32.SetWindowTextW(win, title) == 0) return error.Unexpected;
        }
    }

    fn open(win: win32.HWND) !void {
        var ofn = win32.OPENFILENAMEW{
            .hwndOwner = win,
            .lpstrFile = &dir_buffer,
            .nMaxFile = dir_buffer.len,
            .lpstrFilter = L("Image files\x00") ++ extensions ++ L("\x00"),
        };

        if (try win32.getOpenFileName(&ofn)) {
            const path = dir_buffer[0..std.mem.len(&dir_buffer) :0];
            try load(win, path);
            try updateFiles(path);
        }
    }

    fn updateFiles(path: [:0]u16) !void {
        dir_len = std.mem.lastIndexOfScalar(u16, path, '\\') orelse return error.InvalidPath;

        // Account for the final separator
        dir_len += 1;

        // Split path in file and directory names
        const dirname = path[0..dir_len];
        const filename = path[dir_len.. :0];

        // Copy directory name in find pattern
        var pattern: [1024]u16 = undefined;
        if (dirname.len > pattern.len - 16) return error.PathTooLong;
        assert(dirname[dir_len - 1] == '\\');
        std.mem.copy(u16, pattern[0..], dirname);

        // Append wildcard to pattern and null terminate
        const suffix = L("\\*");
        const pattern_len = dir_len + suffix.len;
        std.mem.copy(u16, pattern[dir_len..], suffix[0..]);
        pattern[pattern_len] = 0;

        // Iterate
        var data: win32.WIN32_FIND_DATAW = undefined;
        const find_str = pattern[0..pattern_len :0];
        const find = win32.kernel32.FindFirstFileW(find_str, &data);
        if (find == win32.INVALID_HANDLE_VALUE) return error.Unexpected;

        while (true) {
            if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) {
                const file = FileInfo.init(&data.cFileName);

                _ = filename;
                if (try file.supported()) {
                    try files.add(file);

                    if (std.mem.eql(u16, file.name(), filename)) {
                        file_index = files.items.len - 1;
                    }
                }
            }

            if (win32.kernel32.FindNextFileW(find, &data) == win32.FALSE) break;
        }
    }

    fn disposeImage() gdip.Error!void {
        if (image) |old_img| {
            try gdip.checkStatus(gdip.disposeImage(old_img));
        }
    }

    fn invalidFile(win: win32.HWND, file_name: [:0]u16) gdip.Error!void {
        const buf = std.mem.bytesAsSlice(u16, &temp_buffer);

        const base = L("Invalid image file: ");
        std.mem.copy(u16, buf[0..], base);
        std.mem.copy(u16, buf[base.len..], file_name);
        buf[base.len + file_name.len] = 0;

        const msg = buf[0 .. base.len + file_name.len :0];
        _ = try win32.messageBoxW(win, msg, app_name, 0);
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

    const GdiplusStartup = fn (
        token: *win32.ULONG_PTR,
        input: *const GdiplusStartupInput,
        output: *GdiplusStartupOutput,
    ) callconv(WINGDIPAPI) Status;

    const GdiplusShutdown = fn (token: win32.ULONG_PTR) callconv(WINGDIPAPI) Status;

    const GdipCreateBitmapFromFile = fn (
        filename: win32.LPCWSTR,
        image: **Image,
    ) callconv(WINGDIPAPI) Status;

    const GdipCreateBitmapFromStream = fn (
        stream: *win32.IStream,
        image: **Image,
    ) callconv(WINGDIPAPI) Status;

    const GdipDisposeImage = fn (image: *Image) callconv(WINGDIPAPI) Status;

    const GdipGetImageDimension = fn (
        image: *Image,
        width: *f32,
        height: *f32,
    ) callconv(WINGDIPAPI) Status;

    const GdipCreateFromHDC = fn (
        hdc: win32.HDC,
        graphics: **Graphics,
    ) callconv(WINGDIPAPI) Status;

    const GdipDeleteGraphics = fn (graphics: *Graphics) callconv(WINGDIPAPI) Status;
    const GdipGraphicsClear = fn (graphics: *Graphics, color: u32) callconv(WINGDIPAPI) Status;

    const GdipDrawImageRect = fn (
        graphics: *Graphics,
        image: *Image,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    ) callconv(WINGDIPAPI) Status;

    const GdipSetInterpolationMode = fn (
        graphics: *Graphics,
        mode: InterpolationMode,
    ) callconv(WINGDIPAPI) Status;

    var dll: win32.HMODULE = undefined;
    var token: win32.ULONG_PTR = 0;
    var shutdown: GdiplusShutdown = undefined;
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
        shutdown = try win32.loadProc(GdiplusShutdown, "GdiplusShutdown", dll);
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

    pub fn deinit() void {
        _ = shutdown(token);
        _ = win32.kernel32.FreeLibrary(dll);
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
