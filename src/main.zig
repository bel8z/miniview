const std = @import("std");
const builtin = @import("builtin");

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

const app = struct {
    const Command = enum(u32) {
        Open = 1,
    };

    var image: ?*gdip.Image = null;

    pub fn main() anyerror!void {
        // Register window class
        const hinst = win32.getCurrentInstance();

        const win_class = win32.WNDCLASSEXW{
            .style = 0,
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
        defer disposeImage();

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
        switch (msg) {
            win32.WM_CLOSE => win32.destroyWindow(win) catch unreachable,
            win32.WM_DESTROY => win32.PostQuitMessage(0),
            win32.WM_PAINT => {
                if (win32.beginBufferedPaint(win)) |pb| {
                    defer win32.endBufferedPaint(win, pb) catch unreachable;
                    // Actual painting is application defined
                    paint(pb, win) catch unreachable;
                } else |_| unreachable;
            },
            win32.WM_COMMAND => {
                if (wparam & 0xffff0000 == 0) {
                    const command = @intToEnum(Command, wparam & 0xffff);
                    switch (command) {
                        .Open => open(win) catch unreachable,
                    }
                }
            },
            else => return win32.defWindowProcW(win, msg, wparam, lparam),
        }

        return 0;
    }

    fn paint(pb: win32.PaintBuffer, win: win32.HWND) gdip.Error!void {
        // TODO: Painting code goes here
        _ = pb;
        _ = win;
    }

    fn open(win: win32.HWND) gdip.Error!void {
        var file_buf = [_:0]u16{0} ** 1024;
        var ofn = win32.OPENFILENAMEW{
            .lpstrFile = &file_buf,
            .nMaxFile = file_buf.len,
            .lpstrFilter = L("Image files\x00*.bmp;*.png;*.jpg;*.jpeg;*.tiff\x00"),
        };

        if (try win32.getOpenFileName(&ofn)) {
            var new_image: *gdip.Image = undefined;
            try gdip.checkStatus(gdip.createBitmapFromFile(&file_buf, &new_image));

            _ = win32.messageBoxW(win, &file_buf, app_name ++ L(": Image Loaded"), 0) catch
                return error.Win32Error;

            try disposeImage();
            image = new_image;
        }
    }

    fn disposeImage() gdip.Error!void {
        if (image) |old_img| {
            try gdip.checkStatus(gdip.disposeImage(old_img));
        }
    }
};

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

    pub const Status = c_int;
    pub const Image = opaque {};

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
    const GdipDisposeImage = fn (image: *Image) callconv(WINGDIPAPI) Status;

    var token: win32.ULONG_PTR = 0;
    var shutdown: GdiplusShutdown = undefined;
    var createBitmapFromFile: GdipCreateBitmapFromFile = undefined;
    var disposeImage: GdipDisposeImage = undefined;
    var dll: win32.HMODULE = undefined;

    pub fn init() Error!void {
        dll = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse return error.Win32Error;
        shutdown = try win32.loadProc(GdiplusShutdown, "GdiplusShutdown", dll);
        createBitmapFromFile = try win32.loadProc(GdipCreateBitmapFromFile, "GdipCreateBitmapFromFile", dll);
        disposeImage = try win32.loadProc(GdipDisposeImage, "GdipDisposeImage", dll);

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
