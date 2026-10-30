//! zigautorandr - autorandr-like monitor profiles keyed on EDID instead of
//! (unstable) output names.

const std = @import("std");
const x11 = @import("x11.zig");
const edid = @import("edid.zig");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Rotation = x11.Rotation;

const usage =
    \\Usage: zigautorandr [command] [options]
    \\
    \\Commands:
    \\  status             show connected monitors and profiles (default)
    \\  save <profile>     save the current layout as <profile>
    \\  load <profile>     apply <profile> (its monitors must be connected)
    \\  change             apply the first profile matching the connected monitors
    \\  remove <profile>   delete <profile>
    \\  daemon             listen for hotplug events and run 'change' on each
    \\
    \\Options:
    \\  --dry-run          only print what load/change would do
    \\  --force            save: overwrite an existing profile
    \\                     load: apply even if the profile looks active
    \\  -h, --help         show this help
    \\  -V, --version      show the version
    \\
    \\Profiles are stored in $XDG_CONFIG_HOME/zigautorandr/<profile>.json.
    \\If $XDG_CONFIG_HOME/zigautorandr/postswitch is executable, it is run with
    \\the profile name as argument after a profile was applied.
    \\
;

// ---- profile format ---------------------------------------------------------

const RotationName = enum { normal, left, inverted, right };

const OutputConfig = struct {
    /// Hash of the EDID base block, or "output:<name>" without EDID.
    fingerprint: []const u8,
    /// Informational only.
    monitor: []const u8 = "",
    /// Output name at save time; only used to tell identical monitors apart.
    output: []const u8 = "",
    enabled: bool = false,
    primary: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    refresh: f64 = 0,
    rotation: RotationName = .normal,
    reflect_x: bool = false,
    reflect_y: bool = false,
    /// Exact timings of the saved mode, preferred over `refresh` when present.
    dot_clock: u32 = 0,
    htotal: u32 = 0,
    vtotal: u32 = 0,
    mode_flags: u32 = 0,
    /// CRTC transform (`xrandr --scale/--transform`), 3x3 row-major, applied
    /// after rotation. Absent means identity, e.g. 1.5x scaling is
    /// [1.5,0,0, 0,1.5,0, 0,0,1].
    transform: ?[9]f64 = null,
    /// Filter for a non-identity transform; absent means "bilinear" (like xrandr).
    filter: ?[]const u8 = null,

    fn rotationBits(e: OutputConfig) u16 {
        var bits: u16 = switch (e.rotation) {
            .normal => Rotation.rotate_0,
            .left => Rotation.rotate_90,
            .inverted => Rotation.rotate_180,
            .right => Rotation.rotate_270,
        };
        if (e.reflect_x) bits |= Rotation.reflect_x;
        if (e.reflect_y) bits |= Rotation.reflect_y;
        return bits;
    }

    fn wantTransform(e: OutputConfig) !CrtcTransform {
        const t = e.transform orelse return .{};
        var out: CrtcTransform = .{ .filter = e.filter orelse "bilinear" };
        for (&out.matrix, t) |*o, v| {
            if (!std.math.isFinite(v) or @abs(v) >= 32768) return error.InvalidTransform;
            o.* = @intFromFloat(@round(v * x11.fixed_one));
        }
        if (x11.isIdentity(out.matrix)) out.filter = "";
        return out;
    }
};

