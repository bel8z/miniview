const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const unicode = std.unicode;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const win32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const Memory = @import("Memory.zig");

const L = win32.L;

// TODO (Matteo):
// - Cleanup string management (UTF8 <=> UTF16) ... in progress
// - Review image storage with async loading
// - Cleanup memory management
// - Cleanup panic handling and error reporting in general

//=== Constants ===//

const app_name = L("MiniView");

// NOTE (Matteo): This looks a bit strange but is a cool way to build the
// list of supported extensions and the dialog filter string at comptime
const filter = "*.bmp;*.png;*.jpg;*.jpeg;*.tiff";
const extensions = init: {
    comptime var temp: [5][]const u8 = undefined;
    comptime var tokens = mem.tokenize(u8, filter, ";*");
    comptime var index: usize = 0;
    inline while (tokens.next()) |token| {
        temp[index] = token;
        index += 1;
    }
    assert(index == temp.len);
    break :init temp;
};

// TODO (Matteo): 1GB should be enough, right? Mind that on x86 Windows the
// available address space should be 2GB, but reserving that much failed...
const reserved_bytes: usize = 1024 << 20;

// NOTE (Matteo): Max number of images to be cached for faster navigation
const cache_size: ImageStore.Int = 16;

// TODO (Matteo): Prefefetch asynchronously
const prefetch = false;

//=== Application ===//

pub fn main() void {
    // NOTE (Matteo): Errors are not returned from main in order to call our
    // custom 'panic' handler - see below
    var mv = MiniView{};
    mv.run() catch unreachable;
}

pub fn panic(err: []const u8, maybe_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // NOTE (Matteo): Custom panic handler that reports the error via message box
    // This is because win32 apps don't have an associated console by default,
    // so stderr "is not visible".

    const static = struct {
        // NOTE (Matteo): Kept static to allow for growing it without risk of smashing the stack
        var buf: [8192]u8 align(@alignOf(usize)) = undefined;
    };
    var buf = RingBuffer(u8).init(&static.buf);

    {
        var writer = buf.writer();
        writer.print("{s}", .{err}) catch unreachable;

        const win_err = win32.kernel32.GetLastError();
        if (win_err != .SUCCESS) {
            var buf_utf8: [win32.ERROR_SIZE]u8 = undefined;
            writer.print("\n\nGetLastError() =  0x{x}: {s}", .{
                win_err,
                win32.formatError(win_err, &buf_utf8) catch unreachable,
            }) catch unreachable;
        }

        if (maybe_trace) |trace| writer.print("\n{}", .{trace}) catch unreachable;
    }

    // TODO (Matteo): When text is going back and forth between Zig's stdlib and
    // Win32 a lot of UTF8<->UTF16 conversions are involved; maybe we can mitigate
    // this a bit by fully embracing Win32 and UTF16.
    var alloc = FixedBufferAllocator.init(buf.writableSlice(0));
    _ = win32.messageBoxW(
        null,
        unicode.utf8ToUtf16LeWithNull(alloc.allocator(), buf.readableSlice(0)) catch unreachable,
        app_name,
        win32.MB_ICONERROR | win32.MB_OK,
    ) catch unreachable;

    // TODO (Matteo): Use ret_addr for better diagnostics
    _ = ret_addr;

    // NOTE (Matteo): This breaks in debug builds on Windows
    std.os.abort();
}

/// Check if the given file name has a supported image format, based on the extension
fn isSupportedW(filename: [:0]const u16) bool {
    var buf: [256]u8 = undefined;
    const dot = mem.lastIndexOfScalar(u16, filename, '.') orelse return false;
    const len = unicode.utf16leToUtf8(buf[0..], filename[dot..filename.len]) catch return false;
    return isSupportedExt(buf[0..len]);
}

