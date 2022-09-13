const std = @import("std");
const win32 = @import("win32.zig");
const L = win32.L;

pub fn main() anyerror!void {
    const hinst = try win32.getCurrentInstance();

    const win_class_name = L("MiniWin");

    const win_class = win32.WNDCLASSEXW{
        .style = 0,
        .lpfnWndProc = wndProc,
        .hInstance = hinst,
        .lpszClassName = win_class_name,
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
        win_class_name,
        win_class_name,
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