const CrtcTransform = struct {
    matrix: x11.Transform = x11.identity_transform,
    /// Irrelevant for the identity transform.
    filter: []const u8 = "",

    fn eql(a: CrtcTransform, b: CrtcTransform) bool {
        if (!std.mem.eql(i32, &a.matrix, &b.matrix)) return false;
        return x11.isIdentity(a.matrix) or std.mem.eql(u8, a.filter, b.filter);
    }

    fn toFloat(t: CrtcTransform) ?[9]f64 {
        if (x11.isIdentity(t.matrix)) return null;
        var out: [9]f64 = undefined;
        for (&out, t.matrix) |*o, v| o.* = @as(f64, @floatFromInt(v)) / x11.fixed_one;
        return out;
    }

    /// Size the CRTC covers on the screen for `mode`, computed like the X
    /// server does: rotation first, then the transform, rounded outwards.
    fn footprint(t: CrtcTransform, mode: x11.ModeInfo, rotation: u16) !struct { w: u32, h: u32 } {
        const sideways = rotation & (Rotation.rotate_90 | Rotation.rotate_270) != 0;
        const w: f64 = @floatFromInt(if (sideways) mode.height else mode.width);
        const h: f64 = @floatFromInt(if (sideways) mode.width else mode.height);
        var m: [9]f64 = undefined;
        for (&m, t.matrix) |*o, v| o.* = @as(f64, @floatFromInt(v)) / x11.fixed_one;
        var min_x = std.math.inf(f64);
        var min_y = std.math.inf(f64);
        var max_x = -std.math.inf(f64);
        var max_y = -std.math.inf(f64);
        for ([_][2]f64{ .{ 0, 0 }, .{ w, 0 }, .{ 0, h }, .{ w, h } }) |p| {
            const z = m[6] * p[0] + m[7] * p[1] + m[8];
            if (!(z > 0)) return error.InvalidTransform;
            const x = (m[0] * p[0] + m[1] * p[1] + m[2]) / z;
            const y = (m[3] * p[0] + m[4] * p[1] + m[5]) / z;
            min_x = @min(min_x, @floor(x));
            min_y = @min(min_y, @floor(y));
            max_x = @max(max_x, @ceil(x));
            max_y = @max(max_y, @ceil(y));
        }
        if (max_x - min_x > 65535 or max_y - min_y > 65535) return error.InvalidTransform;
        return .{ .w = @intFromFloat(max_x - min_x), .h = @intFromFloat(max_y - min_y) };
    }

    /// " scale 1.5x1.5", " transform [...]" or "" for the identity.
    fn describe(t: CrtcTransform, arena: Allocator) ![]const u8 {
        const f = t.toFloat() orelse return "";
        var r: [9]f64 = undefined;
        for (&r, f) |*o, v| o.* = @round(v * 1000) / 1000;
        if (t.matrix[1] == 0 and t.matrix[2] == 0 and t.matrix[3] == 0 and t.matrix[5] == 0 and
            t.matrix[6] == 0 and t.matrix[7] == 0 and t.matrix[8] == x11.fixed_one)
            return std.fmt.allocPrint(arena, " scale {d}x{d}", .{ r[0], r[4] });
        return std.fmt.allocPrint(arena, " transform {any}", .{r});
    }
};

const Profile = struct {
    outputs: []OutputConfig,
};

fn rotationName(bits: u16) RotationName {
    if (bits & Rotation.rotate_90 != 0) return .left;
    if (bits & Rotation.rotate_180 != 0) return .inverted;
    if (bits & Rotation.rotate_270 != 0) return .right;
    return .normal;
}

// ---- current X state ----------------------------------------------------------

const Monitor = struct {
    output: u32,
    name: []const u8,
    info: x11.OutputInfo,
    fingerprint: []const u8,
    description: []const u8,
    /// Set when the output is active.
    crtc: ?x11.CrtcInfo = null,
    mode: ?x11.ModeInfo = null,
    transform: CrtcTransform = .{},
};

const State = struct {
    res: x11.Resources,
    crtcs: []x11.CrtcInfo,
    /// Transforms of `crtcs` (same index).
    transforms: []x11.CrtcTransform,
    /// Connected outputs, sorted by name.
    monitors: []Monitor,
    primary: u32,
    width: u16,
    height: u16,

    /// Sorted fingerprints of all connected monitors; identifies the setup.
    fn key(s: State, arena: Allocator) ![]const u8 {
        const fps = try arena.alloc([]const u8, s.monitors.len);
        for (fps, s.monitors) |*f, m| f.* = m.fingerprint;
        std.mem.sort([]const u8, fps, {}, lessThanStr);
        return std.mem.join(arena, ",", fps);
    }
};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanMonitor(_: void, a: Monitor, b: Monitor) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Reads the EDID through RandR. If the driver doesn't expose it, falls back
/// to the kernel's copy in sysfs, found via the CONNECTOR_ID output property.
fn fetchEdid(arena: Allocator, conn: *x11.Connection, output: u32, edid_atom: u32, connector_atom: u32) !?[]const u8 {
    if (edid_atom != 0) {
        if (try conn.getOutputProperty(arena, output, edid_atom)) |p| {
            if (edid.isValid(p.data)) return p.data;
        }
    }
    if (connector_atom != 0) {
        if (try conn.getOutputProperty(arena, output, connector_atom)) |p| {
            if (p.format == 32 and p.data.len >= 4) return sysfsEdid(arena, x11.get(u32, p.data, 0));
        }
    }
    return null;
}