/// Check if the given file extension identifies a supported image file format
fn isSupportedExt(ext: []const u8) bool {
    if (ext.len > 0) {
        for (extensions, 0..) |token, index| {
            _ = index;
            if (std.ascii.eqlIgnoreCase(token, ext)) return true;
        }
    }
    return false;
}

const FileInfo = struct {
    path: PathBuf = .{},
    handle: ImageStore.Handle = .{},

    pub inline fn name(self: *const FileInfo) [:0]const u16 {
        return self.path.name();
    }
};

const PathBuf = struct {
    // Compute aligned buffer size for u16 paths with null termination. Since MAX_PATH should
    // be 260, this should not take a lot of space.
    pub const size = mem.alignForward(usize, win32.MAX_PATH + 1, @alignOf(u16));
    buf: [size]u16 = mem.zeroes([size]u16),
    len: usize = 0,

    pub inline fn name(self: PathBuf) [:0]const u16 {
        self.validate();
        return self.buf[0..self.len :0];
    }

    pub inline fn measure(self: *PathBuf) bool {
        self.len = mem.indexOfScalar(u16, &self.buf, 0) orelse return false;
        return true;
    }

    pub fn validate(self: PathBuf) void {
        assert(self.len <= self.buf.len);
        assert(self.buf[self.len] == 0);
    }
};

