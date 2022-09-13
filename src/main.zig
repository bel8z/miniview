const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const L = win32.L;

const app_name = L("MiniView");
var buffer: [4096]u8 = undefined;

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below.
    innerMain() catch unreachable;
}

pub fn panic(err: []const u8, maybe_trace: ?*std.builtin.StackTrace) noreturn {
    // NOTE (Matteo): Custom panic handler that reports the error via message box
    // This is because win32 apps don't have an associated console by default,
    // so stderr "is not visible".
    const msg = if (maybe_trace) |trace|
        std.fmt.bufPrint(buffer[0..], "{s}\n{}", .{ err, trace }) catch unreachable
    else
        std.fmt.bufPrint(buffer[0..], "{s}", .{err}) catch unreachable;

    var alloc = std.heap.FixedBufferAllocator.init(buffer[msg.len..]);
    _ = win32.messageBoxW(
        null,
        std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), msg) catch unreachable,
        app_name,
        0,
    ) catch unreachable;

    // Spinning required because the function is 'noreturn'
    while (builtin.mode == .Debug) @breakpoint();

    // Abort in non-debug builds.
    std.os.abort();
}

/// Actual main procedure
fn innerMain() anyerror!void {
    var env = try gdip.Env.init();
    defer env.deinit();

    const hinst = try win32.getCurrentInstance();

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
        null,
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
        else => return win32.defWindowProcW(win, msg, wparam, lparam),
    }

    return 0;
}