fn sysfsEdid(arena: Allocator, connector_id: u32) ?[]const u8 {
    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return null;
    defer dir.close();
    var found: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (std.mem.indexOfScalar(u8, entry.name, '-') == null) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const id_path = std.fmt.bufPrint(&path_buf, "{s}/connector_id", .{entry.name}) catch continue;
        const id_text = dir.readFileAlloc(arena, id_path, 64) catch continue;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, id_text, " \n"), 10) catch continue;
        if (id != connector_id) continue;
        const edid_path = std.fmt.bufPrint(&path_buf, "{s}/edid", .{entry.name}) catch continue;
        const data = dir.readFileAlloc(arena, edid_path, 1 << 16) catch continue;
        if (!edid.isValid(data)) continue;
        // Connector ids are only unique per GPU; refuse to guess.
        if (found != null) return null;
        found = data;
    }
    return found;
}

fn gatherState(arena: Allocator, conn: *x11.Connection, probe: bool) !State {
    const res = try conn.getScreenResources(arena, probe);
    const crtcs = try arena.alloc(x11.CrtcInfo, res.crtcs.len);
    for (crtcs, res.crtcs) |*c, id| c.* = try conn.getCrtcInfo(arena, id, res.config_timestamp);
    const transforms = try arena.alloc(x11.CrtcTransform, res.crtcs.len);
    for (transforms, res.crtcs) |*t, id| t.* = try conn.getCrtcTransform(arena, id);

    const edid_atom = try conn.internAtom(arena, "EDID", true);
    const connector_atom = try conn.internAtom(arena, "CONNECTOR_ID", true);

    var monitors: std.ArrayList(Monitor) = .empty;
    for (res.outputs) |o| {
        const info = try conn.getOutputInfo(arena, o, res.config_timestamp);
        if (info.connection != x11.output_connection.connected) continue;
        var mon: Monitor = .{
            .output = o,
            .name = info.name,
            .info = info,
            .fingerprint = undefined,
            .description = "(no EDID)",
        };
        if (try fetchEdid(arena, conn, o, edid_atom, connector_atom)) |data| {
            mon.fingerprint = try arena.dupe(u8, &edid.fingerprint(data));
            mon.description = try edid.describe(arena, data);
        } else {
            mon.fingerprint = try std.fmt.allocPrint(arena, "output:{s}", .{info.name});
        }
        for (crtcs, transforms) |c, t| {
            if (c.id == info.crtc and c.mode != 0) {
                mon.crtc = c;
                mon.mode = res.findMode(c.mode);
                mon.transform = .{ .matrix = t.current, .filter = t.current_filter };
            }
        }
        try monitors.append(arena, mon);
    }
    std.mem.sort(Monitor, monitors.items, {}, lessThanMonitor);

    const geo = try conn.getGeometry(arena, conn.root);
    return .{
        .res = res,
        .crtcs = crtcs,
        .transforms = transforms,
        .monitors = monitors.items,
        .primary = try conn.getOutputPrimary(arena),
        .width = geo.width,
        .height = geo.height,
    };
}

fn profileFromState(arena: Allocator, state: State) !Profile {
    const outputs = try arena.alloc(OutputConfig, state.monitors.len);
    for (outputs, state.monitors) |*e, m| {
        e.* = .{ .fingerprint = m.fingerprint, .monitor = m.description, .output = m.name };
        const c = m.crtc orelse continue;
        const mode = m.mode orelse continue;
        e.enabled = true;
        e.primary = state.primary == m.output;
        e.x = c.x;
        e.y = c.y;
        e.width = mode.width;
        e.height = mode.height;
        e.refresh = @round(mode.refresh() * 1000) / 1000;
        e.rotation = rotationName(c.rotation);
        e.reflect_x = c.rotation & Rotation.reflect_x != 0;
        e.reflect_y = c.rotation & Rotation.reflect_y != 0;
        e.dot_clock = mode.dot_clock;
        e.htotal = mode.htotal;
        e.vtotal = mode.vtotal;
        e.mode_flags = mode.flags;
        e.transform = m.transform.toFloat();
        if (e.transform != null) e.filter = m.transform.filter;
    }
    return .{ .outputs = outputs };
}

