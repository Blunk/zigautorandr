//! EDID (VESA E-EDID 1.3/1.4) base block layout, validation, a stable
//! fingerprint and a human readable description of the monitor.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const block_size = 128;

const header = [8]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };

pub const fingerprint_len = 32;

/// Three letter PNP vendor ID, each letter 1..26 = 'A'..'Z'. Big-endian on
/// the wire, unlike every other multi-byte EDID field.
pub const Manufacturer = packed struct(u16) {
    third: u5,
    second: u5,
    first: u5,
    reserved: u1 = 0,

    pub fn code(m: Manufacturer) [3]u8 {
        return .{ letter(m.first), letter(m.second), letter(m.third) };
    }

    fn letter(v: u5) u8 {
        return if (v >= 1 and v <= 26) '@' + @as(u8, v) else '?';
    }
};

/// Byte 20; the meaning of the low bits depends on `is_digital` (bit 7).
pub const VideoInput = packed union {
    digital: packed struct(u8) {
        interface: Interface,
        /// 0 = undefined, 1..6 = 6, 8, ..., 16 bits per color, 7 = reserved.
        bit_depth: u3,
        is_digital: bool,

        pub fn bitsPerColor(d: @This()) ?u5 {
            return if (d.bit_depth >= 1 and d.bit_depth <= 6) 4 + 2 * @as(u5, d.bit_depth) else null;
        }
    },
    analog: packed struct(u8) {
        vsync_serration: bool,
        sync_on_green: bool,
        composite_sync: bool,
        separate_sync: bool,
        blank_to_black_setup: bool,
        /// Video white and sync levels relative to blank.
        signal_level: u2,
        is_digital: bool,
    },

    pub const Interface = enum(u4) { undefined = 0, dvi, hdmi_a, hdmi_b, mddi, displayport, _ };

    pub fn isDigital(v: VideoInput) bool {
        return v.digital.is_digital;
    }
};

/// Byte 24.
pub const Features = packed struct(u8) {
    continuous_frequency: bool,
    /// The first detailed timing is the native/preferred mode.
    preferred_timing_is_native: bool,
    srgb_default: bool,
    /// Digital: supported color encodings, analog: display color type.
    color_type: u2,
    dpms_active_off: bool,
    dpms_suspend: bool,
    dpms_standby: bool,
};

/// Bytes 25..34: CIE xy coordinates of the primaries and white point as
/// 10-bit fractions (value / 1024); 2 low bits packed, 8 high bits each.
pub const Chromaticity = extern struct {
    red_green_low: packed struct(u8) { green_y: u2, green_x: u2, red_y: u2, red_x: u2 },
    blue_white_low: packed struct(u8) { white_y: u2, white_x: u2, blue_y: u2, blue_x: u2 },
    red_x_high: u8,
    red_y_high: u8,
    green_x_high: u8,
    green_y_high: u8,
    blue_x_high: u8,
    blue_y_high: u8,
    white_x_high: u8,
    white_y_high: u8,

    pub const Point = struct { x: u10, y: u10 };

    fn point(x_high: u8, x_low: u2, y_high: u8, y_low: u2) Point {
        return .{ .x = @as(u10, x_high) << 2 | x_low, .y = @as(u10, y_high) << 2 | y_low };
    }

    pub fn red(c: Chromaticity) Point {
        return point(c.red_x_high, c.red_green_low.red_x, c.red_y_high, c.red_green_low.red_y);
    }
    pub fn green(c: Chromaticity) Point {
        return point(c.green_x_high, c.red_green_low.green_x, c.green_y_high, c.red_green_low.green_y);
    }
    pub fn blue(c: Chromaticity) Point {
        return point(c.blue_x_high, c.blue_white_low.blue_x, c.blue_y_high, c.blue_white_low.blue_y);
    }
    pub fn white(c: Chromaticity) Point {
        return point(c.white_x_high, c.blue_white_low.white_x, c.white_y_high, c.blue_white_low.white_y);
    }
};

/// Bytes 35..37: legacy VESA/IBM/Apple modes, one bit each.
pub const EstablishedTimings = extern struct {
    first: packed struct(u8) {
        @"800x600@60": bool,
        @"800x600@56": bool,
        @"640x480@75": bool,
        @"640x480@72": bool,
        @"640x480@67": bool,
        @"640x480@60": bool,
        @"720x400@88": bool,
        @"720x400@70": bool,
    },
    second: packed struct(u8) {
        @"1280x1024@75": bool,
        @"1024x768@75": bool,
        @"1024x768@70": bool,
        @"1024x768@60": bool,
        @"1024x768@87i": bool,
        @"832x624@75": bool,
        @"800x600@75": bool,
        @"800x600@72": bool,
    },
    manufacturer: packed struct(u8) {
        reserved: u7,
        @"1152x870@75": bool,
    },
};

