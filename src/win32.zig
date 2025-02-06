const std = @import("std");
const builtin = @import("builtin");
const win32 = std.os.windows;
const assert = std.debug.assert;

//=== Re-exports ===//

pub usingnamespace win32;

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

pub inline fn loadProc(
    comptime T: type,
    comptime name: [*:0]const u8,
    handle: win32.HMODULE,
) Error!T {
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

pub inline fn getWindowRect(win: win32.HWND) win32.RECT {
    var rect: win32.RECT = undefined;
    const result = GetWindowRect(win, &rect);
    assert(result != 0);
    return rect;
}

extern "user32" fn GetWindowRect(
    hwnd: win32.HWND,
    rect_ptr: *win32.RECT,
) callconv(win32.WINAPI) win32.BOOL;

pub fn getDC(hwnd: win32.HWND) !win32.HDC {
    return GetDC(hwnd) orelse error.Unexpected;
}
extern "user32" fn GetDC(hwnd: win32.HWND) callconv(win32.WINAPI) ?win32.HDC;

pub fn releaseDC(hwnd: win32.HWND, hdc: win32.HDC) bool {
    return ReleaseDC(hwnd, hdc) == 1;
}
extern "user32" fn ReleaseDC(hwnd: win32.HWND, hdc: win32.HDC) callconv(win32.WINAPI) c_int;

pub inline fn getCursorPos() win32.POINT {
    var point: win32.POINT = undefined;
    const result = GetCursorPos(&point);
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
    assert(result == win32.TRUE);
    return client_point;
}

pub inline fn pointToScreen(win: win32.HWND, client_point: win32.POINT) win32.POINT {
    var screen_point: win32.POINT = client_point;
    const result = ClientToScreen(win, &screen_point);
    assert(result == win32.TRUE);
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

pub const DisplayInfo = struct {
    width: u32,
    height: u32,
    bitsPerPixel: u32,
    frequency: u32,
    flags: u32,
};

pub fn getDisplayInfo() !DisplayInfo {
    var devmode = std.mem.zeroInit(DEVMODEW, .{ .dmSize = @sizeOf(DEVMODEW) });

    if (EnumDisplaySettingsW(null, -1, &devmode) == win32.TRUE) {
        return DisplayInfo{
            .width = devmode.dmPelsWidth,
            .height = devmode.dmPelsHeight,
            .bitsPerPixel = devmode.dmBitsPerPel,
            .frequency = devmode.dmDisplayFrequency,
            .flags = devmode.dmDisplayFlags,
        };
    }

    return error.Unexpected;
}

extern "user32" fn EnumDisplaySettingsW(
    lpszDeviceName: ?win32.LPCWSTR,
    iModeNum: i32,
    lpDevMode: [*c]DEVMODEW,
) callconv(win32.WINAPI) win32.BOOL;

const DEVMODEW = extern struct {
    dmDeviceName: [32]u16,
    dmSpecVersion: u16,
    dmDriverVersion: u16,
    dmSize: u16,
    dmDriverExtra: u16,
    dmFields: u32,
    dmPosition: win32.POINT,
    dmDisplayOrientation: u32,
    dmDisplayFixedOutput: u32,
    dmColor: c_short,
    dmDuplex: c_short,
    dmYResolution: c_short,
    dmTTOption: c_short,
    dmCollate: c_short,
    dmFormName: [32]u16,
    dmLogPixels: u16,
    dmBitsPerPel: u32,
    dmPelsWidth: u32,
    dmPelsHeight: u32,
    dmDisplayFlags: u32,
    dmDisplayFrequency: u32,
    dmICMMethod: u32,
    dmICMIntent: u32,
    dmMediaType: u32,
    dmDitherType: u32,
    dmReserved1: u32,
    dmReserved2: u32,
    dmPanningWidth: u32,
    dmPanningHeight: u32,
};

// === Windows ===

pub const WM_NULL = 0x0000;
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_ENABLE = 0x000A;
pub const WM_SETREDRAW = 0x000B;
pub const WM_SETTEXT = 0x000C;
pub const WM_GETTEXT = 0x000D;
pub const WM_GETTEXTLENGTH = 0x000E;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUERYENDSESSION = 0x0011;
pub const WM_QUIT = 0x0012;
pub const WM_QUERYOPEN = 0x0013;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SYSCOLORCHANGE = 0x0015;
pub const WM_ENDSESSION = 0x0016;
pub const WM_SHOWWINDOW = 0x0018;
pub const WM_CTLCOLOR = 0x0019;
pub const WM_WININICHANGE = 0x001A;
pub const WM_DEVMODECHANGE = 0x001B;
pub const WM_ACTIVATEAPP = 0x001C;
pub const WM_FONTCHANGE = 0x001D;
pub const WM_TIMECHANGE = 0x001E;
pub const WM_CANCELMODE = 0x001F;
pub const WM_SETCURSOR = 0x0020;
pub const WM_MOUSEACTIVATE = 0x0021;
pub const WM_CHILDACTIVATE = 0x0022;
pub const WM_QUEUESYNC = 0x0023;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_PAINTICON = 0x0026;
pub const WM_ICONERASEBKGND = 0x0027;
pub const WM_NEXTDLGCTL = 0x0028;
pub const WM_SPOOLERSTATUS = 0x002A;
pub const WM_DRAWITEM = 0x002B;
pub const WM_MEASUREITEM = 0x002C;
pub const WM_DELETEITEM = 0x002D;
pub const WM_VKEYTOITEM = 0x002E;
pub const WM_CHARTOITEM = 0x002F;
pub const WM_SETFONT = 0x0030;
pub const WM_GETFONT = 0x0031;
pub const WM_SETHOTKEY = 0x0032;
pub const WM_GETHOTKEY = 0x0033;
pub const WM_QUERYDRAGICON = 0x0037;
pub const WM_COMPAREITEM = 0x0039;
pub const WM_GETOBJECT = 0x003D;
pub const WM_COMPACTING = 0x0041;
pub const WM_COMMNOTIFY = 0x0044;
pub const WM_WINDOWPOSCHANGING = 0x0046;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_POWER = 0x0048;
pub const WM_COPYGLOBALDATA = 0x0049;
pub const WM_COPYDATA = 0x004A;
pub const WM_CANCELJOURNAL = 0x004B;
pub const WM_NOTIFY = 0x004E;
pub const WM_INPUTLANGCHANGEREQUEST = 0x0050;
pub const WM_INPUTLANGCHANGE = 0x0051;
pub const WM_TCARD = 0x0052;
pub const WM_HELP = 0x0053;
pub const WM_USERCHANGED = 0x0054;
pub const WM_NOTIFYFORMAT = 0x0055;
pub const WM_CONTEXTMENU = 0x007B;
pub const WM_STYLECHANGING = 0x007C;
pub const WM_STYLECHANGED = 0x007D;
pub const WM_DISPLAYCHANGE = 0x007E;
pub const WM_GETICON = 0x007F;
pub const WM_SETICON = 0x0080;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCDESTROY = 0x0082;
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCPAINT = 0x0085;
pub const WM_NCACTIVATE = 0x0086;
pub const WM_GETDLGCODE = 0x0087;
pub const WM_SYNCPAINT = 0x0088;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCLBUTTONDBLCLK = 0x00A3;
pub const WM_NCRBUTTONDOWN = 0x00A4;
pub const WM_NCRBUTTONUP = 0x00A5;
pub const WM_NCRBUTTONDBLCLK = 0x00A6;
pub const WM_NCMBUTTONDOWN = 0x00A7;
pub const WM_NCMBUTTONUP = 0x00A8;
pub const WM_NCMBUTTONDBLCLK = 0x00A9;
pub const WM_NCXBUTTONDOWN = 0x00AB;
pub const WM_NCXBUTTONUP = 0x00AC;
pub const WM_NCXBUTTONDBLCLK = 0x00AD;
pub const WM_INPUT = 0x00FF;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_UNICHAR = 0x0109;
pub const WM_WNT_CONVERTREQUESTEX = 0x0109;
pub const WM_CONVERTREQUEST = 0x010A;
pub const WM_CONVERTRESULT = 0x010B;
pub const WM_INTERIM = 0x010C;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_INITDIALOG = 0x0110;
pub const WM_COMMAND = 0x0111;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_HSCROLL = 0x0114;
pub const WM_VSCROLL = 0x0115;
pub const WM_INITMENU = 0x0116;
pub const WM_INITMENUPOPUP = 0x0117;
pub const WM_SYSTIMER = 0x0118;
pub const WM_MENUSELECT = 0x011F;
pub const WM_MENUCHAR = 0x0120;
pub const WM_ENTERIDLE = 0x0121;
pub const WM_MENURBUTTONUP = 0x0122;
pub const WM_MENUDRAG = 0x0123;
pub const WM_MENUGETOBJECT = 0x0124;
pub const WM_UNINITMENUPOPUP = 0x0125;
pub const WM_MENUCOMMAND = 0x0126;
pub const WM_CHANGEUISTATE = 0x0127;
pub const WM_UPDATEUISTATE = 0x0128;
pub const WM_QUERYUISTATE = 0x0129;
pub const WM_CTLCOLORMSGBOX = 0x0132;
pub const WM_CTLCOLOREDIT = 0x0133;
pub const WM_CTLCOLORLISTBOX = 0x0134;
pub const WM_CTLCOLORBTN = 0x0135;
pub const WM_CTLCOLORDLG = 0x0136;
pub const WM_CTLCOLORSCROLLBAR = 0x0137;
pub const WM_CTLCOLORSTATIC = 0x0138;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MBUTTONDBLCLK = 0x0209;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_XBUTTONDBLCLK = 0x020D;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_PARENTNOTIFY = 0x0210;
pub const WM_ENTERMENULOOP = 0x0211;
pub const WM_EXITMENULOOP = 0x0212;
pub const WM_NEXTMENU = 0x0213;
pub const WM_SIZING = 0x0214;
pub const WM_CAPTURECHANGED = 0x0215;
pub const WM_MOVING = 0x0216;
pub const WM_POWERBROADCAST = 0x0218;
pub const WM_DEVICECHANGE = 0x0219;
pub const WM_MDICREATE = 0x0220;
pub const WM_MDIDESTROY = 0x0221;
pub const WM_MDIACTIVATE = 0x0222;
pub const WM_MDIRESTORE = 0x0223;
pub const WM_MDINEXT = 0x0224;
pub const WM_MDIMAXIMIZE = 0x0225;
pub const WM_MDITILE = 0x0226;
pub const WM_MDICASCADE = 0x0227;
pub const WM_MDIICONARRANGE = 0x0228;
pub const WM_MDIGETACTIVE = 0x0229;
pub const WM_MDISETMENU = 0x0230;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const WM_DROPFILES = 0x0233;
pub const WM_MDIREFRESHMENU = 0x0234;
pub const WM_IME_REPORT = 0x0280;
pub const WM_IME_SETCONTEXT = 0x0281;
pub const WM_IME_NOTIFY = 0x0282;
pub const WM_IME_CONTROL = 0x0283;
pub const WM_IME_COMPOSITIONFULL = 0x0284;
pub const WM_IME_SELECT = 0x0285;
pub const WM_IME_CHAR = 0x0286;
pub const WM_IME_REQUEST = 0x0288;
pub const WM_IMEKEYDOWN = 0x0290;
pub const WM_IME_KEYDOWN = 0x0290;
pub const WM_IMEKEYUP = 0x0291;
pub const WM_IME_KEYUP = 0x0291;
pub const WM_NCMOUSEHOVER = 0x02A0;
pub const WM_MOUSEHOVER = 0x02A1;
pub const WM_NCMOUSELEAVE = 0x02A2;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_CUT = 0x0300;
pub const WM_COPY = 0x0301;
pub const WM_PASTE = 0x0302;
pub const WM_CLEAR = 0x0303;
pub const WM_UNDO = 0x0304;
pub const WM_RENDERFORMAT = 0x0305;
pub const WM_RENDERALLFORMATS = 0x0306;
pub const WM_DESTROYCLIPBOARD = 0x0307;
pub const WM_DRAWCLIPBOARD = 0x0308;
pub const WM_PAINTCLIPBOARD = 0x0309;
pub const WM_VSCROLLCLIPBOARD = 0x030A;
pub const WM_SIZECLIPBOARD = 0x030B;
pub const WM_ASKCBFORMATNAME = 0x030C;
pub const WM_CHANGECBCHAIN = 0x030D;
pub const WM_HSCROLLCLIPBOARD = 0x030E;
pub const WM_QUERYNEWPALETTE = 0x030F;
pub const WM_PALETTEISCHANGING = 0x0310;
pub const WM_PALETTECHANGED = 0x0311;
pub const WM_HOTKEY = 0x0312;
pub const WM_PRINT = 0x0317;
pub const WM_PRINTCLIENT = 0x0318;
pub const WM_APPCOMMAND = 0x0319;
pub const WM_RCRESULT = 0x0381;
pub const WM_HOOKRCRESULT = 0x0382;
pub const WM_GLOBALRCCHANGE = 0x0383;
pub const WM_PENMISCINFO = 0x0383;
pub const WM_SKB = 0x0384;
pub const WM_HEDITCTL = 0x0385;
pub const WM_PENCTL = 0x0385;
pub const WM_PENMISC = 0x0386;
pub const WM_CTLINIT = 0x0387;
pub const WM_PENEVENT = 0x0388;
pub const WM_CARET_CREATE = 0x03E0;
pub const WM_CARET_DESTROY = 0x03E1;
pub const WM_CARET_BLINK = 0x03E2;
pub const WM_FDINPUT = 0x03F0;
pub const WM_FDOUTPUT = 0x03F1;
pub const WM_FDEXCEPT = 0x03F2;

pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_DBLCLKS = 0x0008;
pub const CS_OWNDC = 0x0020;
pub const CS_CLASSDC = 0x0040;
pub const CS_PARENTDC = 0x0080;
pub const CS_NOCLOSE = 0x0200;
pub const CS_SAVEBITS = 0x0800;
pub const CS_BYTEALIGNCLIENT = 0x1000;
pub const CS_BYTEALIGNWINDOW = 0x2000;
pub const CS_GLOBALCLASS = 0x4000;

pub const WS_OVERLAPPED = 0x00000000;
pub const WS_POPUP = 0x80000000;
pub const WS_CHILD = 0x40000000;
pub const WS_MINIMIZE = 0x20000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_DISABLED = 0x08000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_MAXIMIZE = 0x01000000;
pub const WS_CAPTION = WS_BORDER | WS_DLGFRAME;
pub const WS_BORDER = 0x00800000;
pub const WS_DLGFRAME = 0x00400000;
pub const WS_VSCROLL = 0x00200000;
pub const WS_HSCROLL = 0x00100000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_GROUP = 0x00020000;
pub const WS_TABSTOP = 0x00010000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_TILED = WS_OVERLAPPED;
pub const WS_ICONIC = WS_MINIMIZE;
pub const WS_SIZEBOX = WS_THICKFRAME;
pub const WS_TILEDWINDOW = WS_OVERLAPPEDWINDOW;
pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_POPUPWINDOW = WS_POPUP | WS_BORDER | WS_SYSMENU;
pub const WS_CHILDWINDOW = WS_CHILD;

pub const WS_EX_DLGMODALFRAME = 0x00000001;
pub const WS_EX_NOPARENTNOTIFY = 0x00000004;
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_ACCEPTFILES = 0x00000010;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const WS_EX_MDICHILD = 0x00000040;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_WINDOWEDGE = 0x00000100;
pub const WS_EX_CLIENTEDGE = 0x00000200;
pub const WS_EX_CONTEXTHELP = 0x00000400;
pub const WS_EX_RIGHT = 0x00001000;
pub const WS_EX_LEFT = 0x00000000;
pub const WS_EX_RTLREADING = 0x00002000;
pub const WS_EX_LTRREADING = 0x00000000;
pub const WS_EX_LEFTSCROLLBAR = 0x00004000;
pub const WS_EX_RIGHTSCROLLBAR = 0x00000000;
pub const WS_EX_CONTROLPARENT = 0x00010000;
pub const WS_EX_STATICEDGE = 0x00020000;
pub const WS_EX_APPWINDOW = 0x00040000;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_OVERLAPPEDWINDOW = WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE;
pub const WS_EX_PALETTEWINDOW = WS_EX_WINDOWEDGE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_NORMAL = 1;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_SHOWMAXIMIZED = 3;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_SHOWMINNOACTIVE = 7;
pub const SW_SHOWNA = 8;
pub const SW_RESTORE = 9;
pub const SW_SHOWDEFAULT = 10;
pub const SW_FORCEMINIMIZE = 11;
pub const SW_MAX = 11;

pub const WNDPROC = *const fn (
    hwnd: win32.HWND,
    uMsg: c_uint,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(win32.WINAPI) win32.LRESULT;

pub const MSG = extern struct {
    hWnd: ?win32.HWND,
    message: c_uint,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
    time: u32,
    pt: win32.POINT,
    lPrivate: u32,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: c_uint = @sizeOf(WNDCLASSEXW),
    style: c_uint,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: win32.HINSTANCE,
    hIcon: ?win32.HICON,
    hCursor: ?win32.HCURSOR,
    hbrBackground: ?win32.HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?win32.HICON,
};

pub fn registerClassExW(window_class: *const WNDCLASSEXW) !win32.ATOM {
    const atom = RegisterClassExW(window_class);
    if (atom == 0) return error.Unexpected;
    return atom;
}
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(win32.WINAPI) win32.ATOM;

pub fn unregisterClassW(name: win32.LPCWSTR, instance: win32.HINSTANCE) !void {
    const res = UnregisterClassW(name, instance);
    if (res == win32.FALSE) return error.Unexpected;
}
extern "user32" fn UnregisterClassW(
    name: win32.LPCWSTR,
    instance: win32.HINSTANCE,
) callconv(win32.WINAPI) win32.BOOL;

pub fn createWindowExW(
    dwExStyle: u32,
    lpClassName: win32.LPCWSTR,
    lpWindowName: win32.LPCWSTR,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWindParent: ?win32.HWND,
    hMenu: ?win32.HMENU,
    hInstance: win32.HINSTANCE,
    lpParam: ?win32.LPVOID,
) !win32.HWND {
    const window = CreateWindowExW(
        dwExStyle,
        lpClassName,
        lpWindowName,
        dwStyle,
        X,
        Y,
        nWidth,
        nHeight,
        hWindParent,
        hMenu,
        hInstance,
        lpParam,
    );
    if (window) |win| return win;
    return error.Unexpected;
}
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: win32.LPCWSTR,
    lpWindowName: win32.LPCWSTR,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWindParent: ?win32.HWND,
    hMenu: ?win32.HMENU,
    hInstance: win32.HINSTANCE,
    lpParam: ?win32.LPVOID,
) callconv(win32.WINAPI) ?win32.HWND;

pub inline fn destroyWindow(win: win32.HWND) !void {
    if (DestroyWindow(win) == win32.FALSE) return error.Unexpected;
}
extern "user32" fn DestroyWindow(win: win32.HWND) callconv(win32.WINAPI) win32.BOOL;

pub fn showWindow(hWnd: win32.HWND, nCmdShow: i32) bool {
    return (ShowWindow(hWnd, nCmdShow) == win32.TRUE);
}
extern "user32" fn ShowWindow(hWnd: win32.HWND, nCmdShow: i32) callconv(win32.WINAPI) win32.BOOL;

pub fn updateWindow(hWnd: win32.HWND) !void {
    if (UpdateWindow(hWnd) == win32.FALSE) return error.Unexpected;
}
extern "user32" fn UpdateWindow(hWnd: win32.HWND) callconv(win32.WINAPI) win32.BOOL;

pub fn getWindowUserPtr(win: win32.HWND, comptime T: type) !*T {
    const long = GetWindowLongPtrW(win, -21);
    if (long == 0) return error.Unexpected;

    const addr: usize = @intCast(long);
    return @ptrFromInt(addr);
}
extern "user32" fn GetWindowLongPtrW(hWnd: win32.HWND, nIndex: i32) callconv(win32.WINAPI) isize;

pub fn setWindowUserPtr(win: win32.HWND, comptime T: type, ptr: *T) !void {
    win32.kernel32.SetLastError(.SUCCESS);

    const addr = @intFromPtr(ptr);
    const res = SetWindowLongPtrW(win, -21, @intCast(addr));
    if (res == 0) {
        const err = win32.kernel32.GetLastError();
        if (err != .SUCCESS) {
            win32.kernel32.SetLastError(err);
            return error.Unexpected;
        }
    }
}
extern "user32" fn SetWindowLongPtrW(hWnd: win32.HWND, nIndex: i32, dwNewLong: isize) callconv(win32.WINAPI) isize;

pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(win32.WINAPI) void;

pub inline fn waitMessage() !void {
    const res = WaitMessage();
    if (res == 0) return error.Unexpected;
}
extern "user32" fn WaitMessage() callconv(win32.WINAPI) win32.BOOL;

pub fn getMessageW(lpMsg: *MSG, hWnd: ?win32.HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) !void {
    const res = GetMessageW(lpMsg, hWnd, wMsgFilterMin, wMsgFilterMax);
    if (res == win32.FALSE) return error.Quit;
    if (res < 0) return error.Unexpected;
}
extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?win32.HWND,
    wMsgFilterMin: c_uint,
    wMsgFilterMax: c_uint,
) callconv(win32.WINAPI) win32.BOOL;

pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;
pub const PM_NOYIELD = 0x0002;

pub extern "user32" fn PeekMessageW(
    msg: *MSG,
    wnd: ?win32.HWND,
    wMsgFilterMin: c_uint,
    wMsgFilterMax: c_uint,
    wRemoveMsg: c_uint,
) callconv(win32.WINAPI) win32.BOOL;

pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(win32.WINAPI) win32.BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(win32.WINAPI) win32.LRESULT;

pub extern "user32" fn DefWindowProcW(
    hWnd: win32.HWND,
    Msg: c_uint,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(win32.WINAPI) win32.LRESULT;

// === Modal dialogue boxes ===

pub const MB_OK = 0x00000000;
pub const MB_OKCANCEL = 0x00000001;
pub const MB_ABORTRETRYIGNORE = 0x00000002;
pub const MB_YESNOCANCEL = 0x00000003;
pub const MB_YESNO = 0x00000004;
pub const MB_RETRYCANCEL = 0x00000005;
pub const MB_CANCELTRYCONTINUE = 0x00000006;
pub const MB_ICONHAND = 0x00000010;
pub const MB_ICONQUESTION = 0x00000020;
pub const MB_ICONEXCLAMATION = 0x00000030;
pub const MB_ICONASTERISK = 0x00000040;
pub const MB_USERICON = 0x00000080;
pub const MB_ICONWARNING = MB_ICONEXCLAMATION;
pub const MB_ICONERROR = MB_ICONHAND;
pub const MB_ICONINFORMATION = MB_ICONASTERISK;
pub const MB_ICONSTOP = MB_ICONHAND;
pub const MB_DEFBUTTON1 = 0x00000000;
pub const MB_DEFBUTTON2 = 0x00000100;
pub const MB_DEFBUTTON3 = 0x00000200;
pub const MB_DEFBUTTON4 = 0x00000300;
pub const MB_APPLMODAL = 0x00000000;
pub const MB_SYSTEMMODAL = 0x00001000;
pub const MB_TASKMODAL = 0x00002000;
pub const MB_HELP = 0x00004000;
pub const MB_NOFOCUS = 0x00008000;
pub const MB_SETFOREGROUND = 0x00010000;
pub const MB_DEFAULT_DESKTOP_ONLY = 0x00020000;
pub const MB_TOPMOST = 0x00040000;
pub const MB_RIGHT = 0x00080000;
pub const MB_RTLREADING = 0x00100000;
pub const MB_TYPEMASK = 0x0000000F;
pub const MB_ICONMASK = 0x000000F0;
pub const MB_DEFMASK = 0x00000F00;
pub const MB_MODEMASK = 0x00003000;
pub const MB_MISCMASK = 0x0000C000;

pub extern "user32" fn MessageBoxW(
    win: ?win32.HWND,
    text: win32.LPCWSTR,
    caption: win32.LPCWSTR,
    flags: c_uint,
) callconv(win32.WINAPI) i32;

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

    const len = FormatMessageW(
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
        @as(c_uint, @intCast(mem.len)),
    ) orelse error.Unexpected;
}

extern "shlwapi" fn SHCreateMemStream(
    pInit: [*]const u8,
    cbInit: c_uint,
) callconv(win32.WINAPI) ?*IStream;

//=== Console ===//

pub extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(win32.WINAPI) win32.BOOL;
pub extern "kernel32" fn AllocConsole() callconv(win32.WINAPI) win32.BOOL;
pub extern "kernel32" fn FreeConsole() callconv(win32.WINAPI) win32.BOOL;
pub extern "kernel32" fn SetConsoleTitleW(lpConsoleTitle: win32.LPCWSTR) callconv(win32.WINAPI) win32.BOOL;
