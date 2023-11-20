const std = @import("std");
const builtin = @import("builtin");
const win32 = std.os.windows;
const assert = std.debug.assert;

//=== Re-exports ===//

pub usingnamespace win32;
pub usingnamespace win32.user32;

//=== Misc utilities ===//

/// Emulates the L prefix used in C for "wide" string literals
pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Returns the HINSTANCE corresponding to the process executable
pub inline fn getCurrentInstance() win32.HINSTANCE {
    return @as(
        win32.HINSTANCE,
        @ptrCast(win32.kernel32.GetModuleHandleW(null) orelse unreachable),
    );
}

pub inline fn loadProc(comptime T: type, comptime name: [*:0]const u8, handle: win32.HMODULE) Error!T {
    return @as(T, @ptrCast(win32.kernel32.GetProcAddress(handle, name) orelse
        return error.Unexpected));
}

pub inline fn setWindowText(
    hwnd: win32.HWND,
    string: win32.LPCWSTR,
) bool {
    return (SetWindowTextW(hwnd, string) != 0);
}

extern "user32" fn SetWindowTextW(
    hWnd: win32.HWND,
    lpString: win32.LPCWSTR,
) callconv(win32.WINAPI) win32.BOOL;

pub inline fn setProcessDpiAware() !void {
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;
    const res = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (res != win32.TRUE) return error.Unexpected;
}

extern "user32" fn SetProcessDpiAwarenessContext(
    value: isize,
) callconv(win32.WINAPI) win32.BOOL;

pub extern "user32" fn GetDpiForWindow(
    hwnd: win32.HWND,
) callconv(win32.WINAPI) c_uint;

pub inline fn getClientRect(win: win32.HWND) win32.RECT {
    var rect: win32.RECT = undefined;
    const result = GetClientRect(win, &rect);
    assert(result != 0);
    return rect;
}

extern "user32" fn GetClientRect(
    hwnd: win32.HWND,
    rect_ptr: *win32.RECT,
) callconv(win32.WINAPI) win32.BOOL;

pub inline fn getCursorPos(win: win32.HWND) win32.POINT {
    var point: win32.RECT = undefined;
    const result = GetCursorPos(win, &point);
    assert(result != 0);
    return point;
}

extern "user32" fn GetCursorPos(
    out_point: *win32.POINT,
) callconv(win32.WINAPI) win32.BOOL;

extern "user32" fn GetAsyncKeyState(
    vkey: c_int,
) callconv(win32.WINAPI) i16;

pub inline fn isKeyPressed(vkey: c_int) bool {
    const word: u16 = @bitCast(GetAsyncKeyState(vkey));
    return ((word & 0x8000) != 0);
}

pub extern "user32" fn SetTimer(
    hwnd: win32.HWND,
    event_id: isize,
    ms_timeout: c_uint,
    timer_fn: ?*anyopaque,
) callconv(win32.WINAPI) isize;

pub extern "user32" fn KillTimer(
    hwnd: win32.HWND,
    event_id: isize,
) callconv(win32.WINAPI) win32.BOOL;

pub inline fn pointToClient(win: win32.HWND, screen_point: win32.POINT) win32.POINT {
    var client_point: win32.POINT = screen_point;
    const result = ScreenToClient(win, &client_point);
    assert(result);
    return client_point;
}

pub inline fn pointToScreen(win: win32.HWND, client_point: win32.POINT) win32.POINT {
    var screen_point: win32.POINT = client_point;
    const result = ScreenToClient(win, &screen_point);
    assert(result);
    return screen_point;
}

extern "user32" fn ScreenToClient(
    hwnd: win32.HWND,
    point: *win32.POINT,
) callconv(win32.WINAPI) win32.BOOL;

extern "user32" fn ClientToScreen(
    hwnd: win32.HWND,
    point: *win32.POINT,
) callconv(win32.WINAPI) win32.BOOL;

pub inline fn waitMessage() !void {
    const res = WaitMessage();
    if (res == 0) return error.Unexpected;
}

extern "user32" fn WaitMessage() callconv(win32.WINAPI) win32.BOOL;

//=== Command line ===//

pub fn getArgs() []win32.LPWSTR {
    const cmd_line = win32.kernel32.GetCommandLineW();
    var argc: c_int = undefined;
    const argv = CommandLineToArgvW(cmd_line, &argc);
    return argv[0..@as(usize, @intCast(argc))];
}

pub inline fn freeArgs(args: []win32.LPWSTR) void {
    win32.LocalFree(@as(win32.HLOCAL, @ptrCast(args.ptr)));
}

