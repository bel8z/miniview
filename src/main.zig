const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const L = win32.L;

const app_name = L("MiniView");

var panic_buffer: [4096]u8 = undefined;

const Command = enum(u32) {
    Open = 1,
};

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below.
    innerMain() catch unreachable;
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

/// Actual main procedure
fn innerMain() anyerror!void {
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

    try win32.initBufferedPaint();
    defer win32.deinitBufferedPaint();

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

    var mv = try MiniView.init();
    defer mv.deinit();
    try setAppPtr(win, &mv);

    _ = win32.showWindow(win, win32.SW_SHOWDEFAULT);
    try win32.updateWindow(win);

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

fn paint(pb: win32.PaintBuffer) void {
    // TODO: Painting code goes here
    _ = pb;
}

fn setAppPtr(win: win32.HWND, ptr: anytype) !void {
    _ = try win32.setWindowLongPtrW(
        win,
        win32.GWL_USERDATA,
        @intCast(isize, @ptrToInt(ptr)),
    );
}

fn getAppPtr(comptime T: type, win: win32.HWND) ?*T {
    if (win32.getWindowLongPtrW(win, win32.GWL_USERDATA)) |address| {
        return @intToPtr(?*T, @intCast(usize, address));
    } else |_| {
        return null;
    }
}

fn wndProc(
    win: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(win32.WINAPI) win32.LRESULT {
    var miniview = getAppPtr(MiniView, win) orelse return win32.defWindowProcW(win, msg, wparam, lparam);

    switch (msg) {
        win32.WM_CLOSE => win32.destroyWindow(win) catch unreachable,
        win32.WM_DESTROY => win32.PostQuitMessage(0),
        win32.WM_PAINT => {
            if (win32.beginBufferedPaint(win)) |pb| {
                defer win32.endBufferedPaint(win, pb) catch unreachable;
                paint(pb);
            } else |_| unreachable;
        },
        win32.WM_COMMAND => {
            if (wparam & 0xffff0000 == 0) {
                switch (@intToEnum(Command, wparam & 0xffff)) {
                    .Open => miniview.open(win) catch unreachable,
                }
            }
        },
        else => return win32.defWindowProcW(win, msg, wparam, lparam),
    }

    return 0;
}

const Image = opaque {};

const MiniView = struct {
    // GDI+ stuff
    gdip_dll: win32.HMODULE,
    gdip_startup: GdiplusStartup,
    gdip_shutdown: GdiplusShutdown,
    img_load: GdipCreateBitmapFromFile,
    img_dispose: GdipDisposeImage,
    gdip_token: win32.ULONG_PTR = 0,

    // App specific stuff
    image: ?*Image = null,

    const Self = @This();

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

    pub fn init() Error!Self {
        var dll = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse return error.Win32Error;

        var self = Self{
            .gdip_dll = dll,
            .gdip_startup = try win32.loadProc(GdiplusStartup, "GdiplusStartup", dll),
            .gdip_shutdown = try win32.loadProc(GdiplusShutdown, "GdiplusShutdown", dll),
            .img_load = try win32.loadProc(GdipCreateBitmapFromFile, "GdipCreateBitmapFromFile", dll),
            .img_dispose = try win32.loadProc(GdipDisposeImage, "GdipDisposeImage", dll),
        };

        const input = GdiplusStartupInput{};
        var output: GdiplusStartupOutput = undefined;
        const status = self.gdip_startup(&self.gdip_token, &input, &output);
        std.debug.assert(status == 0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.disposeImage() catch {};
        _ = self.gdip_shutdown(self.gdip_token);
        _ = win32.kernel32.FreeLibrary(self.gdip_dll);
    }

    pub fn open(self: *MiniView, win: win32.HWND) Error!void {
        var file_buf = [_:0]u16{0} ** 1024;
        var ofn = win32.OPENFILENAMEW{
            .lpstrFile = &file_buf,
            .nMaxFile = file_buf.len,
            .lpstrFilter = L("Image files\x00*.bmp;*.png;*.jpg;*.jpeg;*.tiff\x00"),
        };

        if (try win32.getOpenFileName(&ofn)) {
            var image: *Image = undefined;
            const status = self.img_load(&file_buf, &image);
            if (status != 0) return mapError(status);

            _ = win32.messageBoxW(win, &file_buf, app_name ++ L(": Image Loaded"), 0) catch
                return error.Win32Error;

            try self.disposeImage();
            self.image = image;
        }
    }

    fn disposeImage(self: *Self) Error!void {
        if (self.image) |old_img| {
            const status = self.img_dispose(old_img);
            if (status != 0) return mapError(status);
        }
    }

    //=== Internal GDI+ implementation ===//

    const WINGDIPAPI = win32.WINAPI;

    const Status = c_int;

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

    const GdiplusStartup = fn (token: *win32.ULONG_PTR, input: *const GdiplusStartupInput, output: *GdiplusStartupOutput) callconv(WINGDIPAPI) Status;
    const GdiplusShutdown = fn (token: win32.ULONG_PTR) callconv(WINGDIPAPI) Status;
    const GdipCreateBitmapFromFile = fn (filename: win32.LPCWSTR, image: **Image) callconv(WINGDIPAPI) Status;
    const GdipDisposeImage = fn (image: *Image) callconv(WINGDIPAPI) Status;

    inline fn mapError(status: Status) Error {
        return switch (status) {
            1 => error.GenericError,
            2 => error.InvalidParameter,
            3 => error.OutOfMemory,
            4 => error.ObjectBusy,
            5 => error.InsufficientBuffer,
            6 => error.NotImplemented,
            7 => error.Win32Error,
            8 => error.WrongState,
            9 => error.Aborted,
            10 => error.FileNotFound,
            11 => error.ValueOverflow,
            12 => error.AccessDenied,
            13 => error.UnknownImageFormat,
            14 => error.FontFamilyNotFound,
            15 => error.FontStyleNotFound,
            16 => error.NotTrueTypeFont,
            17 => error.UnsupportedGdiplusVersion,
            18 => error.GdiplusNotInitialized,
            19 => error.PropertyNotFound,
            20 => error.PropertyNotSupported,
            21 => error.ProfileNotFound,
            else => error.Win32Error,
        };
    }
};