/// Bytes 38..53, 8 entries of 2 bytes.
pub const StandardTiming = extern struct {
    /// Horizontal resolution / 8 - 31; 0x01 0x01 marks an unused entry.
    x_resolution: u8,
    info: packed struct(u8) {
        /// Refresh rate - 60 Hz.
        refresh: u6,
        aspect: Aspect,
    },

    /// 16:10 is 1:1 in EDID < 1.3.
    pub const Aspect = enum(u2) { @"16:10", @"4:3", @"5:4", @"16:9" };

    pub fn isUsed(t: StandardTiming) bool {
        return !(t.x_resolution == 0x01 and @as(u8, @bitCast(t.info)) == 0x01) and t.x_resolution != 0;
    }

    pub fn width(t: StandardTiming) u16 {
        return (@as(u16, t.x_resolution) + 31) * 8;
    }

    pub fn height(t: StandardTiming) u16 {
        const w = t.width();
        return switch (t.info.aspect) {
            .@"16:10" => w * 10 / 16,
            .@"4:3" => w * 3 / 4,
            .@"5:4" => w * 4 / 5,
            .@"16:9" => w * 9 / 16,
        };
    }

    pub fn refreshRate(t: StandardTiming) u8 {
        return @as(u8, t.info.refresh) + 60;
    }
};

/// An 18 byte descriptor holding a mode. Values above 8 bits are split into
/// a low byte and high bits packed with other fields.
pub const DetailedTiming = extern struct {
    /// In 10 kHz units; 0 marks a `DisplayDescriptor` instead.
    pixel_clock: u16,
    h_active_low: u8,
    h_blanking_low: u8,
    h_high: packed struct(u8) { blanking: u4, active: u4 },
    v_active_low: u8,
    v_blanking_low: u8,
    v_high: packed struct(u8) { blanking: u4, active: u4 },
    h_front_porch_low: u8,
    h_sync_width_low: u8,
    v_sync_low: packed struct(u8) { width: u4, front_porch: u4 },
    sync_high: packed struct(u8) { v_sync_width: u2, v_front_porch: u2, h_sync_width: u2, h_front_porch: u2 },
    h_image_mm_low: u8,
    v_image_mm_low: u8,
    image_mm_high: packed struct(u8) { v: u4, h: u4 },
    h_border: u8,
    v_border: u8,
    flags: packed struct(u8) {
        stereo_low: u1,
        /// Analog/digital, composite/separate sync and polarities.
        sync: u4,
        stereo_high: u2,
        interlaced: bool,
    },

    pub fn pixelClockKhz(t: DetailedTiming) u32 {
        return @as(u32, t.pixel_clock) * 10;
    }
    pub fn hActive(t: DetailedTiming) u12 {
        return @as(u12, t.h_high.active) << 8 | t.h_active_low;
    }
    pub fn hBlanking(t: DetailedTiming) u12 {
        return @as(u12, t.h_high.blanking) << 8 | t.h_blanking_low;
    }
    pub fn vActive(t: DetailedTiming) u12 {
        return @as(u12, t.v_high.active) << 8 | t.v_active_low;
    }
    pub fn vBlanking(t: DetailedTiming) u12 {
        return @as(u12, t.v_high.blanking) << 8 | t.v_blanking_low;
    }
    pub fn hFrontPorch(t: DetailedTiming) u10 {
        return @as(u10, t.sync_high.h_front_porch) << 8 | t.h_front_porch_low;
    }
    pub fn hSyncWidth(t: DetailedTiming) u10 {
        return @as(u10, t.sync_high.h_sync_width) << 8 | t.h_sync_width_low;
    }
    pub fn vFrontPorch(t: DetailedTiming) u6 {
        return @as(u6, t.sync_high.v_front_porch) << 4 | t.v_sync_low.front_porch;
    }
    pub fn vSyncWidth(t: DetailedTiming) u6 {
        return @as(u6, t.sync_high.v_sync_width) << 4 | t.v_sync_low.width;
    }
    pub fn hImageMm(t: DetailedTiming) u12 {
        return @as(u12, t.image_mm_high.h) << 8 | t.h_image_mm_low;
    }
    pub fn vImageMm(t: DetailedTiming) u12 {
        return @as(u12, t.image_mm_high.v) << 8 | t.v_image_mm_low;
    }
};

