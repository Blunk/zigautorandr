//! EDID helpers: validation, a stable fingerprint and a human readable
//! description of the monitor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const header = [8]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };

pub const fingerprint_len = 32;

pub fn isValid(edid: []const u8) bool {
    return edid.len >= 128 and std.mem.eql(u8, edid[0..8], &header);
}

/// Hash of the 128 byte base block. Extension blocks are left out on purpose:
/// some monitors rewrite them when e.g. FreeSync/HDR is toggled in the OSD,
/// while the base block (vendor, product, serial, ...) stays the same.
pub fn fingerprint(edid: []const u8) [fingerprint_len]u8 {
    std.debug.assert(isValid(edid));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(edid[0..128], &hash, .{});
    return std.fmt.bytesToHex(hash[0 .. fingerprint_len / 2].*, .lower);
}

/// Text of a display descriptor (0xfc = name, 0xff = serial) if present.
fn descriptorText(edid: []const u8, tag: u8) ?[]const u8 {
    var off: usize = 54;
    while (off + 18 <= 126) : (off += 18) {
        const d = edid[off..][0..18];
        if (d[0] != 0 or d[1] != 0 or d[3] != tag) continue;
        const text = d[5..18];
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        return std.mem.trim(u8, text[0..end], " \x00");
    }
    return null;
}

pub fn manufacturer(edid: []const u8) [3]u8 {
    const m = std.mem.readInt(u16, edid[8..10], .big);
    var out: [3]u8 = undefined;
    for (&out, 0..) |*c, i| {
        const v: u8 = @intCast((m >> @intCast(10 - 5 * i)) & 0x1f);
        c.* = if (v >= 1 and v <= 26) '@' + v else '?';
    }
    return out;
}

/// e.g. "DEL DELL U2720Q (product 0xa0c5, serial ABC123)"
pub fn describe(arena: Allocator, edid: []const u8) ![]const u8 {
    const mfg = manufacturer(edid);
    const product = std.mem.readInt(u16, edid[10..12], .little);
    const serial_num = std.mem.readInt(u32, edid[12..16], .little);
    const name = descriptorText(edid, 0xfc) orelse "";
    const serial = descriptorText(edid, 0xff) orelse
        if (serial_num != 0) try std.fmt.allocPrint(arena, "{d}", .{serial_num}) else "-";
    return std.fmt.allocPrint(arena, "{s} {s} (product 0x{x:0>4}, serial {s})", .{ &mfg, name, product, serial });
}

test "describe and fingerprint" {
    var e = [_]u8{0} ** 128;
    @memcpy(e[0..8], &header);
    // "DEL" = 00100 00101 01100
    e[8] = 0x10;
    e[9] = 0xac;
    e[10] = 0xc5;
    e[11] = 0xa0;
    e[54 + 3] = 0xfc;
    @memcpy(e[54 + 5 ..][0..8], "DELL X1\n");
    e[72 + 3] = 0xff;
    @memcpy(e[72 + 5 ..][0..4], "SN42");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "DEL DELL X1 (product 0xa0c5, serial SN42)",
        try describe(arena.allocator(), &e),
    );
    const fp1 = fingerprint(&e);
    e[12] = 1;
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fingerprint(&e)));
}
