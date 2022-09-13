const std = @import("std");
const win32 = std.os.windows;

//=== Re-exports ===//

pub usingnamespace win32;
pub usingnamespace win32.user32;

//=== Misc utilities ===//

/// Emulates the L prefix used in C for "wide" string literals
pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Returns the HINSTANCE corresponding to the process executable
pub fn getCurrentInstance() Error!win32.HINSTANCE {
    return @ptrCast(
        win32.HINSTANCE,
        win32.kernel32.GetModuleHandleW(null) orelse return getLastError(),
    );
}

//=== Error handling ===//

pub const Error = std.os.UnexpectedError;

/// Converts the error code returned by GetLastError in a Zig error.
pub inline fn getLastError() Error {
    traceError(GetLastError(), "GetLastError()");
    return error.Unexpected;
}

inline fn traceHr(hr: win32.HRESULT) void {
    traceError(@intCast(win32.DWORD, hr), "HRESULT");
}

fn traceError(err: u32, comptime src: []const u8) void {
    // Derived from std.os.unexpected error
    if (std.os.unexpected_error_tracing) {
        // 614 is the length of the longest windows error desciption
        var buf_wstr: [614]u16 = undefined;
        var buf_utf8: [614]u8 = undefined;

        const len = FormatMessageW(
            win32.FORMAT_MESSAGE_FROM_SYSTEM | win32.FORMAT_MESSAGE_IGNORE_INSERTS,
            null,
            err,
            (0x01 << 10), // MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
            &buf_wstr,
            buf_wstr.len,
            null,
        );

        if (len != 0) {
            _ = std.unicode.utf16leToUtf8(&buf_utf8, buf_wstr[0..len]) catch unreachable;
            std.debug.print("Win32 " ++ src ++ " = {x}: {s}\n", .{ err, buf_utf8[0..len] });
        }

        std.debug.dumpCurrentStackTrace(null);
    }
}

extern "kernel32" fn GetLastError() callconv(win32.WINAPI) u32;

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
    return LoadCursorW(null, name) orelse getLastError();
}

extern "user32" fn LoadCursorW(
    hinst: ?win32.HINSTANCE,
    cursor_name: win32.LPCWSTR,
) callconv(win32.WINAPI) ?win32.HCURSOR;

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
            traceHr(hr);
            return error.Unexpected;
        }
    }
};

pub inline fn initBufferedPaint() Error!void {
    const hr = BufferedPaintInit();
    if (hr != 0) {
        traceHr(hr);
        return error.Unexpected;
    }
}

pub inline fn deinitBufferedPaint() void {
    const hr = BufferedPaintUnInit();
    if (hr != 0) {
        traceHr(hr);
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

    return getLastError();
}

pub inline fn endBufferedPaint(win: win32.HWND, pb: PaintBuffer) Error!void {
    const hr = EndBufferedPaint(pb.pb, win32.TRUE);
    if (hr != 0) {
        traceError(GetLastError(), "HRESULT");
        return error.Unexpected;
    }

    if (EndPaint(win, &pb.ps) != win32.TRUE) return getLastError();
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