/// An 18 byte descriptor holding monitor information instead of a mode.
pub const DisplayDescriptor = extern struct {
    /// Always 0 (distinguishes it from a `DetailedTiming`).
    pixel_clock: u16,
    reserved: u8,
    tag: Tag,
    reserved2: u8,
    data: [13]u8,

    pub const Tag = enum(u8) {
        dummy = 0x10,
        established_timings_3 = 0xf7,
        cvt_3byte_timings = 0xf8,
        color_management = 0xf9,
        standard_timings = 0xfa,
        white_point = 0xfb,
        product_name = 0xfc,
        range_limits = 0xfd,
        text = 0xfe,
        serial_number = 0xff,
        /// 0x00..0x0f are manufacturer specific.
        _,
    };

    /// For text descriptors: the text up to the newline, without padding.
    pub fn text(d: *const DisplayDescriptor) []const u8 {
        const end = std.mem.indexOfScalar(u8, &d.data, '\n') orelse d.data.len;
        return std.mem.trim(u8, d.data[0..end], " \x00");
    }
};

pub const Descriptor = extern union {
    timing: DetailedTiming,
    display: DisplayDescriptor,

    pub fn isTiming(d: Descriptor) bool {
        return d.timing.pixel_clock != 0;
    }
};

/// The 128 byte EDID base block. Obtain it through `parse`, which converts
/// the multi-byte fields to native byte order.
pub const BaseBlock = extern struct {
    header: [8]u8,
    manufacturer: Manufacturer,
    product_code: u16,
    /// 0 if unused; many monitors put the serial in a descriptor instead.
    serial_number: u32,
    /// 1..54, 0 = unspecified, 0xff = `manufacture_year` is the model year.
    manufacture_week: u8,
    /// Years since 1990.
    manufacture_year: u8,
    version: u8,
    revision: u8,
    video_input: VideoInput,
    /// 0 if unknown or variable (then together with the height an aspect ratio).
    screen_width_cm: u8,
    screen_height_cm: u8,
    /// gamma * 100 - 100; 0xff = defined in an extension.
    gamma: u8,
    features: Features,
    chromaticity: Chromaticity,
    established_timings: EstablishedTimings,
    standard_timings: [8]StandardTiming,
    /// The first one is the preferred mode.
    descriptors: [4]Descriptor,
    extension_count: u8,
    /// Makes the sum of all 128 bytes 0 (mod 256).
    checksum: u8,

    pub fn year(b: BaseBlock) u16 {
        return 1990 + @as(u16, b.manufacture_year);
    }

    pub fn gammaValue(b: BaseBlock) ?f32 {
        if (b.gamma == 0xff) return null;
        return (@as(f32, @floatFromInt(b.gamma)) + 100) / 100;
    }

    /// The first display descriptor with `tag`.
    pub fn findDisplay(b: *const BaseBlock, tag: DisplayDescriptor.Tag) ?*const DisplayDescriptor {
        for (&b.descriptors) |*d| {
            if (!d.isTiming() and d.display.tag == tag) return &d.display;
        }
        return null;
    }

    pub fn productName(b: *const BaseBlock) ?[]const u8 {
        return if (b.findDisplay(.product_name)) |d| d.text() else null;
    }

    pub fn serialText(b: *const BaseBlock) ?[]const u8 {
        return if (b.findDisplay(.serial_number)) |d| d.text() else null;
    }
};

comptime {
    std.debug.assert(@sizeOf(BaseBlock) == block_size);
    std.debug.assert(@sizeOf(Descriptor) == 18);
    std.debug.assert(@offsetOf(BaseBlock, "manufacturer") == 8);
    std.debug.assert(@offsetOf(BaseBlock, "video_input") == 20);
    std.debug.assert(@offsetOf(BaseBlock, "chromaticity") == 25);
    std.debug.assert(@offsetOf(BaseBlock, "established_timings") == 35);
    std.debug.assert(@offsetOf(BaseBlock, "standard_timings") == 38);
    std.debug.assert(@offsetOf(BaseBlock, "descriptors") == 54);
    std.debug.assert(@offsetOf(BaseBlock, "extension_count") == 126);
}

pub fn isValid(data: []const u8) bool {
    return data.len >= block_size and std.mem.eql(u8, data[0..8], &header);
}

/// Decodes the base block. The checksum is not enforced: plenty of monitors
/// get it wrong, and rejecting them would change their fingerprint.
pub fn parse(data: []const u8) error{InvalidEdid}!BaseBlock {
    if (!isValid(data)) return error.InvalidEdid;
    var b = std.mem.bytesToValue(BaseBlock, data[0..block_size]);
    b.manufacturer = @bitCast(std.mem.bigToNative(u16, @bitCast(b.manufacturer)));
    b.product_code = std.mem.littleToNative(u16, b.product_code);
    b.serial_number = std.mem.littleToNative(u32, b.serial_number);
    for (&b.descriptors) |*d| d.timing.pixel_clock = std.mem.littleToNative(u16, d.timing.pixel_clock);
    return b;
}