extern "shell32" fn CommandLineToArgvW(
    lpCmdLine: win32.LPCWSTR,
    pNumArgs: *c_int,
) callconv(win32.WINAPI) [*c]win32.LPWSTR;

//=== Drag & Drop ===//

pub const HDROP = *opaque {};

pub extern "shell32" fn DragAcceptFiles(
    win: win32.HWND,
    accept: win32.BOOL,
) callconv(win32.WINAPI) void;

pub extern "shell32" fn DragQueryFileW(
    drop: HDROP,
    file: c_uint,
    lpszFile: ?[*:0]u16,
    cch: c_uint,
) callconv(win32.WINAPI) c_uint;

pub extern "shell32" fn DragFinish(
    drop: HDROP,
) callconv(win32.WINAPI) void;

//=== UTF16 string comparison ===//

pub inline fn compareStringOrdinal(
    string1: []const u16,
    string2: []const u16,
    ignore_case: bool,
) Error!std.math.Order {
    const cmp = CompareStringOrdinal(
        string1.ptr,
        @as(c_int, @intCast(string1.len)),
        string2.ptr,
        @as(c_int, @intCast(string2.len)),
        @intFromBool(ignore_case),
    );

    return switch (cmp) {
        1 => .lt,
        2 => .eq,
        3 => .gt,
        else => error.Unexpected,
    };
}

extern "kernel32" fn CompareStringOrdinal(
    lpString1: [*]const u16,
    cchCount1: c_int,
    lpString2: [*]const u16,
    cchCount2: c_int,
    bIgnoreCase: win32.BOOL,
) callconv(win32.WINAPI) c_int;

//=== Error handling ===//

pub const Error = error{Unexpected};

pub const ERROR_SIZE: usize = 614;

pub fn formatError(err: win32.Win32Error, buffer: []u8) ![]u8 {
    var wbuffer: [ERROR_SIZE]u16 = undefined;

    var len = FormatMessageW(
        win32.FORMAT_MESSAGE_FROM_SYSTEM | win32.FORMAT_MESSAGE_IGNORE_INSERTS,
        null,
        @intFromEnum(err),
        (0x01 << 10), // MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        &wbuffer,
        wbuffer.len,
        null,
    );

    if (len == 0) return error.Unexpected;

    return buffer[0..try std.unicode.utf16leToUtf8(buffer, wbuffer[0..len])];
}

extern "kernel32" fn FormatMessageW(
    dwFlags: u32,
    lpSource: ?*anyopaque,
    dwMessageId: u32,
    dwLanguageId: u32,
    lpBuffer: [*]u16,
    nSize: u32,
    Arguments: ?*win32.va_list,
) callconv(win32.WINAPI) u32;

//=== Standard cursors ===//

pub const CursorId = enum(u16) {
    Arrow = 32512,
    IBeam = 32513,
    Wait = 32514,
    Cross = 32515,
    UpArrow = 32516,
    SizeNWSE = 32642,
    SizeNESW = 32643,
    SizeWE = 32644,
    SizeNS = 32645,
    SizeAll = 32646,
    Hand = 32649,
    Help = 32651,
    Pin = 32671,
    Person = 32672,
    // NOTE (Matteo): The following are missing win3.1, I don't think is a problem
    AppStarting = 32650,
    No = 32648,
};

pub inline fn getDefaultCursor() win32.HCURSOR {
    return getStandardCursor(.Arrow) catch unreachable;
}

pub inline fn getStandardCursor(id: CursorId) Error!win32.HCURSOR {
    const name = @as(win32.LPCWSTR, @ptrFromInt(@intFromEnum(id)));
    return LoadCursorW(null, name) orelse error.Unexpected;
}

extern "user32" fn LoadCursorW(
    hinst: ?win32.HINSTANCE,
    cursor_name: win32.LPCWSTR,
) callconv(win32.WINAPI) ?win32.HCURSOR;

//=== Menus ===//

pub const MF_CHECKED: u32 = 0x00000008;
pub const MF_DISABLED: u32 = 0x00000002;
pub const MF_GRAYED: u32 = 0x00000001;
pub const MF_MENUBARBREAK: u32 = 0x00000020;
pub const MF_MENUBREAK: u32 = 0x00000040;

// NOTE (Matteo): These are kept internal - specific functions are provided instead
const MF_OWNERDRAW: u32 = 0x00000100;
const MF_BITMAP: u32 = 0x00000004;
const MF_POPUP: u32 = 0x00000010;
const MF_SEPARATOR: u32 = 0x00000800;

