const std = @import("std");
const builtin = @import("builtin");
const win32 = std.os.windows;

//=== Re-exports ===//

pub usingnamespace win32;
pub usingnamespace win32.user32;

//=== Misc utilities ===//

/// Emulates the L prefix used in C for "wide" string literals
pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Returns the HINSTANCE corresponding to the process executable
pub fn getCurrentInstance() win32.HINSTANCE {
    return @ptrCast(
        win32.HINSTANCE,
        win32.kernel32.GetModuleHandleW(null) orelse unreachable,
    );
}

pub inline fn loadProc(comptime T: type, comptime name: [*:0]const u8, handle: win32.HMODULE) Error!T {
    return @ptrCast(T, win32.kernel32.GetProcAddress(handle, name) orelse
        return error.Win32Error);
}

//=== Error handling ===//

pub const Error = error{Win32Error};

pub extern "kernel32" fn GetLastError() callconv(win32.WINAPI) u32;
pub extern "kernel32" fn SetLastError(dwErrCode: u32) callconv(win32.WINAPI) void;

pub const ERROR_SIZE: usize = 614;

pub fn formatError(err: u32, buffer: []u8) ![]u8 {
    var wbuffer: [ERROR_SIZE]u16 = undefined;

    var len = FormatMessageW(
        win32.FORMAT_MESSAGE_FROM_SYSTEM | win32.FORMAT_MESSAGE_IGNORE_INSERTS,
        null,
        err,
        (0x01 << 10), // MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        &wbuffer,
        wbuffer.len,
        null,
    );

    if (len == 0) return error.Win32Error;

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

pub fn getDefaultCursor() win32.HCURSOR {
    return getStandardCursor(.Arrow) catch unreachable;
}

pub fn getStandardCursor(id: CursorId) Error!win32.HCURSOR {
    const name = @intToPtr(win32.LPCWSTR, @enumToInt(id));
    return LoadCursorW(null, name) orelse error.Win32Error;
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

pub fn createMenu() Error!win32.HMENU {
    return CreateMenu() orelse error.Win32Error;
}

pub fn appendMenu(menu: win32.HMENU, item: MenuItem, flags: u32) Error!void {
    const res = switch (item) {
        .String => |x| AppendMenuW(menu, flags, menuIdToPtr(x.id), @ptrCast(*const anyopaque, x.str)),
        .Popup => |x| AppendMenuW(menu, flags, @ptrCast(*anyopaque, x.sub_menu), @ptrCast(*const anyopaque, x.name)),
        .Bitmap => |x| AppendMenuW(menu, flags, menuIdToPtr(x.id), x.handle),
        .OwnerDraw => |x| AppendMenuW(menu, flags, menuIdToPtr(x.id), x.data),
    };

    if (res != win32.TRUE) return error.Win32Error;
}

inline fn menuIdToPtr(id: u32) *const anyopaque {
    return @intToPtr(*const anyopaque, id);
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

pub const PaintBuffer = struct {
    /// Memory DC to be used for painting
    dc: win32.HDC,
    // Paint information returned by BeginPaint
    ps: PAINTSTRUCT,
    // Internal, opaque paint buffer handle
    pb: HPAINTBUFFER,

    pub fn clear(self: *PaintBuffer, rect: win32.RECT) Error!void {
        const hr = BufferedPaintClear(self.pb, &rect);
        if (hr != 0) {
            SetLastError(@intCast(u32, hr));
            return error.Win32Error;
        }
    }
};

pub inline fn initBufferedPaint() Error!void {
    const hr = BufferedPaintInit();
    if (hr != 0) {
        SetLastError(@intCast(u32, hr));
        return error.Win32Error;
    }
}

pub inline fn deinitBufferedPaint() void {
    const hr = BufferedPaintUnInit();
    if (hr != 0) {
        SetLastError(@intCast(u32, hr));
        unreachable;
    }
}

pub inline fn beginBufferedPaint(
    win: win32.HWND,
) Error!PaintBuffer {
    var out: PaintBuffer = undefined;

    if (BeginPaint(win, &out.ps)) |win_dc| {
        // TODO (Matteo): Is it better to always paint the client rectangle explicitly?
        if (BeginBufferedPaint(win_dc, &out.ps.rcPaint, .COMPATIBLEBITMAP, null, &out.dc)) |pb| {
            out.pb = pb;
            return out;
        }
    }

    return error.Win32Error;
}

pub inline fn endBufferedPaint(win: win32.HWND, pb: PaintBuffer) Error!void {
    const hr = EndBufferedPaint(pb.pb, win32.TRUE);
    if (hr != 0) {
        SetLastError(@intCast(u32, hr));
        return error.Win32Error;
    }

    if (EndPaint(win, &pb.ps) != win32.TRUE) unreachable;
}

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
) ?HPAINTBUFFER;

extern "uxtheme" fn EndBufferedPaint(
    hBufferedPaint: HPAINTBUFFER,
    fUpdateTarget: win32.BOOL,
) callconv(win32.WINAPI) win32.HRESULT;

extern "uxtheme" fn BufferedPaintClear(
    hBufferedPaint: HPAINTBUFFER,
    prc: *const win32.RECT,
) callconv(win32.WINAPI) win32.HRESULT;

//=== File dialogs ===//

pub const OPENFILENAMEW = extern struct {
    lStructSize: win32.DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?win32.HWND = null,
    hInstance: ?win32.HINSTANCE = null,
    lpstrFilter: ?win32.LPCWSTR = null,
    lpstrCustomFilter: ?win32.LPWSTR = null,
    nMaxCustFilter: win32.DWORD = 0,
    nFilterIndex: win32.DWORD = 0,
    lpstrFile: win32.LPWSTR,
    nMaxFile: win32.DWORD,
    lpstrFileTitle: ?win32.LPWSTR = null,
    nMaxFileTitle: win32.DWORD = 0,
    lpstrInitialDir: ?win32.LPCWSTR = null,
    lpstrTitle: ?win32.LPCWSTR = null,
    Flags: win32.DWORD = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?win32.LPCWSTR = null,
    lCustData: win32.LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?win32.LPCWSTR = null,
    _mac_fields: MacFields = .{},
    _w2k_fields: Win2kFields = .{},
    FlagsEx: win32.DWORD = 0,

    // #if (_WIN32_WINNT >= 0x0500)
    const Win2kFields = if (builtin.os.isAtLeast(.windows, .win2k) orelse unreachable)
        packed struct { pvReserved: ?*anyopaque = null, dwReserved: win32.DWORD = 0 }
    else
        packed struct {};

    // #ifdef _MAC
    const _MAC = false;
    const MacFields = if (_MAC)
        packed struct { lpEditInfo: ?*anyopaque = null, lpstrPrompt: ?win32.LPCSTR = null }
    else
        packed struct {};
};

pub fn getOpenFileName(ofn: *OPENFILENAMEW) Error!bool {
    std.debug.assert(ofn.lStructSize == @sizeOf(OPENFILENAMEW));

    if (GetOpenFileNameW(ofn) == win32.TRUE) return true;

    const err = CommDlgExtendedError();
    if (err == 0) return false;

    // TODO (Matteo): Translate errors
    return error.Win32Error;
}

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(win32.WINAPI) win32.BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(win32.WINAPI) u32;