/// Hash of the 128 byte base block as sent by the monitor. Extension blocks
/// are left out on purpose: some monitors rewrite them when e.g. FreeSync/HDR
/// is toggled in the OSD, while the base block (vendor, product, serial, ...)
/// stays the same.
pub fn fingerprint(data: []const u8) [fingerprint_len]u8 {
    std.debug.assert(isValid(data));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data[0..block_size], &hash, .{});
    return std.fmt.bytesToHex(hash[0 .. fingerprint_len / 2].*, .lower);
}

/// e.g. "DEL DELL U2720Q (product 0xa0c5, serial ABC123)"
pub fn describe(arena: Allocator, b: BaseBlock) ![]const u8 {
    const serial = b.serialText() orelse
        if (b.serial_number != 0) try std.fmt.allocPrint(arena, "{d}", .{b.serial_number}) else "-";
    return std.fmt.allocPrint(arena, "{s} {s} (product 0x{x:0>4}, serial {s})", .{
        &b.manufacturer.code(), b.productName() orelse "", b.product_code, serial,
    });
}

test "describe and fingerprint" {
    var e = [_]u8{0} ** block_size;
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
        try describe(arena.allocator(), try parse(&e)),
    );
    const fp1 = fingerprint(&e);
    e[12] = 1;
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fingerprint(&e)));
    try std.testing.expectError(error.InvalidEdid, parse(e[0..127]));
}

test "field decoding" {
    var e = [_]u8{0} ** block_size;
    @memcpy(e[0..8], &header);
    e[12] = 0x78; // serial 0x12345678, little-endian
    e[13] = 0x56;
    e[14] = 0x34;
    e[15] = 0x12;
    e[17] = 33; // 2023
    e[20] = 0xb5; // digital, 10 bits per color, DisplayPort
    e[23] = 120; // gamma 2.2
    e[24] = 0x06; // sRGB default, preferred timing is native
    e[35] = 0x20; // 640x480@60
    e[38] = 0xd1; // 1920x1080@60 (16:9)
    e[39] = 0xc0;
    e[40] = 0x01; // unused
    e[41] = 0x01;
    // 2560x1440@59.95: 241.5 MHz, blanking 160/41, porches 48/3, sync 32/5,
    // 597x336 mm.
    const dtd = [18]u8{ 0x56, 0x5e, 0x00, 0xa0, 0xa0, 0xa0, 0x29, 0x50, 0x30, 0x20, 0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00, 0x1a };
    @memcpy(e[54..72], &dtd);

    const b = try parse(&e);
    try std.testing.expectEqual(0x12345678, b.serial_number);
    try std.testing.expectEqual(2023, b.year());
    try std.testing.expect(b.video_input.isDigital());
    try std.testing.expectEqual(.displayport, b.video_input.digital.interface);
    try std.testing.expectEqual(10, b.video_input.digital.bitsPerColor().?);
    try std.testing.expectEqual(2.2, b.gammaValue().?);
    try std.testing.expect(b.features.srgb_default and b.features.preferred_timing_is_native);
    try std.testing.expect(b.established_timings.first.@"640x480@60");
    try std.testing.expect(!b.established_timings.first.@"800x600@60");
    try std.testing.expect(b.standard_timings[0].isUsed());
    try std.testing.expectEqual(1920, b.standard_timings[0].width());
    try std.testing.expectEqual(1080, b.standard_timings[0].height());
    try std.testing.expectEqual(60, b.standard_timings[0].refreshRate());
    try std.testing.expect(!b.standard_timings[1].isUsed());

    try std.testing.expect(b.descriptors[0].isTiming());
    try std.testing.expect(!b.descriptors[1].isTiming());
    const t = b.descriptors[0].timing;
    try std.testing.expectEqual(241500, t.pixelClockKhz());
    try std.testing.expectEqual(2560, t.hActive());
    try std.testing.expectEqual(160, t.hBlanking());
    try std.testing.expectEqual(1440, t.vActive());
    try std.testing.expectEqual(41, t.vBlanking());
    try std.testing.expectEqual(48, t.hFrontPorch());
    try std.testing.expectEqual(32, t.hSyncWidth());
    try std.testing.expectEqual(3, t.vFrontPorch());
    try std.testing.expectEqual(5, t.vSyncWidth());
    try std.testing.expectEqual(597, t.hImageMm());
    try std.testing.expectEqual(336, t.vImageMm());
    try std.testing.expect(!t.flags.interlaced);
}