pub const MenuItem = union(enum) {
    String: struct { id: u32, str: win32.LPCWSTR },
    Popup: struct { sub_menu: win32.HMENU, name: win32.LPCWSTR },
    Bitmap: struct { id: u32, handle: win32.HANDLE },
    OwnerDraw: struct { id: u32, data: *anyopaque },
};

pub inline fn createMenu() Error!win32.HMENU {
    return CreateMenu() orelse error.Unexpected;
}

pub fn appendMenu(menu: win32.HMENU, item: MenuItem, flags: u32) Error!void {
    const res = switch (item) {
        .String => |x| AppendMenuW(menu, flags, menuIdToPtr(x.id), @as(*const anyopaque, @ptrCast(x.str))),
        .Popup => |x| AppendMenuW(menu, flags, @as(*anyopaque, @ptrCast(x.sub_menu)), @as(*const anyopaque, @ptrCast(x.name))),
        .Bitmap => |x| AppendMenuW(menu, flags, menuIdToPtr(x.id), x.handle),
        .OwnerDraw => |x| AppendMenuW(menu, flags, menuIdToPtr(x.id), x.data),
    };

    if (res != win32.TRUE) return error.Unexpected;
}

inline fn menuIdToPtr(id: u32) *const anyopaque {
    return @as(*const anyopaque, @ptrFromInt(id));
}

extern "user32" fn CreateMenu() callconv(win32.WINAPI) ?win32.HMENU;
extern "user32" fn AppendMenuW(
    hMenu: win32.HMENU,
    uFlags: u32,
    uIDNewItem: *const anyopaque,
    lpNewItem: *const anyopaque,
) callconv(win32.WINAPI) win32.BOOL;

//=== Buffered window painting ===//

pub const PAINTSTRUCT = extern struct {
    hdc: win32.HDC,
    fErase: win32.BOOL,
    rcPaint: win32.RECT,
    fRestore: win32.BOOL,
    fIncUpdate: win32.BOOL,
    rgbReserved: [32]u8,
};

pub inline fn beginPaint(win: win32.HWND, ps: *PAINTSTRUCT) Error!win32.HDC {
    return BeginPaint(win, ps) orelse error.Unexpected;
}

pub inline fn endPaint(win: win32.HWND, ps: PAINTSTRUCT) Error!void {
    if (EndPaint(win, &ps) != win32.TRUE) return error.Unexpected;
}

pub const BufferedPaint = struct {
    /// Window affected by the painting
    win: win32.HWND,
    /// Memory DC to be used for painting
    dc: win32.HDC,
    // Paint information returned by BeginPaint
    ps: PAINTSTRUCT,
    // Internal, opaque paint buffer handle
    pb: HPAINTBUFFER,

    /// Initialize buffered painting for the current thread
    pub inline fn init() Error!void {
        const hr = BufferedPaintInit();
        if (hr != 0) {
            SetLastError(@as(u32, @intCast(hr)));
            return error.Unexpected;
        }
    }

    /// Shutdown buffered painting for the current thread
    pub inline fn deinit() void {
        const hr = BufferedPaintUnInit();
        if (hr != 0) {
            SetLastError(@as(u32, @intCast(hr)));
            unreachable;
        }
    }

    /// Begin buffered painting session for the given window
    pub inline fn begin(
        win: win32.HWND,
    ) Error!BufferedPaint {
        var out: BufferedPaint = undefined;

        const win_dc = try beginPaint(win, &out.ps);

        // TODO (Matteo): Is it better to always paint the client rectangle explicitly?
        if (BeginBufferedPaint(win_dc, &out.ps.rcPaint, .COMPATIBLEBITMAP, null, &out.dc)) |pb| {
            out.win = win;
            out.pb = pb;
            return out;
        }

        return error.Unexpected;
    }

    /// End buffered painting
    pub inline fn end(pb: BufferedPaint) Error!void {
        const hr = EndBufferedPaint(pb.pb, win32.TRUE);
        if (hr != 0) {
            SetLastError(@as(u32, @intCast(hr)));
            return error.Unexpected;
        }

        try endPaint(pb.win, pb.ps);
    }

    pub const Area = union(enum) { All, Rect: win32.RECT };

    /// Clear an area of the buffer defined by the given rectangle
    pub inline fn clear(self: *const BufferedPaint, area: Area) Error!void {
        const rect_ptr = switch (area) {
            .All => null,
            .Rect => |*rect| rect,
        };

        const hr = BufferedPaintClear(self.pb, rect_ptr);
        if (hr != 0) {
            SetLastError(@as(u32, @intCast(hr)));
            return error.Unexpected;
        }
    }
};

