const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
const L = win32.L;

const app_name = L("MiniView");

//=== Infrastructure ===//

// NOTE (Matteo): Kept static to allow for growing it without risk of smashing the stack
var panic_buffer: [4096]u8 = undefined;

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below.
    app.main() catch unreachable;
}

pub fn panic(err: []const u8, maybe_trace: ?*std.builtin.StackTrace) noreturn {
    // NOTE (Matteo): Custom panic handler that reports the error via message box
    // This is because win32 apps don't have an associated console by default,
    // so stderr "is not visible".
    var stream = std.io.fixedBufferStream(&panic_buffer);
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
        panic_buffer[stream.getPos() catch unreachable ..],
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

const Bump = struct {
    buffer: []u8,
    alloc_pos: usize = 0,
    commit_pos: usize = 0,

    const Self = @This();

    pub fn init() !Self {
        const size = 1024 * 1024 * 1024;

        const ptr = try win32.VirtualAlloc(
            null,
            size,
            win32.MEM_RESERVE,
            win32.PAGE_NOACCESS,
        );

        return Self{ .buffer = @ptrCast([*]u8, ptr)[0..size] };
    }

    pub fn deinit(self: *Self) void {
        win32.VirtualFree(@ptrCast(win32.LPVOID, self.buffer.ptr), 0, win32.MEM_RELEASE);
        self.alloc_pos = 0;
        self.commit_pos = 0;
        self.buffer = self.buffer[0..0];
    }

    pub fn push(self: *Self, comptime T: type, count: usize) ![]T {
        const cap = self.buffer.len;
        const size = count * @sizeOf(T);
        const offset = std.mem.alignForward(self.alloc_pos, @alignOf(T));

        if (size > cap or offset > cap or offset + size > cap) return error.OutOfMemory;

        if (offset > self.commit_pos) {
            const ptr = @ptrCast(win32.LPVOID, self.buffer.ptr + self.commit_pos);
            const next_pos = std.mem.alignForward(offset, std.mem.page_size);
            assert(next_pos <= cap);

            _ = try win32.VirtualAlloc(
                ptr,
                next_pos - self.commit_pos,
                win32.MEM_COMMIT,
                win32.PAGE_READWRITE,
            );

            self.commit_pos = next_pos;
        }

        self.alloc_pos = offset;

        return std.mem.bytesAsSlice(T, self.buffer[offset..size]);
    }
};

const app = struct {
    const Command = enum(u32) {
        Open = 1,
    };

    var image: ?*gdip.Image = null;
    var memory: Bump = undefined;

    pub fn main() anyerror!void {
        // Setup memory
        memory = try Bump.init();
        defer memory.deinit();

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
        try win32.appendMenu(menu, .{ .String = .{ .id = @enumToInt(Command.Open), .str = L("Open") } }, 0);

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

    fn open(win: win32.HWND) gdip.Error!void {
        var file_buf = [_:0]u16{0} ** 1024;
        var ofn = win32.OPENFILENAMEW{
            .hwndOwner = win,
            .lpstrFile = &file_buf,
            .nMaxFile = file_buf.len,
            .lpstrFilter = L("Image files\x00*.bmp;*.png;*.jpg;*.jpeg;*.tiff\x00"),
        };

        if (try win32.getOpenFileName(&ofn)) {
            var new_image: *gdip.Image = undefined;
            try gdip.checkStatus(gdip.createImageFromFile(&file_buf, &new_image));

            try disposeImage();
            image = new_image;

            _ = win32.InvalidateRect(win, null, win32.TRUE);
        }
    }

    fn disposeImage() gdip.Error!void {
        if (image) |old_img| {
            try gdip.checkStatus(gdip.disposeImage(old_img));
        }
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
    const GdipCreateBitmapFromFile = fn (filename: win32.LPCWSTR, image: **Image) callconv(WINGDIPAPI) Status;
    const GdipCreateBitmapFromStream = fn (stream: *win32.IStream, image: **Image) callconv(WINGDIPAPI) Status;
    const GdipDisposeImage = fn (image: *Image) callconv(WINGDIPAPI) Status;
    const GdipGetImageDimension = fn (image: *Image, width: *f32, height: *f32) callconv(WINGDIPAPI) Status;
    const GdipCreateFromHDC = fn (hdc: win32.HDC, graphics: **Graphics) callconv(WINGDIPAPI) Status;
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
    const GdipSetInterpolationMode = fn (graphics: *Graphics, mode: InterpolationMode) callconv(WINGDIPAPI) Status;

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
        dll = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse return error.Win32Error;
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
            7 => return error.Win32Error,
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
            else => return error.Win32Error,
        }
    }
};
