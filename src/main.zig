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
    var gdip = try Gdip.init();
    defer gdip.deinit();

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
                paint(pb);
            } else |_| unreachable;
        },
        win32.WM_COMMAND => {
            if (wparam & 0xffff0000 == 0) {
                switch (@intToEnum(Command, wparam & 0xffff)) {
                    .Open => _ = win32.messageBoxW(win, L("Open!"), app_name, 0) catch unreachable,
                }
            }
        },
        else => return win32.defWindowProcW(win, msg, wparam, lparam),
    }

    return 0;
}

pub const Gdip = struct {
    handle: win32.HMODULE,
    token: win32.ULONG_PTR,
    startup: GdiplusStartup,
    shutdown: GdiplusShutdown,
    load: GdipLoadImageFromFile,

    pub const Error = win32.Error || error{
        GenericError,
        InvalidParameter,
        OutOfMemory,
        ObjectBusy,
        InsufficientBuffer,
        NotImplemented,
        Win32Error,
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

    pub const Image = opaque {};

    const Self = @This();

    //=== Wrapper interface ===//

    pub fn init() Error!Self {
        var self: Self = undefined;

        self.handle = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse
            return Error.Win32Error;

        self.startup = try loadProc(GdiplusStartup, "GdiplusStartup", self.handle);
        self.shutdown = try loadProc(GdiplusShutdown, "GdiplusShutdown", self.handle);
        self.load = try loadProc(GdipLoadImageFromFile, "GdipLoadImageFromFile", self.handle);

        const input = GdiplusStartupInput{};
        var output: GdiplusStartupOutput = undefined;
        const status = self.startup(&self.token, &input, &output);
        std.debug.assert(status == 0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self.shutdown(self.token);
        _ = win32.kernel32.FreeLibrary(self.handle);
    }

    pub fn loadImage(self: *Self, filename: []const u8) Error!*Image {
        var buffer: [1024]u8 = undefined;
        var alloc = std.heap.FixedBufferAllocator.init(buffer[0..]);
        const path = try std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), filename);

        var image: *Image = undefined;
        const status = self.load(path, &image);
        if (status != 0) return mapError(status);

        return image;
    }

    //=== Internal implementation ===//

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
    const GdipLoadImageFromFile = fn (filename: win32.LPCWSTR, image: **Image) callconv(WINGDIPAPI) Status;

    inline fn loadProc(comptime T: type, comptime name: [*:0]const u8, handle: win32.HMODULE) !T {
        return @ptrCast(T, win32.kernel32.GetProcAddress(handle, name) orelse
            return Error.Win32Error);
    }

    inline fn mapError(status: Status) Error {
        return switch (status) {
            1 => Error.GenericError,
            2 => Error.InvalidParameter,
            3 => Error.OutOfMemory,
            4 => Error.ObjectBusy,
            5 => Error.InsufficientBuffer,
            6 => Error.NotImplemented,
            7 => Error.Win32Error,
            8 => Error.WrongState,
            9 => Error.Aborted,
            10 => Error.FileNotFound,
            11 => Error.ValueOverflow,
            12 => Error.AccessDenied,
            13 => Error.UnknownImageFormat,
            14 => Error.FontFamilyNotFound,
            15 => Error.FontStyleNotFound,
            16 => Error.NotTrueTypeFont,
            17 => Error.UnsupportedGdiplusVersion,
            18 => Error.GdiplusNotInitialized,
            19 => Error.PropertyNotFound,
            20 => Error.PropertyNotSupported,
            21 => Error.ProfileNotFound,
            else => Error.UnexpectedError,
        };
    }
};