/// Maps every connected monitor to a profile entry (result[i] is the entry
/// for state.monitors[i]), or returns null if the monitor sets differ.
/// Identical monitors (same fingerprint) are told apart by output name.
fn matchProfile(arena: Allocator, profile: Profile, monitors: []const Monitor) !?[]usize {
    if (profile.outputs.len != monitors.len) return null;
    const map = try arena.alloc(?usize, monitors.len);
    @memset(map, null);
    const used = try arena.alloc(bool, profile.outputs.len);
    @memset(used, false);
    for (0..2) |pass| {
        for (monitors, map) |m, *slot| {
            if (slot.* != null) continue;
            for (profile.outputs, used, 0..) |e, *u, j| {
                if (u.* or !std.mem.eql(u8, e.fingerprint, m.fingerprint)) continue;
                if (pass == 0 and !std.mem.eql(u8, e.output, m.name)) continue;
                slot.* = j;
                u.* = true;
                break;
            }
        }
    }
    const result = try arena.alloc(usize, monitors.len);
    for (result, map) |*r, m| r.* = m orelse return null;
    return result;
}

/// Picks the output's mode for a profile entry: the exact saved timings if
/// available, otherwise the same resolution with the closest refresh rate.
fn pickMode(state: State, m: Monitor, e: OutputConfig) ?x11.ModeInfo {
    const scan_flags = x11.ModeInfo.flag_interlace | x11.ModeInfo.flag_doublescan;
    var best: ?x11.ModeInfo = null;
    var best_diff = std.math.inf(f64);
    for (m.info.modes) |id| {
        const mode = state.res.findMode(id) orelse continue;
        if (mode.width != e.width or mode.height != e.height) continue;
        if (e.dot_clock != 0 and mode.dot_clock == e.dot_clock and mode.htotal == e.htotal and
            mode.vtotal == e.vtotal and mode.flags & scan_flags == e.mode_flags & scan_flags) return mode;
        const diff = @abs(mode.refresh() - e.refresh);
        if (diff < best_diff) {
            best = mode;
            best_diff = diff;
        }
    }
    return best;
}

fn isApplied(state: State, profile: Profile, mapping: []const usize) bool {
    for (state.monitors, mapping) |m, j| {
        const e = profile.outputs[j];
        if ((m.crtc != null) != e.enabled) return false;
        if ((state.primary == m.output) != (e.enabled and e.primary)) return false;
        if (!e.enabled) continue;
        const c = m.crtc.?;
        if (c.x != e.x or c.y != e.y or c.rotation != e.rotationBits()) return false;
        const want = pickMode(state, m, e) orelse return false;
        if (c.mode != want.id) return false;
        const transform = e.wantTransform() catch return false;
        if (!m.transform.eql(transform)) return false;
    }
    return true;
}

// ---- applying -----------------------------------------------------------------

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    out: *std.Io.Writer,
    config_dir: []const u8,
    conn: ?*x11.Connection = null,
    dry_run: bool = false,
    force: bool = false,

    fn print(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
        ctx.out.print(fmt, args) catch {};
        ctx.out.flush() catch {};
    }

    fn profilePath(ctx: *Ctx, name: []const u8) ![]const u8 {
        const file = try std.fmt.allocPrint(ctx.arena, "{s}.json", .{name});
        return std.fs.path.join(ctx.arena, &.{ ctx.config_dir, file });
    }
};

