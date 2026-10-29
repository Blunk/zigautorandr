//! Minimal X11 wire-protocol client with just enough of the RandR extension
//! (>= 1.3) to read and change the monitor configuration. Talks to the X
//! server directly over its unix socket; no Xlib/xcb required.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// We announce our native byte order in the connection setup, so the server
/// talks to us in native order as well.
const ne = builtin.cpu.arch.endian();

pub fn get(comptime T: type, bytes: []const u8, off: usize) T {
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], ne);
}

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

const Request = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn init(opcode: u8, data: u8) Request {
        var r: Request = .{};
        r.put(u8, opcode);
        r.put(u8, data);
        r.put(u16, 0); // length, filled in by finish()
        return r;
    }

    fn put(r: *Request, comptime T: type, v: T) void {
        std.mem.writeInt(T, r.buf[r.len..][0..@sizeOf(T)], v, ne);
        r.len += @sizeOf(T);
    }

    fn putBytes(r: *Request, b: []const u8) void {
        @memcpy(r.buf[r.len..][0..b.len], b);
        r.len += b.len;
        r.pad();
    }

    fn pad(r: *Request) void {
        while (r.len % 4 != 0) : (r.len += 1) r.buf[r.len] = 0;
    }

    fn finish(r: *Request) []const u8 {
        r.pad();
        std.mem.writeInt(u16, r.buf[2..4], @intCast(r.len / 4), ne);
        return r.buf[0..r.len];
    }
};

pub const XError = struct {
    code: u8,
    seq: u16,
    bad_value: u32,
    minor: u16,
    major: u8,

    fn parse(p: []const u8) XError {
        return .{
            .code = p[1],
            .seq = get(u16, p, 2),
            .bad_value = get(u32, p, 4),
            .minor = get(u16, p, 8),
            .major = p[10],
        };
    }
};

pub const Display = struct {
    number: []const u8,
    screen: usize,
};