// TODO (Matteo): Implement some logic as methods?
const MiniView = struct {
    main_mem: Memory = undefined,
    temp_mem: Memory = undefined,

    win: win32.HWND = undefined,

    images: *ImageStore = undefined,
    files: std.ArrayListUnmanaged(FileInfo) = .{},
    curr_file: usize = 0,
    curr_image: ?*gdip.Image = null,

    debug_buf: []u8 = &[_]u8{},

    const Command = enum(u32) {
        Open = 1,
    };

    /// Allocate memory from the temporary storage
    fn tempAlloc(mv: *MiniView, comptime T: type, size: usize) Memory.Error![]T {
        return mv.temp_mem.alloc(T, size);
    }

    /// Free memory allocated from the temporary storage.
    /// Assert that the allocation is the last one (basic leakage check)
    fn tempFree(mv: *MiniView, slice: anytype) void {
        assert(mv.temp_mem.isLastAllocation(mem.sliceAsBytes(slice)));
        mv.temp_mem.free(slice);
    }

    fn run(mv: *MiniView) anyerror!void {
        // Init memory block
        var reserved_buf = try Memory.rawReserve(reserved_bytes);

        mv.main_mem = Memory.fromReserved(reserved_buf[0 .. reserved_buf.len / 4]);
        mv.temp_mem = Memory.fromReserved(reserved_buf[reserved_buf.len / 4 .. reserved_buf.len / 2]);

        var cache_mem = Memory.fromReserved(reserved_buf[reserved_buf.len / 2 ..]);

        // Allocate persistent data
        if (builtin.mode == .Debug) mv.debug_buf = try mv.main_mem.alloc(u8, 4096);
        mv.images = try ImageStore.init(&cache_mem);

        // Register window class
        const hinst = win32.getCurrentInstance();

        const win_class = win32.WNDCLASSEXW{
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
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

        // Init buffered painting
        try win32.BufferedPaint.init();

        // Init GDI+
        try gdip.init();
        defer gdip.deinit();

        // Create window
        const menu = try win32.createMenu();
        try win32.appendMenu(
            menu,
            .{ .String = .{ .id = @intFromEnum(Command.Open), .str = L("Open") } },
            0,
        );

        const win_flags = win32.WS_OVERLAPPEDWINDOW;
        mv.win = try win32.createWindowExW(
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

        // NOTE (Matteo): Store application pointer to be retrieved by wndProc
        setWindowUserPtr(mv.win, MiniView, mv);

        _ = win32.showWindow(mv.win, win32.SW_SHOWDEFAULT);
        try win32.updateWindow(mv.win);

        win32.DragAcceptFiles(mv.win, win32.TRUE);

        // Handle command line
        {
            const args = win32.getArgs();
            defer win32.freeArgs(args);
            if (args.len > 1) {
                var path = PathBuf{};
                path.len = mem.len(args[1]);
                path.validate();
                mem.copy(u16, path.buf[0..path.len], args[1][0..path.len]);
                try mv.loadFile(path);
            }
        }

        // Main loop
        defer mv.images.clear();

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

    fn wndProc(
        win: win32.HWND,
        msg: u32,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(win32.WINAPI) win32.LRESULT {
        if (getWindowUserPtr(win, MiniView)) |mv| {
            if (mv.processEvent(msg, wparam, lparam) catch unreachable) return 0;
        }
        return win32.defWindowProcW(win, msg, wparam, lparam);
    }

    fn processEvent(
        mv: *MiniView,
        msg: u32,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) !bool {
        _ = lparam;

        switch (msg) {
            win32.WM_CLOSE => try win32.destroyWindow(mv.win),
            win32.WM_DESTROY => win32.PostQuitMessage(0),
            win32.WM_PAINT => {
                const pb = try win32.BufferedPaint.begin(mv.win);
                defer pb.end() catch unreachable;

                // The background is not erased since the given brush is null
                assert(pb.ps.fErase == win32.TRUE);

                try mv.paint(pb.dc, pb.ps.rcPaint);
            },
            win32.WM_COMMAND => {
                if (wparam & 0xffff0000 == 0) {
                    const command = @as(Command, @enumFromInt(wparam & 0xffff));
                    switch (command) {
                        .Open => try mv.open(),
                    }
                }
            },
            win32.WM_KEYDOWN => {
                const file_count = mv.files.items.len;
                if (file_count < 2) return false;
                switch (wparam) {
                    0x25 => mv.curr_file = mv.prevFile(),
                    0x27 => mv.curr_file = mv.nextFile(),
                    else => return false,
                }

                try mv.updateImage();
            },
            win32.WM_DROPFILES => {
                const drop: win32.HDROP = @ptrFromInt(wparam);
                defer win32.DragFinish(drop);

                const drag_count = win32.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);

                if (drag_count == 1) {
                    var path = PathBuf{};
                    path.len = win32.DragQueryFileW(drop, 0, null, 0);
                    path.validate();

                    const actual_len = win32.DragQueryFileW(
                        drop,
                        0,
                        @ptrCast(&path.buf[0]),
                        @intCast(path.buf.len),
                    );
                    assert(actual_len == path.len);

                    try mv.loadFile(path);
                } else {
                    // TODO (Matteo): Print how many files were dropped?
                    _ = try win32.messageBoxW(
                        mv.win,
                        L("Dropping multiple files is not supported"),
                        app_name,
                        0,
                    );
                }

                return true;
            },
            else => return false,
        }

        return true;
    }

    /// Open an image file via modal dialog
    fn open(mv: *MiniView) !void {
        var path = PathBuf{};
        var ptr = @as([*:0]u16, @ptrCast(&path.buf[0]));
        var ofn = win32.OPENFILENAMEW{
            .hwndOwner = mv.win,
            .lpstrFile = ptr,
            .nMaxFile = @as(u32, @intCast(path.buf.len)),
            .lpstrFilter = L("Image files\x00") ++ L(filter) ++ L("\x00"),
        };

        if (try win32.getOpenFileName(&ofn)) {
            if (!path.measure()) return error.InvalidPath;
            try mv.loadFileDirectory(path, ofn.nFileOffset);
        }
    }

    /// Load an image file from explicit path
    fn loadFile(mv: *MiniView, path_buf: PathBuf) !void {
        const path = path_buf.name();

        if (!isSupportedW(path)) {
            try mv.showNotSupported(path);
            return;
        }

        // Split path in file and directory names
        const sep = mem.lastIndexOfScalar(u16, path, '\\') orelse return error.InvalidPath;
        try mv.loadFileDirectory(path_buf, sep + 1);
    }

    /// Load the image file paths for the given directory. Browsing starts at the given file.
    fn loadFileDirectory(
        mv: *MiniView,
        full_path: PathBuf,
        name_offset: usize,
    ) !void {
        // TODO (Matteo): Cleanup
        const file_name = full_path.name()[name_offset..];
        const dir_name = full_path.name()[0..name_offset];

        // Clear list and cache and prepare allocations
        mv.curr_file = 0;
        mv.files.clearRetainingCapacity();
        mv.images.clear();
        var allocator = mv.main_mem.allocator();

        // Prepare pattern for iteration (copy full path, insert wilcard after the directory part and
        // terminate)
        var pattern = full_path;
        pattern.len = name_offset + 1;
        pattern.buf[name_offset] = '*';
        pattern.buf[pattern.len] = 0;
        pattern.validate();

        // Start directory iteration
        // NOTE (Matteo): First file is ".", skip ".." as well
        var data: win32.WIN32_FIND_DATAW = undefined;
        const finder = win32.kernel32.FindFirstFileW(pattern.name(), &data);
        if (finder == win32.INVALID_HANDLE_VALUE) return error.Unexpected;
        _ = win32.kernel32.FindNextFileW(finder, &data);

        // Start iterating
        while (win32.kernel32.FindNextFileW(finder, &data) != 0) {
            const curr_len = mem.indexOfScalar(u16, &data.cFileName, 0) orelse unreachable;
            const curr_name = data.cFileName[0..curr_len :0];

            if (isSupportedW(curr_name)) {
                // Push file to the list
                var file = try mv.files.addOne(allocator);

                // Copy full path
                file.* = .{};
                file.path.len = dir_name.len + curr_name.len;
                file.path.validate();

                // TODO (Matteo): Cleanup
                mem.copy(u16, file.path.buf[0..dir_name.len], dir_name);
                mem.copy(u16, file.path.buf[dir_name.len..file.path.len], curr_name);
                file.path.validate();

                // Update browse index
                if (mem.eql(u16, file.name(), file_name)) {
                    mv.curr_file = mv.files.items.len - 1;
                }
            }
        }

        try mv.updateImage();
    }

    /// Update image to display
    fn updateImage(mv: *MiniView) !void {
        const file_count = mv.files.items.len;
        if (file_count == 0) return;

        assert(mv.curr_file >= 0);

        const file_name = mv.files.items[mv.curr_file].name();

        mv.curr_image = mv.loadInCache(mv.curr_file) catch |err| switch (err) {
            error.InvalidParameter => {
                try showNotSupported(file_name);
                return;
            },
            else => return err,
        };

        if (!win32.invalidateRect(mv.win, null, true)) return error.Unexpected;
        try mv.setTitle(file_name);

        // TODO (Matteo): Prefefetch asynchronously
        if (prefetch) {
            _ = mv.loadInCache(mv.nextFile()) catch {};
            _ = mv.loadInCache(mv.prevFile()) catch {};
        }
    }

    inline fn prevFile(mv: *MiniView) usize {
        const count = mv.files.items.len;
        return if (mv.curr_file == 0) count - 1 else mv.curr_file - 1;
    }

    inline fn nextFile(mv: *MiniView) usize {
        const count = mv.files.items.len;
        return if (mv.curr_file == count - 1) 0 else mv.curr_file + 1;
    }

    /// Display a message box indicating that the given file is not supported
    fn showNotSupported(mv: *MiniView, file_path: [:0]const u16) !void {
        var buf = try mv.tempAlloc(u8, 3 * PathBuf.size);
        defer mv.tempFree(buf);

        const out = try bufPrintW(buf, "File not supported:\n{s}", .{unicode.fmtUtf16le(file_path)});
        _ = try win32.messageBoxW(mv.win, out, app_name, 0);
    }

    /// Build title by composing app name and file path
    fn setTitle(mv: *MiniView, file_name: [:0]const u16) !void {
        var buf_mem = try mv.tempAlloc(u16, app_name.len + file_name.len + 16);
        defer mv.tempFree(buf_mem);

        var buf = RingBuffer(u16).init(buf_mem);
        try buf.write(app_name);
        try buf.write(L(" - "));
        try buf.write(file_name);
        try buf.writeItem(0);
        const title = buf.readableSlice(0)[0 .. buf.readableLength() - 1 :0];

        if (!win32.setWindowText(mv.win, title)) return error.Unexpected;
    }

    // TODO (Matteo): Review image storage
    fn loadInCache(mv: *MiniView, index: usize) !*gdip.Image {
        const file = &mv.files.items[index];
        while (true) {
            if (mv.images.get(file.handle, file.name())) |image| return image;
            file.handle = mv.images.new();
        }
    }

    fn paint(mv: *MiniView, dc: win32.HDC, rect: win32.RECT) !void {
        var gfx: *gdip.Graphics = undefined;
        try gdip.checkStatus(gdip.createFromHDC(dc, &gfx));
        defer gdip.checkStatus(gdip.deleteGraphics(gfx)) catch unreachable;

        try gdip.checkStatus(gdip.graphicsClear(gfx, 0xFFF0F0F0));

        if (mv.curr_image) |bmp| {
            // Compute dimensions
            const bounds = rect;
            const bounds_w = @as(f32, @floatFromInt(bounds.right - bounds.left));
            const bounds_h = @as(f32, @floatFromInt(bounds.bottom - bounds.top));
            var img_w: f32 = undefined;
            var img_h: f32 = undefined;
            try gdip.checkStatus(gdip.getImageDimension(bmp, &img_w, &img_h));

            // Downscale out-of-bounds images
            var scale = @min(bounds_w / img_w, bounds_h / img_h);
            if (scale < 1) {
                // Bicubic interpolation displays better results when downscaling
                try gdip.checkStatus(gdip.setInterpolationMode(gfx, .HighQualityBicubic));
            } else {
                // No upscaling and no interpolation
                scale = 1;
                try gdip.checkStatus(gdip.setInterpolationMode(gfx, .NearestNeighbor));
            }

            // Draw
            const draw_w = scale * img_w;
            const draw_h = scale * img_h;

            try gdip.checkStatus(gdip.drawImageRect(
                gfx,
                bmp,
                0.5 * (bounds_w - draw_w),
                0.5 * (bounds_h - draw_h),
                draw_w,
                draw_h,
            ));
        }

        mv.debugInfo(dc);
    }

    /// Write debug information on the given surface (DC)
    fn debugInfo(mv: *MiniView, dc: win32.HDC) void {
        var y: i32 = 0;

        const cache_mem = mv.images.memory;
        const total_commit = mv.main_mem.commit_pos + mv.temp_mem.commit_pos + cache_mem.commit_pos;
        const total_used = mv.main_mem.alloc_pos + mv.temp_mem.alloc_pos + cache_mem.alloc_pos;

        y = mv.debugText(dc, y, "Debug mode\n# files: {}", .{mv.files.items.len});
        y = mv.debugText(dc, y, "Memory usage", .{});

        y = mv.debugText(dc, y, //
            "\tTotal: \n\t\tCommitted: {}\n\t\tUsed: {}\n\t\tWaste: {}", //
            .{ total_commit, total_used, total_commit - total_used });

        y = mv.debugText(dc, y, //
            "\tMain:  \n\t\tCommitted: {}\n\t\tUsed: {}\n\t\tWaste: {}", //
            .{ mv.main_mem.commit_pos, mv.main_mem.alloc_pos, mv.main_mem.commit_pos - mv.main_mem.alloc_pos });

        y = mv.debugText(dc, y, //
            "\tCache: \n\t\tCommitted: {}\n\t\tUsed: {}\n\t\tWaste: {}", //
            .{ cache_mem.commit_pos, cache_mem.alloc_pos, cache_mem.commit_pos - cache_mem.alloc_pos });

        y = mv.debugText(dc, y, //
            "\tTemp:\n\t\tCommitted: {}\n\t\tUsed: {}\n\t\tWaste: {}", //
            .{ mv.temp_mem.commit_pos, mv.temp_mem.alloc_pos, mv.temp_mem.commit_pos - mv.temp_mem.alloc_pos });
    }

    fn debugText(mv: *MiniView, dc: win32.HDC, y: i32, comptime fmt: []const u8, args: anytype) i32 {
        _ = win32.SetBkMode(dc, .Transparent);

        const text = bufPrintW(mv.debug_buf, fmt, args) catch return y;
        const text_len = @as(c_int, @intCast(text.len));
        const flags = win32.DT_TOP | win32.DT_LEFT | win32.DT_EXPANDTABS;
        const tabs = win32.DT_TABSTOP | 0x300;

        var cur_y = y + 1;
        var bounds = win32.RECT{
            .left = 1,
            .top = cur_y,
            .right = 0,
            .bottom = 0,
        };

        var ofst: c_int = 0;
        ofst = win32.DrawTextW(dc, text, text_len, &bounds, tabs);
        ofst = win32.DrawTextW(dc, text, text_len, &bounds, flags | win32.DT_CALCRECT);
        ofst = win32.DrawTextW(dc, text, text_len, &bounds, flags | tabs);

        cur_y += ofst;
        return cur_y;
    }
};

//=== Utilities ===//

fn RingBuffer(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Slice);
}

/// Format message to a utf16 "wide" string
fn bufPrintW(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]const u16 {
    const str = try std.fmt.bufPrint(buf, fmt, args);
    var alloc = FixedBufferAllocator.init(buf[str.len..]);
    return unicode.utf8ToUtf16LeWithNull(alloc.allocator(), str);
}

fn setWindowUserPtr(win: win32.HWND, comptime T: type, ptr: *T) void {
    const addr = @intFromPtr(ptr);
    _ = win32.setWindowLongPtrW(win, win32.GWL_USERDATA, @intCast(addr)) catch unreachable;
}

fn getWindowUserPtr(win: win32.HWND, comptime T: type) ?*T {
    const long = win32.getWindowLongPtrW(win, win32.GWL_USERDATA) catch return null;
    const addr: usize = @intCast(long);
    return @ptrFromInt(addr);
}

//=== Image store implementation ===//

const ImageStore = struct {
    pub const Image = union(enum) { None, Loaded: *gdip.Image };
    pub const Handle = packed struct {
        idx: Int = 0,
        gen: Int = 0,

        pub inline fn toInt(handle: Handle) usize {
            return @as(usize, @bitCast(handle));
        }

        pub inline fn fromInt(int: usize) Handle {
            return @as(Handle, @bitCast(int));
        }
    };

    comptime {
        assert(@bitSizeOf(Handle) == @bitSizeOf(usize));
    }

    const Int = std.meta.Int(.unsigned, @divExact(@bitSizeOf(usize), 2));

    const Node = struct { gen: Int = 0, val: Image = .None };

    comptime {
        assert(std.math.isPowerOfTwo(cache_size));
    }

    memory: *Memory,
    iocp: win32.HANDLE = undefined,
    nodes: [cache_size]Node = [_]Node{.{}} ** cache_size,
    count: Int = 0,

    pub fn init(memory: *Memory) !*ImageStore {
        var self = try memory.create(ImageStore);
        self.* = .{
            .memory = memory,
            // Create IO completion port for async file reading
            .iocp = try win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, null, 0, 0),
        };
        return self;
    }

    pub fn new(self: *ImageStore) Handle {
        const idx = @atomicRmw(Int, &self.count, .Add, 1, .SeqCst) & (cache_size - 1);

        var node = &self.nodes[idx];

        const handle = Handle{
            .idx = idx,
            .gen = if (node.gen == std.math.maxInt(Int)) 1 else node.gen + 1,
        };

        switch (node.val) {
            .Loaded => |ptr| gdip.checkStatus(gdip.disposeImage(ptr)) catch unreachable,
            else => {},
        }
        node.gen = handle.gen;
        node.val = .None;

        return handle;
    }

    pub fn get(self: *ImageStore, handle: Handle, filename: [:0]const u16) ?*gdip.Image {
        if (handle.gen == 0) return null;

        const node = &self.nodes[handle.idx];
        if (node.gen != handle.gen) return null;

        switch (node.val) {
            .None => {
                const image = self.loadImageFile(filename) catch return null;
                node.val = .{ .Loaded = image };
                return image;
            },
            .Loaded => |image| return image,
        }
    }

    pub fn clear(self: *ImageStore) void {
        for (&self.nodes) |*node| {
            switch (node.val) {
                .Loaded => |ptr| gdip.checkStatus(gdip.disposeImage(ptr)) catch unreachable,
                else => {},
            }
            node.val = .None;
            node.gen = 0;
        }
        self.count = 0;
    }

    // TODO (Matteo): Review image storage
    fn loadImageFile(self: *ImageStore, file_name: [:0]const u16) !*gdip.Image {
        const wide_path = try win32.wToPrefixedFileW(file_name);

        const file = win32.kernel32.CreateFileW(
            wide_path.span(),
            win32.GENERIC_READ,
            win32.FILE_SHARE_READ,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (file == win32.INVALID_HANDLE_VALUE) return error.Unexpected;

        // Read all file in a temporary block
        const size = @as(usize, @intCast(try win32.GetFileSizeEx(file)));
        const block = try self.memory.alloc(u8, size);

        // Emulate asyncronous read
        try self.beginLoad(file, block);
        return self.endLoad(file, block);
    }

    fn beginLoad(self: *ImageStore, file: win32.HANDLE, block: []u8) !void {
        var ovp_in = mem.zeroInit(win32.OVERLAPPED, .{});
        _ = try win32.CreateIoCompletionPort(file, self.iocp, 0, 0);
        if (win32.kernel32.ReadFile(
            file,
            block.ptr,
            @as(u32, @intCast(block.len)),
            null,
            &ovp_in,
        ) == 0) {
            const err = win32.kernel32.GetLastError();
            switch (err) {
                .IO_PENDING => {}, // ERROR_IO_PENDING
                else => {
                    // NOTE (Matteo): Restore error code and fail; our panic handler is responsible
                    // for reporting the error in a proper way
                    win32.kernel32.SetLastError(err);
                    return error.Unexpected;
                },
            }
        }
    }

    fn endLoad(self: *ImageStore, file: win32.HANDLE, block: []u8) !*gdip.Image {
        defer win32.CloseHandle(file);
        defer self.memory.free(block);

        var bytes: u32 = undefined;
        var key: usize = undefined;
        var ovp_out: ?*win32.OVERLAPPED = undefined;
        switch (win32.GetQueuedCompletionStatus(self.iocp, &bytes, &key, &ovp_out, win32.INFINITE)) {
            .Normal => {},
            else => return error.Unexpected,
        }
        assert(bytes == block.len);

        // TODO (Matteo): Get rid of this nonsense! This seems to make a copy of the
        // given buffer, because memory leaks if the stream is not released.
        // I honestly expected this to behave as a wrapper.
        const stream = try win32.createMemStream(block);
        defer _ = stream.release();

        var new_image: *gdip.Image = undefined;
        const status = gdip.createImageFromStream(stream, &new_image);
        try gdip.checkStatus(status);

        return new_image;
    }
};