fn apply(ctx: *Ctx, conn: *x11.Connection, state: State, profile: Profile, mapping: []const usize) !void {
    const arena = ctx.arena;
    const Plan = struct {
        mode: ?x11.ModeInfo = null,
        x: i16 = 0,
        y: i16 = 0,
        rotation: u16 = Rotation.rotate_0,
        transform: CrtcTransform = .{},
        output: u32 = 0,
        name: []const u8 = "",
    };
    const plans = try arena.alloc(Plan, state.crtcs.len);
    @memset(plans, .{});
    const placed = try arena.alloc(bool, state.monitors.len);
    @memset(placed, false);
    var primary: u32 = 0;
    var fb_w: u32 = 0;
    var fb_h: u32 = 0;

    // Pass 0 keeps outputs on their current CRTC to avoid needless
    // reconfiguration, pass 1 places the remaining ones on any free CRTC.
    for (0..2) |pass| {
        for (state.monitors, mapping, placed) |m, j, *done| {
            const e = profile.outputs[j];
            if (!e.enabled or done.*) continue;
            const mode = pickMode(state, m, e) orelse {
                std.log.err("{s}: mode {d}x{d} is not available", .{ m.name, e.width, e.height });
                return error.ModeNotAvailable;
            };
            const slot: ?usize = for (m.info.crtcs) |c| {
                if (pass == 0 and c != m.info.crtc) continue;
                const k = std.mem.indexOfScalar(u32, state.res.crtcs, c) orelse continue;
                if (plans[k].mode == null) break k;
            } else null;
            const k = slot orelse {
                if (pass == 0) continue;
                std.log.err("{s}: no free CRTC", .{m.name});
                return error.NoFreeCrtc;
            };
            const x = std.math.cast(i16, e.x) orelse return error.InvalidPosition;
            const y = std.math.cast(i16, e.y) orelse return error.InvalidPosition;
            if (x < 0 or y < 0) return error.InvalidPosition;
            const rotation = e.rotationBits();
            const transform = e.wantTransform() catch |err| {
                std.log.err("{s}: invalid transform", .{m.name});
                return err;
            };
            if (!x11.isIdentity(transform.matrix) and !state.transforms[k].supported) {
                std.log.err("{s}: the driver doesn't support scaling/transforms", .{m.name});
                return error.TransformNotSupported;
            }
            plans[k] = .{ .mode = mode, .x = x, .y = y, .rotation = rotation, .transform = transform, .output = m.output, .name = m.name };
            done.* = true;

            const size = transform.footprint(mode, rotation) catch |err| {
                std.log.err("{s}: invalid transform", .{m.name});
                return err;
            };
            fb_w = @max(fb_w, @as(u32, @intCast(x)) + size.w);
            fb_h = @max(fb_h, @as(u32, @intCast(y)) + size.h);
            if (e.primary) primary = m.output;
        }
    }
    if (fb_w == 0) return error.NoOutputEnabled;

    const range = try conn.getScreenSizeRange(arena);
    fb_w = @max(fb_w, range.min_width);
    fb_h = @max(fb_h, range.min_height);
    if (fb_w > range.max_width or fb_h > range.max_height) {
        std.log.err("screen size {d}x{d} exceeds maximum {d}x{d}", .{ fb_w, fb_h, range.max_width, range.max_height });
        return error.ScreenTooLarge;
    }

    const changed = try arena.alloc(bool, state.crtcs.len);
    for (state.crtcs, state.transforms, plans, changed) |c, t, p, *ch| {
        const want: u32 = if (p.mode) |mode| mode.id else 0;
        const current: CrtcTransform = .{ .matrix = t.current, .filter = t.current_filter };
        ch.* = c.mode != want or (want != 0 and (c.x != p.x or c.y != p.y or c.rotation != p.rotation or
            c.outputs.len != 1 or c.outputs[0] != p.output or !current.eql(p.transform)));
    }

    const dry = ctx.dry_run;
    const ts = state.res.config_timestamp;
    if (!dry) try conn.grabServer();
    defer if (!dry) conn.ungrabServer() catch {};

    // Turn off every CRTC that changes or wouldn't fit into the new screen.
    for (state.crtcs, changed) |c, *ch| {
        if (c.mode == 0) continue;
        const fits = @as(i32, c.x) + c.width <= fb_w and @as(i32, c.y) + c.height <= fb_h;
        if (!ch.* and fits) continue;
        ch.* = true;
        ctx.print("  disable CRTC 0x{x}\n", .{c.id});
        if (!dry) try conn.setCrtcConfig(arena, c.id, ts, 0, 0, 0, Rotation.rotate_0, &.{});
    }

    if (fb_w != state.width or fb_h != state.height) {
        // Physical size for 96 DPI, like most desktops assume anyway.
        const mm_w: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(fb_w)) * 25.4 / 96));
        const mm_h: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(fb_h)) * 25.4 / 96));
        ctx.print("  screen size {d}x{d}\n", .{ fb_w, fb_h });
        if (!dry) try conn.setScreenSize(@intCast(fb_w), @intCast(fb_h), mm_w, mm_h);
    }

    for (state.crtcs, state.transforms, plans, changed) |c, t, p, ch| {
        const mode = p.mode orelse continue;
        if (!ch) continue;
        ctx.print("  {s}: {d}x{d}@{d:.2} +{d}+{d} {t}{s} on CRTC 0x{x}\n", .{
            p.name,                          mode.width, mode.height, mode.refresh(), p.x, p.y, rotationName(p.rotation),
            try p.transform.describe(arena), c.id,
        });
        if (dry) continue;
        // The transform is pending until the following SetCrtcConfig.
        const pending: CrtcTransform = .{ .matrix = t.pending, .filter = t.pending_filter };
        if (!pending.eql(p.transform)) try conn.setCrtcTransform(c.id, p.transform.matrix, p.transform.filter);
        try conn.setCrtcConfig(arena, c.id, ts, p.x, p.y, mode.id, p.rotation, &.{p.output});
    }

    if (primary != state.primary) {
        ctx.print("  primary output 0x{x}\n", .{primary});
        if (!dry) try conn.setOutputPrimary(primary);
    }
    if (!dry) try conn.sync(arena);
}