pub fn parseDisplay(display: []const u8) !Display {
    const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return error.BadDisplay;
    const host = display[0..colon];
    if (host.len != 0 and !std.mem.eql(u8, host, "unix")) return error.UnsupportedDisplay;
    const rest = display[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const number = if (dot) |d| rest[0..d] else rest;
    if (number.len == 0) return error.BadDisplay;
    for (number) |c| if (!std.ascii.isDigit(c)) return error.BadDisplay;
    const screen = if (dot) |d| std.fmt.parseInt(usize, rest[d + 1 ..], 10) catch return error.BadDisplay else 0;
    return .{ .number = number, .screen = screen };
}

pub const Rotation = struct {
    pub const rotate_0: u16 = 1;
    pub const rotate_90: u16 = 2;
    pub const rotate_180: u16 = 4;
    pub const rotate_270: u16 = 8;
    pub const reflect_x: u16 = 16;
    pub const reflect_y: u16 = 32;
};

pub const output_connection = struct {
    pub const connected: u8 = 0;
    pub const disconnected: u8 = 1;
    pub const unknown: u8 = 2;
};

pub const ModeInfo = struct {
    id: u32,
    width: u16,
    height: u16,
    dot_clock: u32,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    flags: u32,
    name: []const u8,

    pub const flag_interlace: u32 = 0x10;
    pub const flag_doublescan: u32 = 0x20;

    pub fn refresh(m: ModeInfo) f64 {
        var vtotal: f64 = @floatFromInt(m.vtotal);
        if (m.flags & flag_doublescan != 0) vtotal *= 2;
        if (m.flags & flag_interlace != 0) vtotal /= 2;
        const denom = @as(f64, @floatFromInt(m.htotal)) * vtotal;
        if (denom == 0) return 0;
        return @as(f64, @floatFromInt(m.dot_clock)) / denom;
    }
};

pub const Resources = struct {
    config_timestamp: u32,
    crtcs: []u32,
    outputs: []u32,
    modes: []ModeInfo,

    pub fn findMode(r: Resources, id: u32) ?ModeInfo {
        for (r.modes) |m| if (m.id == id) return m;
        return null;
    }
};

pub const OutputInfo = struct {
    id: u32,
    crtc: u32,
    mm_width: u32,
    mm_height: u32,
    connection: u8,
    crtcs: []u32,
    modes: []u32,
    num_preferred: u16,
    clones: []u32,
    name: []const u8,
};

pub const CrtcInfo = struct {
    id: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    mode: u32,
    rotation: u16,
    rotations: u16,
    outputs: []u32,
    possible: []u32,
};

pub const Property = struct {
    type: u32,
    format: u8,
    data: []const u8,
};

pub const SizeRange = struct { min_width: u16, min_height: u16, max_width: u16, max_height: u16 };

/// RandR event selection masks.
pub const notify_mask = struct {
    pub const screen_change: u16 = 1;
    pub const crtc_change: u16 = 2;
    pub const output_change: u16 = 4;
    pub const output_property: u16 = 8;
};

fn readU32s(arena: Allocator, bytes: []const u8, off: *usize, n: usize) ![]u32 {
    const out = try arena.alloc(u32, n);
    for (out) |*v| {
        v.* = get(u32, bytes, off.*);
        off.* += 4;
    }
    return out;
}

pub const Connection = struct {
    fd: posix.fd_t,
    gpa: Allocator,
    seq: u16 = 0,
    root: u32 = 0,
    randr_major: u8 = 0,
    randr_first_event: u8 = 0,
    /// Events that arrived while we were waiting for a reply.
    events: std.ArrayList([32]u8) = .empty,
    /// First error belonging to a request without reply; reported by sync().
    pending_error: ?XError = null,
    /// Details for the last error.XRequestFailed.
    last_error: ?XError = null,

    /// Connects to $DISPLAY. `gpa` is used for long-lived internal state,
    /// `arena` for temporary allocations during setup.
    pub fn open(gpa: Allocator, arena: Allocator) !Connection {
        const display = posix.getenv("DISPLAY") orelse return error.NoDisplay;
        const d = try parseDisplay(display);
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{s}", .{d.number});
        const stream = std.net.connectUnixSocket(path) catch return error.ConnectionFailed;
        var conn: Connection = .{ .fd = stream.handle, .gpa = gpa };
        errdefer conn.close();
        try conn.setup(arena, d);
        try conn.initRandr(arena);
        return conn;
    }

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
        self.events.deinit(self.gpa);
    }

    fn writeAll(self: *Connection, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) off += try posix.write(self.fd, bytes[off..]);
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try posix.read(self.fd, buf[off..]);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    fn setup(self: *Connection, arena: Allocator, d: Display) !void {
        const cookie = readXauthority(arena, d.number) catch null;
        const auth_name: []const u8 = if (cookie != null) "MIT-MAGIC-COOKIE-1" else "";
        const auth_data: []const u8 = cookie orelse "";

        var r: Request = .{};
        r.put(u8, if (ne == .little) 'l' else 'B');
        r.put(u8, 0);
        r.put(u16, 11); // protocol major
        r.put(u16, 0); // protocol minor
        r.put(u16, @intCast(auth_name.len));
        r.put(u16, @intCast(auth_data.len));
        r.put(u16, 0);
        r.putBytes(auth_name);
        r.putBytes(auth_data);
        try self.writeAll(r.buf[0..r.len]);

        var head: [8]u8 = undefined;
        try self.readExact(&head);
        const extra = try arena.alloc(u8, @as(usize, get(u16, &head, 6)) * 4);
        try self.readExact(extra);
        switch (head[0]) {
            1 => {},
            0 => {
                std.log.err("X server refused connection: {s}", .{extra[0..@min(head[1], extra.len)]});
                return error.ConnectionRefused;
            },
            else => return error.AuthenticationRequired,
        }

        const vendor_len = get(u16, extra, 16);
        const num_screens = extra[20];
        const num_formats = extra[21];
        if (d.screen >= num_screens) return error.BadScreen;
        var off: usize = 32 + pad4(vendor_len) + @as(usize, num_formats) * 8;
        var i: usize = 0;
        while (i < d.screen) : (i += 1) {
            const num_depths = extra[off + 39];
            off += 40;
            for (0..num_depths) |_| off += 8 + @as(usize, get(u16, extra, off + 2)) * 24;
        }
        self.root = get(u32, extra, off);
    }

    fn send(self: *Connection, req: []const u8) !u16 {
        try self.writeAll(req);
        self.seq +%= 1;
        return self.seq;
    }

    fn readPacket(self: *Connection, arena: Allocator) ![]u8 {
        var head: [32]u8 = undefined;
        try self.readExact(&head);
        const kind = head[0] & 0x7f;
        const extra: usize = if (kind == 1 or kind == 35) @as(usize, get(u32, &head, 4)) * 4 else 0;
        const buf = try arena.alloc(u8, 32 + extra);
        @memcpy(buf[0..32], &head);
        try self.readExact(buf[32..]);
        return buf;
    }

    fn reply(self: *Connection, arena: Allocator, seq: u16) ![]u8 {
        while (true) {
            const p = try self.readPacket(arena);
            switch (p[0] & 0x7f) {
                0 => {
                    const e = XError.parse(p);
                    if (e.seq == seq) {
                        self.last_error = e;
                        return error.XRequestFailed;
                    }
                    if (self.pending_error == null) self.pending_error = e;
                },
                1 => if (get(u16, p, 2) == seq) return p,
                35 => {}, // generic events are not used
                else => try self.events.append(self.gpa, p[0..32].*),
            }
        }
    }

    /// Round-trips to the server and reports any error caused by earlier
    /// requests that don't have a reply.
    pub fn sync(self: *Connection, arena: Allocator) !void {
        var r = Request.init(43, 0); // GetInputFocus
        _ = try self.reply(arena, try self.send(r.finish()));
        if (self.pending_error) |e| {
            self.pending_error = null;
            self.last_error = e;
            return error.XRequestFailed;
        }
    }

    /// Returns the next event, or null if none arrived within `timeout_ms`
    /// (-1 waits forever).
    pub fn waitEvent(self: *Connection, arena: Allocator, timeout_ms: i32) !?[32]u8 {
        if (self.events.items.len > 0) return self.events.orderedRemove(0);
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        while (true) {
            if (try posix.poll(&fds, timeout_ms) == 0) return null;
            const p = try self.readPacket(arena);
            switch (p[0] & 0x7f) {
                0 => std.log.warn("X error {d} (request {d}.{d})", .{ p[1], p[10], get(u16, p, 8) }),
                1, 35 => {},
                else => return p[0..32].*,
            }
        }
    }

    // ---- core protocol ----------------------------------------------------

    pub fn internAtom(self: *Connection, arena: Allocator, name: []const u8, only_if_exists: bool) !u32 {
        var r = Request.init(16, @intFromBool(only_if_exists));
        r.put(u16, @intCast(name.len));
        r.put(u16, 0);
        r.putBytes(name);
        const rep = try self.reply(arena, try self.send(r.finish()));
        return get(u32, rep, 8);
    }

    pub fn getGeometry(self: *Connection, arena: Allocator, drawable: u32) !struct { width: u16, height: u16 } {
        var r = Request.init(14, 0);
        r.put(u32, drawable);
        const rep = try self.reply(arena, try self.send(r.finish()));
        return .{ .width = get(u16, rep, 16), .height = get(u16, rep, 18) };
    }

    pub fn grabServer(self: *Connection) !void {
        var r = Request.init(36, 0);
        _ = try self.send(r.finish());
    }

    pub fn ungrabServer(self: *Connection) !void {
        var r = Request.init(37, 0);
        _ = try self.send(r.finish());
    }

    const Extension = struct { present: bool, major: u8, first_event: u8 };

    fn queryExtension(self: *Connection, arena: Allocator, name: []const u8) !Extension {
        var r = Request.init(98, 0);
        r.put(u16, @intCast(name.len));
        r.put(u16, 0);
        r.putBytes(name);
        const rep = try self.reply(arena, try self.send(r.finish()));
        return .{ .present = rep[8] != 0, .major = rep[9], .first_event = rep[10] };
    }

    // ---- RandR ------------------------------------------------------------

    fn initRandr(self: *Connection, arena: Allocator) !void {
        const ext = try self.queryExtension(arena, "RANDR");
        if (!ext.present) return error.NoRandr;
        self.randr_major = ext.major;
        self.randr_first_event = ext.first_event;
        var r = Request.init(self.randr_major, 0); // QueryVersion
        r.put(u32, 1);
        r.put(u32, 5);
        const rep = try self.reply(arena, try self.send(r.finish()));
        const major = get(u32, rep, 8);
        const minor = get(u32, rep, 12);
        if (major < 1 or (major == 1 and minor < 3)) return error.RandrTooOld;
    }

    pub fn selectInput(self: *Connection, mask: u16) !void {
        var r = Request.init(self.randr_major, 4);
        r.put(u32, self.root);
        r.put(u16, mask);
        r.put(u16, 0);
        _ = try self.send(r.finish());
    }

    pub fn getScreenSizeRange(self: *Connection, arena: Allocator) !SizeRange {
        var r = Request.init(self.randr_major, 6);
        r.put(u32, self.root);
        const rep = try self.reply(arena, try self.send(r.finish()));
        return .{
            .min_width = get(u16, rep, 8),
            .min_height = get(u16, rep, 10),
            .max_width = get(u16, rep, 12),
            .max_height = get(u16, rep, 14),
        };
    }

    pub fn setScreenSize(self: *Connection, width: u16, height: u16, mm_width: u32, mm_height: u32) !void {
        var r = Request.init(self.randr_major, 7);
        r.put(u32, self.root);
        r.put(u16, width);
        r.put(u16, height);
        r.put(u32, mm_width);
        r.put(u32, mm_height);
        _ = try self.send(r.finish());
    }

    /// `probe` asks the server to re-detect outputs (like plain `xrandr`),
    /// otherwise the cached state is returned.
    pub fn getScreenResources(self: *Connection, arena: Allocator, probe: bool) !Resources {
        var r = Request.init(self.randr_major, if (probe) 8 else 25);
        r.put(u32, self.root);
        const rep = try self.reply(arena, try self.send(r.finish()));
        const num_crtcs = get(u16, rep, 16);
        const num_outputs = get(u16, rep, 18);
        const num_modes = get(u16, rep, 20);
        var off: usize = 32;
        const crtcs = try readU32s(arena, rep, &off, num_crtcs);
        const outputs = try readU32s(arena, rep, &off, num_outputs);
        const modes = try arena.alloc(ModeInfo, num_modes);
        var name_off = off + @as(usize, num_modes) * 32;
        for (modes) |*m| {
            const name_len = get(u16, rep, off + 26);
            m.* = .{
                .id = get(u32, rep, off),
                .width = get(u16, rep, off + 4),
                .height = get(u16, rep, off + 6),
                .dot_clock = get(u32, rep, off + 8),
                .hsync_start = get(u16, rep, off + 12),
                .hsync_end = get(u16, rep, off + 14),
                .htotal = get(u16, rep, off + 16),
                .hskew = get(u16, rep, off + 18),
                .vsync_start = get(u16, rep, off + 20),
                .vsync_end = get(u16, rep, off + 22),
                .vtotal = get(u16, rep, off + 24),
                .flags = get(u32, rep, off + 28),
                .name = rep[name_off..][0..name_len],
            };
            off += 32;
            name_off += name_len;
        }
        return .{ .config_timestamp = get(u32, rep, 12), .crtcs = crtcs, .outputs = outputs, .modes = modes };
    }

    pub fn getOutputInfo(self: *Connection, arena: Allocator, output: u32, config_timestamp: u32) !OutputInfo {
        var r = Request.init(self.randr_major, 9);
        r.put(u32, output);
        r.put(u32, config_timestamp);
        const rep = try self.reply(arena, try self.send(r.finish()));
        var off: usize = 36;
        const crtcs = try readU32s(arena, rep, &off, get(u16, rep, 26));
        const modes = try readU32s(arena, rep, &off, get(u16, rep, 28));
        const clones = try readU32s(arena, rep, &off, get(u16, rep, 32));
        return .{
            .id = output,
            .crtc = get(u32, rep, 12),
            .mm_width = get(u32, rep, 16),
            .mm_height = get(u32, rep, 20),
            .connection = rep[24],
            .crtcs = crtcs,
            .modes = modes,
            .num_preferred = get(u16, rep, 30),
            .clones = clones,
            .name = rep[off..][0..get(u16, rep, 34)],
        };
    }

    pub fn getOutputProperty(self: *Connection, arena: Allocator, output: u32, property: u32) !?Property {
        var r = Request.init(self.randr_major, 15);
        r.put(u32, output);
        r.put(u32, property);
        r.put(u32, 0); // AnyPropertyType
        r.put(u32, 0); // long-offset
        r.put(u32, 16384); // long-length (in 4 byte units)
        r.put(u8, 0); // delete
        r.put(u8, 0); // pending
        r.put(u16, 0);
        const rep = try self.reply(arena, try self.send(r.finish()));
        const prop_type = get(u32, rep, 8);
        if (prop_type == 0) return null;
        const format = rep[1];
        const len = @as(usize, get(u32, rep, 16)) * (format / 8);
        return .{ .type = prop_type, .format = format, .data = rep[32..][0..len] };
    }

    pub fn getCrtcInfo(self: *Connection, arena: Allocator, crtc: u32, config_timestamp: u32) !CrtcInfo {
        var r = Request.init(self.randr_major, 20);
        r.put(u32, crtc);
        r.put(u32, config_timestamp);
        const rep = try self.reply(arena, try self.send(r.finish()));
        var off: usize = 32;
        const outputs = try readU32s(arena, rep, &off, get(u16, rep, 28));
        const possible = try readU32s(arena, rep, &off, get(u16, rep, 30));
        return .{
            .id = crtc,
            .x = get(i16, rep, 12),
            .y = get(i16, rep, 14),
            .width = get(u16, rep, 16),
            .height = get(u16, rep, 18),
            .mode = get(u32, rep, 20),
            .rotation = get(u16, rep, 24),
            .rotations = get(u16, rep, 26),
            .outputs = outputs,
            .possible = possible,
        };
    }

    pub fn setCrtcConfig(
        self: *Connection,
        arena: Allocator,
        crtc: u32,
        config_timestamp: u32,
        x: i16,
        y: i16,
        mode: u32,
        rotation: u16,
        outputs: []const u32,
    ) !void {
        var r = Request.init(self.randr_major, 21);
        r.put(u32, crtc);
        r.put(u32, 0); // CurrentTime
        r.put(u32, config_timestamp);
        r.put(i16, x);
        r.put(i16, y);
        r.put(u32, mode);
        r.put(u16, rotation);
        r.put(u16, 0);
        for (outputs) |o| r.put(u32, o);
        const rep = try self.reply(arena, try self.send(r.finish()));
        switch (rep[1]) {
            0 => {},
            1 => return error.InvalidConfigTime,
            2 => return error.InvalidTime,
            else => return error.SetCrtcConfigFailed,
        }
    }

    pub fn setOutputPrimary(self: *Connection, output: u32) !void {
        var r = Request.init(self.randr_major, 30);
        r.put(u32, self.root);
        r.put(u32, output);
        _ = try self.send(r.finish());
    }

    pub fn getOutputPrimary(self: *Connection, arena: Allocator) !u32 {
        var r = Request.init(self.randr_major, 31);
        r.put(u32, self.root);
        const rep = try self.reply(arena, try self.send(r.finish()));
        return get(u32, rep, 8);
    }
};