// TODO (Matteo): Left as a way to report HRESULT. Find a better solution.
extern "kernel32" fn SetLastError(dwErrCode: u32) callconv(win32.WINAPI) void;

pub inline fn invalidateRect(
    win: win32.HWND,
    opt_rect: ?*const win32.RECT,
    erase: bool,
) bool {
    return (InvalidateRect(win, opt_rect, @intFromBool(erase)) != 0);
}

extern "user32" fn InvalidateRect(
    hWnd: win32.HWND,
    lpRect: ?*const win32.RECT,
    bErase: win32.BOOL,
) callconv(win32.WINAPI) win32.BOOL;

const HPAINTBUFFER = *opaque {};
const BP_PAINTPARAMS = opaque {};
const BP_BUFFERFORMAT = enum(c_int) { COMPATIBLEBITMAP, DIB, TOPDOWNDIB, TOPDOWNMONODIB };

extern "user32" fn BeginPaint(
    hwnd: win32.HWND,
    paint: *PAINTSTRUCT,
) callconv(win32.WINAPI) ?win32.HDC;

extern "user32" fn EndPaint(
    hwnd: win32.HWND,
    paint: *const PAINTSTRUCT,
) callconv(win32.WINAPI) win32.BOOL;

extern "uxtheme" fn BufferedPaintInit() callconv(win32.WINAPI) win32.HRESULT;
extern "uxtheme" fn BufferedPaintUnInit() callconv(win32.WINAPI) win32.HRESULT;

extern "uxtheme" fn BeginBufferedPaint(
    hdcTarget: win32.HDC,
    prcTarget: *const win32.RECT,
    dwFormat: BP_BUFFERFORMAT,
    pPaintParams: ?*BP_PAINTPARAMS,
    phdc: *win32.HDC,
) callconv(win32.WINAPI) ?HPAINTBUFFER;

extern "uxtheme" fn EndBufferedPaint(
    hBufferedPaint: HPAINTBUFFER,
    fUpdateTarget: win32.BOOL,
) callconv(win32.WINAPI) win32.HRESULT;

extern "uxtheme" fn BufferedPaintClear(
    hBufferedPaint: HPAINTBUFFER,
    prc: ?*const win32.RECT,
) callconv(win32.WINAPI) win32.HRESULT;

//=== Drawing ===//

pub const BkModes = enum(c_int) { Transparent = 1, Opaque = 2 };

pub const SIZE = extern struct {
    cx: i32,
    cy: i32,
};

pub extern "gdi32" fn SetBkMode(
    hdc: win32.HDC,
    mode: BkModes,
) callconv(win32.WINAPI) c_int;

pub extern "gdi32" fn ExtTextOutW(
    hdc: win32.HDC,
    x: c_int,
    y: c_int,
    options: c_uint,
    lprect: ?*const win32.RECT,
    lpString: win32.LPCWSTR,
    c: c_int,
    lpDx: ?*const c_int,
) callconv(win32.WINAPI) c_int;

pub extern "gdi32" fn GetTextExtentPoint32W(
    hdc: win32.HDC,
    lpString: win32.LPCWSTR,
    c: c_int,
    psizl: *SIZE,
) callconv(win32.WINAPI) c_int;

pub extern "gdi32" fn DrawTextW(
    hdc: win32.HDC,
    lpchText: ?win32.LPCWSTR,
    cchText: c_int,
    lprc: *win32.RECT,
    format: c_uint,
) c_int;

pub extern "gdi32" fn DrawTextExW(
    hdc: win32.HDC,
    lpchText: win32.LPCWSTR,
    cchText: c_int,
    lprc: *win32.RECT,
    format: c_uint,
    lpdtp: *DRAWTEXTPARAMS,
) c_int;

pub const DRAWTEXTPARAMS = struct {
    cbSize: c_uint = @sizeOf(DRAWTEXTPARAMS),
    iTabLength: c_int = 8,
    iLeftMargin: c_int = 0,
    iRightMargin: c_int = 0,
    uiLengthDrawn: c_uint = 0,
};