fn runHook(ctx: *Ctx, profile_name: []const u8) void {
    const path = std.fs.path.join(ctx.arena, &.{ ctx.config_dir, "postswitch" }) catch return;
    std.fs.accessAbsolute(path, .{}) catch return;
    var child = std.process.Child.init(&.{ path, profile_name }, ctx.gpa);
    const term = child.spawnAndWait() catch |err| {
        std.log.warn("running {s} failed: {t}", .{ path, err });
        return;
    };
    if (term != .Exited or term.Exited != 0) std.log.warn("{s} failed: {any}", .{ path, term });
}

fn applyNamed(ctx: *Ctx, conn: *x11.Connection, state: State, name: []const u8, profile: Profile, mapping: []const usize) !void {
    ctx.print("{s} profile '{s}'\n", .{ if (ctx.dry_run) "Would apply" else "Applying", name });
    try apply(ctx, conn, state, profile, mapping);
    if (!ctx.dry_run) runHook(ctx, name);
}

// ---- profiles on disk ---------------------------------------------------------

fn listProfiles(ctx: *Ctx) ![]const []const u8 {
    var dir = std.fs.openDirAbsolute(ctx.config_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name[0 .. entry.name.len - ".json".len]));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    return names.items;
}

fn loadProfile(ctx: *Ctx, name: []const u8) !Profile {
    const path = try ctx.profilePath(name);
    const data = std.fs.cwd().readFileAlloc(ctx.arena, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("no profile named '{s}'", .{name});
            return error.ProfileNotFound;
        },
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Profile, ctx.arena, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("{s}: invalid profile: {t}", .{ path, err });
        return error.InvalidProfile;
    };
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name[0] == '.' or std.mem.indexOfScalar(u8, name, '/') != null) {
        std.log.err("invalid profile name '{s}'", .{name});
        return error.InvalidProfileName;
    }
}

// ---- commands -----------------------------------------------------------------

fn cmdStatus(ctx: *Ctx, conn: *x11.Connection) !void {
    const state = try gatherState(ctx.arena, conn, true);
    ctx.print("Connected monitors:\n", .{});
    for (state.monitors) |m| {
        ctx.print("  {s:<16} {s}\n", .{ m.name, m.description });
        ctx.print("  {s:<16} fingerprint {s}\n", .{ "", m.fingerprint });
        if (m.crtc) |c| {
            const mode = m.mode.?;
            const primary = if (state.primary == m.output) " primary" else "";
            ctx.print("  {s:<16} {d}x{d}@{d:.2} +{d}+{d} {t}{s}{s}\n", .{
                "",                                  mode.width, mode.height, mode.refresh(), c.x, c.y, rotationName(c.rotation),
                try m.transform.describe(ctx.arena), primary,
            });
        } else ctx.print("  {s:<16} off\n", .{""});
    }

    const names = try listProfiles(ctx);
    ctx.print("\nProfiles:\n", .{});
    if (names.len == 0) ctx.print("  (none)\n", .{});
    for (names) |name| {
        const profile = loadProfile(ctx, name) catch {
            ctx.print("  {s} (invalid)\n", .{name});
            continue;
        };
        const mapping = try matchProfile(ctx.arena, profile, state.monitors);
        const tag = if (mapping) |map|
            (if (isApplied(state, profile, map)) " (detected) (current)" else " (detected)")
        else
            "";
        ctx.print("  {s}{s}\n", .{ name, tag });
    }
}