/// Finds the MIT-MAGIC-COOKIE-1 for our display in ~/.Xauthority. Returns
/// null if there is none (the server may still accept us, e.g. via xhost).
fn readXauthority(arena: Allocator, display_number: []const u8) !?[]const u8 {
    const path = posix.getenv("XAUTHORITY") orelse blk: {
        const home = posix.getenv("HOME") orelse return null;
        break :blk try std.fs.path.join(arena, &.{ home, ".Xauthority" });
    };
    const data = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch return null;

    var host_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const host = posix.gethostname(&host_buf) catch "";

    const family_local = 256;
    const family_wild = 65535;
    var fallback: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos + 2 <= data.len) {
        const family = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        const address = xauthField(data, &pos) orelse break;
        const number = xauthField(data, &pos) orelse break;
        const name = xauthField(data, &pos) orelse break;
        const cookie = xauthField(data, &pos) orelse break;
        if (!std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1")) continue;
        if (number.len != 0 and !std.mem.eql(u8, number, display_number)) continue;
        if (family == family_wild or (family == family_local and std.mem.eql(u8, address, host))) return cookie;
        if (fallback == null) fallback = cookie;
    }
    return fallback;
}

fn xauthField(data: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + 2 > data.len) return null;
    const n = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    if (pos.* + n > data.len) return null;
    defer pos.* += n;
    return data[pos.*..][0..n];
}

test parseDisplay {
    const d = try parseDisplay(":1.2");
    try std.testing.expectEqualStrings("1", d.number);
    try std.testing.expectEqual(@as(usize, 2), d.screen);
    try std.testing.expectEqual(@as(usize, 0), (try parseDisplay("unix:0")).screen);
    try std.testing.expectError(error.UnsupportedDisplay, parseDisplay("remote:0"));
    try std.testing.expectError(error.BadDisplay, parseDisplay(":"));
}
