const std = @import("std");
const win32 = @import("win32.zig");
const L = win32.L;

const WINGDIPAPI = win32.WINAPI;

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

const GpImage = opaque {};

pub const Env = struct {
    handle: win32.HMODULE,
    token: win32.ULONG_PTR,
    startup: GdiplusStartup,
    shutdown: GdiplusShutdown,
    load: GdipLoadImageFromFile,

    pub fn init() !Env {
        var env: Env = undefined;

        env.handle = win32.kernel32.LoadLibraryW(L("Gdiplus")) orelse
            return win32.getLastError();

        env.startup = try loadProc(GdiplusStartup, "GdiplusStartu", env.handle);
        env.shutdown = try loadProc(GdiplusShutdown, "GdiplusShutdown", env.handle);
        env.load = try loadProc(GdipLoadImageFromFile, "GdipLoadImageFromFile", env.handle);

        const input = GdiplusStartupInput{};
        var output: GdiplusStartupOutput = undefined;
        const status = env.startup(&env.token, &input, &output);
        std.debug.assert(status == 0);

        return env;
    }

    pub fn deinit(env: *Env) void {
        _ = env.shutdown(env.token);
        _ = win32.kernel32.FreeLibrary(env.handle);
    }

    pub fn loadImage(env: *Env, filename: []const u8) !*GpImage {
        var buffer: [1024]u8 = undefined;
        var alloc = std.heap.FixedBufferAllocator.init(buffer[0..]);
        const path = try std.unicode.utf8ToUtf16LeWithNull(alloc.allocator(), filename);

        var image: *GpImage = undefined;
        const status = env.load(path, &image);
        if (status != 0) return mapError(status);

        return image;
    }
};

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
const GdipLoadImageFromFile = fn (filename: win32.LPCWSTR, image: **GpImage) callconv(WINGDIPAPI) Status;

inline fn loadProc(comptime T: type, comptime name: [*:0]const u8, handle: win32.HMODULE) !T {
    return @ptrCast(T, win32.kernel32.GetProcAddress(handle, name) orelse
        return win32.getLastError());
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