fn cmdSave(ctx: *Ctx, conn: *x11.Connection, name: []const u8) !void {
    try validateName(name);
    const path = try ctx.profilePath(name);
    if (!ctx.force) {
        if (std.fs.accessAbsolute(path, .{})) |_| {
            std.log.err("profile '{s}' exists, use --force to overwrite", .{name});
            return error.ProfileExists;
        } else |_| {}
    }
    const state = try gatherState(ctx.arena, conn, true);
    const profile = try profileFromState(ctx.arena, state);
    const json = try std.json.Stringify.valueAlloc(ctx.arena, profile, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    try std.fs.cwd().makePath(ctx.config_dir);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
    ctx.print("Saved profile '{s}' to {s}\n", .{ name, path });
}

fn cmdLoad(ctx: *Ctx, conn: *x11.Connection, name: []const u8) !void {
    try validateName(name);
    const profile = try loadProfile(ctx, name);
    const state = try gatherState(ctx.arena, conn, true);
    const mapping = try matchProfile(ctx.arena, profile, state.monitors) orelse {
        std.log.err("profile '{s}' does not match the connected monitors", .{name});
        return error.ProfileMismatch;
    };
    if (!ctx.force and isApplied(state, profile, mapping)) {
        ctx.print("Profile '{s}' is already active\n", .{name});
        return;
    }
    try applyNamed(ctx, conn, state, name, profile, mapping);
}

/// Applies the first matching profile (alphabetically) unless one of the
/// matching profiles is already active. Returns false if none matches.
fn change(ctx: *Ctx, conn: *x11.Connection, state: State) !bool {
    var first: ?struct { name: []const u8, profile: Profile, mapping: []usize } = null;
    for (try listProfiles(ctx)) |name| {
        const profile = loadProfile(ctx, name) catch continue;
        const mapping = try matchProfile(ctx.arena, profile, state.monitors) orelse continue;
        if (isApplied(state, profile, mapping)) {
            ctx.print("Profile '{s}' is already active\n", .{name});
            return true;
        }
        if (first == null) first = .{ .name = name, .profile = profile, .mapping = mapping };
    }
    const f = first orelse {
        ctx.print("No profile matches the connected monitors\n", .{});
        return false;
    };
    try applyNamed(ctx, conn, state, f.name, f.profile, f.mapping);
    return true;
}

fn cmdDaemon(ctx: *Ctx, conn: *x11.Connection) !void {
    try conn.selectInput(x11.notify_mask.output_change);
    var last_key: []u8 = &.{};
    defer ctx.gpa.free(last_key);
    var iteration = std.heap.ArenaAllocator.init(ctx.gpa);
    defer iteration.deinit();
    var first = true;
    while (true) : (first = false) {
        _ = iteration.reset(.retain_capacity);
        ctx.arena = iteration.allocator();

        // Only probe at startup; afterwards the server has already probed
        // when it tells us about a change, and probing could itself emit
        // events.
        const state = try gatherState(ctx.arena, conn, first);
        const key = try state.key(ctx.arena);
        if (!std.mem.eql(u8, key, last_key)) {
            ctx.gpa.free(last_key);
            last_key = &.{};
            if (change(ctx, conn, state)) |_| {
                last_key = try ctx.gpa.dupe(u8, key);
            } else |err| {
                std.log.err("change failed: {t}", .{err});
            }
        }

        // Wait for a hotplug event, then until things have settled.
        _ = try conn.waitEvent(ctx.arena, -1);
        while (try conn.waitEvent(ctx.arena, 1500)) |_| {}
    }
}

fn cmdRemove(ctx: *Ctx, name: []const u8) !void {
    try validateName(name);
    std.fs.deleteFileAbsolute(try ctx.profilePath(name)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("no profile named '{s}'", .{name});
            return error.ProfileNotFound;
        },
        else => return err,
    };
    ctx.print("Removed profile '{s}'\n", .{name});
}

// ---- main ---------------------------------------------------------------------

fn configDir(arena: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |dir| {
        if (dir.len != 0) return std.fs.path.join(arena, &.{ dir, "zigautorandr" });
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(arena, &.{ home, ".config", "zigautorandr" });
}

pub fn main() u8 {
    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var out_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);

    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .out = &stdout.interface,
        .config_dir = undefined,
    };
    run(&ctx) catch |err| {
        if (err == error.XRequestFailed) {
            if (ctx.conn) |conn| if (conn.last_error) |e| {
                std.log.err("X error {d} in request {d}.{d} (value 0x{x})", .{ e.code, e.major, e.minor, e.bad_value });
            };
        }
        std.log.err("{t}", .{err});
        return 1;
    };
    return 0;
}

