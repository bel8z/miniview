/// GDI+ wrapper
const win32 = @import("win32.zig");
const L = win32.L;

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

const GdiplusStartup = *const fn (
    token: *win32.ULONG_PTR,
    input: *const GdiplusStartupInput,
    output: *GdiplusStartupOutput,
) callconv(WINGDIPAPI) Status;

const GdiplusShutdown = *const fn (
    token: win32.ULONG_PTR,
) callconv(WINGDIPAPI) void;

const GdipCreateBitmapFromStream = *const fn (
    stream: *win32.IStream,
    image: **Image,
) callconv(WINGDIPAPI) Status;

const GdipDisposeImage = *const fn (image: *Image) callconv(WINGDIPAPI) Status;

const GdipGetImageDimension = *const fn (
    image: *Image,
    width: *f32,
    height: *f32,
) callconv(WINGDIPAPI) Status;

const GdipCreateFromHDC = *const fn (
    hdc: win32.HDC,
    graphics: **Graphics,
) callconv(WINGDIPAPI) Status;

const GdipDeleteGraphics = *const fn (graphics: *Graphics) callconv(WINGDIPAPI) Status;
const GdipGraphicsClear = *const fn (graphics: *Graphics, color: u32) callconv(WINGDIPAPI) Status;

const GdipDrawImageRect = *const fn (
    graphics: *Graphics,
    image: *Image,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) callconv(WINGDIPAPI) Status;

const GdipSetInterpolationMode = *const fn (
    graphics: *Graphics,
    mode: InterpolationMode,
) callconv(WINGDIPAPI) Status;

var dll: win32.HMODULE = undefined;
var token: win32.ULONG_PTR = 0;
var shutdown: GdiplusShutdown = undefined;

pub var createImageFromStream: GdipCreateBitmapFromStream = undefined;
pub var disposeImage: GdipDisposeImage = undefined;
pub var getImageDimension: GdipGetImageDimension = undefined;
pub var createFromHDC: GdipCreateFromHDC = undefined;
pub var deleteGraphics: GdipDeleteGraphics = undefined;
pub var graphicsClear: GdipGraphicsClear = undefined;
pub var drawImageRect: GdipDrawImageRect = undefined;
pub var setInterpolationMode: GdipSetInterpolationMode = undefined;

pub fn init() Error!void {
    dll = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse return error.Unexpected;
    createImageFromStream = try win32.loadProc(GdipCreateBitmapFromStream, "GdipCreateBitmapFromStream", dll);
    disposeImage = try win32.loadProc(GdipDisposeImage, "GdipDisposeImage", dll);
    getImageDimension = try win32.loadProc(GdipGetImageDimension, "GdipGetImageDimension", dll);
    createFromHDC = try win32.loadProc(GdipCreateFromHDC, "GdipCreateFromHDC", dll);
    deleteGraphics = try win32.loadProc(GdipDeleteGraphics, "GdipDeleteGraphics", dll);
    graphicsClear = try win32.loadProc(GdipGraphicsClear, "GdipGraphicsClear", dll);
    drawImageRect = try win32.loadProc(GdipDrawImageRect, "GdipDrawImageRect", dll);
    setInterpolationMode = try win32.loadProc(GdipSetInterpolationMode, "GdipSetInterpolationMode", dll);
    shutdown = try win32.loadProc(GdiplusShutdown, "GdiplusShutdown", dll);

    const startup = try win32.loadProc(GdiplusStartup, "GdiplusStartup", dll);
    const input = GdiplusStartupInput{};
    var output: GdiplusStartupOutput = undefined;
    const status = startup(&token, &input, &output);
    try checkStatus(status);
}

pub fn deinit() void {
    shutdown(token);
}

pub inline fn checkStatus(status: Status) Error!void {
    switch (status) {
        0 => return,
        1 => return error.GenericError,
        2 => return error.InvalidParameter,
        3 => return error.OutOfMemory,
        4 => return error.ObjectBusy,
        5 => return error.InsufficientBuffer,
        6 => return error.NotImplemented,
        7 => return error.Unexpected,
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
        else => return error.Unexpected,
    }
}