// DrawText Format Flags
pub const DT_TOP = 0x00000000;
pub const DT_LEFT = 0x00000000;
pub const DT_CENTER = 0x00000001;
pub const DT_RIGHT = 0x00000002;
pub const DT_VCENTER = 0x00000004;
pub const DT_BOTTOM = 0x00000008;
pub const DT_WORDBREAK = 0x00000010;
pub const DT_SINGLELINE = 0x00000020;
pub const DT_EXPANDTABS = 0x00000040;
pub const DT_TABSTOP = 0x00000080;
pub const DT_NOCLIP = 0x00000100;
pub const DT_EXTERNALLEADING = 0x00000200;
pub const DT_CALCRECT = 0x00000400;
pub const DT_NOPREFIX = 0x00000800;
pub const DT_INTERNAL = 0x00001000;

//=== File dialogs ===//

pub const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?win32.HWND = null,
    hInstance: ?win32.HINSTANCE = null,
    lpstrFilter: ?win32.LPCWSTR = null,
    lpstrCustomFilter: ?win32.LPWSTR = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: win32.LPWSTR,
    nMaxFile: u32,
    lpstrFileTitle: ?win32.LPWSTR = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?win32.LPCWSTR = null,
    lpstrTitle: ?win32.LPCWSTR = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?win32.LPCWSTR = null,
    lCustData: win32.LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?win32.LPCWSTR = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

pub inline fn getOpenFileName(ofn: *OPENFILENAMEW) Error!bool {
    assert(ofn.lStructSize == @sizeOf(OPENFILENAMEW));

    if (GetOpenFileNameW(ofn) == win32.TRUE) return true;

    const err = CommDlgExtendedError();
    if (err == 0) return false;

    // TODO (Matteo): Translate errors
    return error.Unexpected;
}

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(win32.WINAPI) win32.BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(win32.WINAPI) u32;

//=== COM stuff ===//

pub const IStream = extern struct {
    lpVtbl: [*c]Vtbl,

    pub fn release(stream: *IStream) u32 {
        return stream.lpVtbl.*.Release(stream);
    }

    const Vtbl = extern struct {
        QueryInterface: *const fn (
            [*c]IStream,
            ?*anyopaque,
            [*c]?*anyopaque,
        ) callconv(win32.WINAPI) win32.HRESULT,

        AddRef: *const fn ([*c]IStream) callconv(win32.WINAPI) u32,
        Release: *const fn ([*c]IStream) callconv(win32.WINAPI) u32,

        Read: *const fn (
            [*c]IStream,
            ?*anyopaque,
            u32,
            [*c]u32,
        ) callconv(win32.WINAPI) win32.HRESULT,

        Write: *const fn (
            [*c]IStream,
            ?*const anyopaque,
            u32,
            [*c]u32,
        ) callconv(win32.WINAPI) win32.HRESULT,

        Seek: *const fn ([*c]IStream, i64, u32, [*c]u64) callconv(win32.WINAPI) win32.HRESULT,
        SetSize: *const fn ([*c]IStream, u64) callconv(win32.WINAPI) win32.HRESULT,

        CopyTo: *const fn (
            [*c]IStream,
            [*c]IStream,
            u64,
            [*c]u64,
            [*c]u64,
        ) callconv(win32.WINAPI) win32.HRESULT,

        Commit: *const fn ([*c]IStream, u32) callconv(win32.WINAPI) win32.HRESULT,
        Revert: *const fn ([*c]IStream) callconv(win32.WINAPI) win32.HRESULT,

        LockRegion: *const fn ([*c]IStream, u64, u64, u32) callconv(win32.WINAPI) win32.HRESULT,
        UnlockRegion: *const fn ([*c]IStream, u64, u64, u32) callconv(win32.WINAPI) win32.HRESULT,

        Stat: *const fn ([*c]IStream, ?*anyopaque, u32) callconv(win32.WINAPI) win32.HRESULT,
        Clone: *const fn ([*c]IStream, [*c][*c]IStream) callconv(win32.WINAPI) win32.HRESULT,
    };
};

pub inline fn createMemStream(mem: []const u8) !*IStream {
    return SHCreateMemStream(
        mem.ptr,
        @as(win32.UINT, @intCast(mem.len)),
    ) orelse error.Unexpected;
}

extern "shlwapi" fn SHCreateMemStream(
    pInit: [*]const u8,
    cbInit: win32.UINT,
) callconv(win32.WINAPI) ?*IStream;

//=== Console ===//

pub extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(win32.WINAPI) win32.BOOL;
pub extern "kernel32" fn AllocConsole() callconv(win32.WINAPI) win32.BOOL;
pub extern "kernel32" fn FreeConsole() callconv(win32.WINAPI) win32.BOOL;
pub extern "kernel32" fn SetConsoleTitleW(lpConsoleTitle: win32.LPCWSTR) callconv(win32.WINAPI) win32.BOOL;