fn run(ctx: *Ctx) !void {
    const args = try std.process.argsAlloc(ctx.arena);
    var positional: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            ctx.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            ctx.force = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            ctx.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            ctx.print("zigautorandr {s}\n", .{build_options.version});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("unknown option '{s}'\n\n{s}", .{ arg, usage });
            return error.InvalidArguments;
        } else try positional.append(ctx.arena, arg);
    }
    const cmd = if (positional.items.len > 0) positional.items[0] else "status";
    const Command = enum { status, save, load, change, remove, daemon };
    const command = std.meta.stringToEnum(Command, cmd) orelse {
        std.log.err("unknown command '{s}'\n\n{s}", .{ cmd, usage });
        return error.InvalidArguments;
    };
    const wants_name = command == .save or command == .load or command == .remove;
    if (positional.items.len != @as(usize, if (wants_name) 2 else 1) and !(command == .status and positional.items.len == 0)) {
        std.log.err("wrong number of arguments\n\n{s}", .{usage});
        return error.InvalidArguments;
    }

    ctx.config_dir = try configDir(ctx.arena);
    if (command == .remove) return cmdRemove(ctx, positional.items[1]);

    var conn = try x11.Connection.open(ctx.gpa, ctx.arena);
    defer conn.close();
    ctx.conn = &conn;

    switch (command) {
        .status => try cmdStatus(ctx, &conn),
        .save => try cmdSave(ctx, &conn, positional.items[1]),
        .load => try cmdLoad(ctx, &conn, positional.items[1]),
        .change => _ = try change(ctx, &conn, try gatherState(ctx.arena, &conn, true)),
        .daemon => try cmdDaemon(ctx, &conn),
        .remove => unreachable,
    }
}

test {
    _ = x11;
    _ = edid;
}

test matchProfile {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info: x11.OutputInfo = undefined;
    const monitors = [_]Monitor{
        .{ .output = 1, .name = "DP-1", .info = info, .fingerprint = "aaa", .description = "" },
        .{ .output = 2, .name = "DP-2", .info = info, .fingerprint = "aaa", .description = "" },
        .{ .output = 3, .name = "eDP", .info = info, .fingerprint = "bbb", .description = "" },
    };
    var entries = [_]OutputConfig{
        .{ .fingerprint = "bbb", .output = "eDP-1" },
        .{ .fingerprint = "aaa", .output = "DP-2" },
        .{ .fingerprint = "aaa", .output = "DP-7" },
    };
    const map = (try matchProfile(a, .{ .outputs = &entries }, &monitors)).?;
    // DP-2 matches by name, DP-1 takes the remaining identical monitor,
    // eDP matches by EDID even though the output got renamed.
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, map);

    entries[0].fingerprint = "ccc";
    try std.testing.expect(try matchProfile(a, .{ .outputs = &entries }, &monitors) == null);
}

test CrtcTransform {
    const mode: x11.ModeInfo = .{
        .id = 1,
        .width = 1920,
        .height = 1080,
        .dot_clock = 0,
        .hsync_start = 0,
        .hsync_end = 0,
        .htotal = 0,
        .hskew = 0,
        .vsync_start = 0,
        .vsync_end = 0,
        .vtotal = 0,
        .flags = 0,
        .name = "",
    };
    // Old profiles without transform are unscaled.
    const old = try std.json.parseFromSliceLeaky(OutputConfig, std.testing.allocator, "{\"fingerprint\":\"a\"}", .{});
    const identity = try old.wantTransform();
    try std.testing.expect(identity.eql(.{}));
    try std.testing.expectEqual(null, identity.toFloat());

    const e: OutputConfig = .{ .fingerprint = "a", .transform = .{ 1.5, 0, 0, 0, 1.25, 0, 0, 0, 1 } };
    const t = try e.wantTransform();
    try std.testing.expectEqualStrings("bilinear", t.filter);
    try std.testing.expectEqual(e.transform.?, t.toFloat().?);
    const size = try t.footprint(mode, Rotation.rotate_0);
    try std.testing.expectEqual(2880, size.w);
    try std.testing.expectEqual(1350, size.h);
    // Rotation is applied before the transform.
    const rotated = try t.footprint(mode, Rotation.rotate_90);
    try std.testing.expectEqual(1620, rotated.w);
    try std.testing.expectEqual(2400, rotated.h);
    // Filter only matters for non-identity transforms.
    try std.testing.expect(!t.eql(.{ .matrix = t.matrix, .filter = "nearest" }));
    try std.testing.expect(identity.eql(.{ .filter = "nearest" }));

    const bad: OutputConfig = .{ .fingerprint = "a", .transform = .{ std.math.nan(f64), 0, 0, 0, 1, 0, 0, 0, 1 } };
    try std.testing.expectError(error.InvalidTransform, bad.wantTransform());
}
