const std = @import("std");
const json = @import("json.zig");
const testing = std.testing;

fn encodeToBuf(value: anytype, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try json.encode(value, &w);
    return w.buffered();
}

fn expectEncodes(value: anytype, expected: []const u8) !void {
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, try encodeToBuf(value, &buf));
}

// ------------------------------------------------------------------ scalars

test "encode scalars" {
    try expectEncodes(@as(u8, 7), "7");
    try expectEncodes(@as(i64, -9223372036854775808), "-9223372036854775808");
    try expectEncodes(@as(u64, 18446744073709551615), "18446744073709551615");
    try expectEncodes(true, "true");
    try expectEncodes(false, "false");
    try expectEncodes(@as(?u8, null), "null");
    try expectEncodes(@as(f64, 1.5), "1.5");
    try expectEncodes("hi", "\"hi\"");
}

test "encode non-finite floats as null" {
    try expectEncodes(std.math.nan(f64), "null");
    try expectEncodes(std.math.inf(f64), "null");
    try expectEncodes(-std.math.inf(f64), "null");

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.NonFiniteFloat,
        json.encodeWithOptions(std.math.nan(f64), &w, .{ .non_finite = .fail }),
    );
}

test "decode integer limits and range errors" {
    const a = std.testing.allocator;
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try json.decodeFromSliceLeaky(u64, a, "18446744073709551615"));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try json.decodeFromSliceLeaky(i64, a, "-9223372036854775808"));
    try testing.expectEqual(@as(i32, -2147483648), try json.decodeFromSliceLeaky(i32, a, "-2147483648"));

    try testing.expectError(error.NumberOutOfRange, json.decodeFromSliceLeaky(u8, a, "256"));
    try testing.expectError(error.NumberOutOfRange, json.decodeFromSliceLeaky(u8, a, "-1"));
    try testing.expectError(error.InvalidNumber, json.decodeFromSliceLeaky(u32, a, "1.5"));
    try testing.expectError(error.InvalidNumber, json.decodeFromSliceLeaky(u32, a, "1e3"));
}

/// Every one of these must land on the same bits `std.fmt.parseFloat`
/// produces, whether it takes the exact fast path or falls through to it.
const float_inputs = [_][]const u8{
    "0",                              "-0",                      "1",
    "0.5",                            "3.14159",                 "1234.56",
    "0.1",                            "-0.1",                    "1e10",
    "1e-10",                          "5e-324",                  "1.5e300",
    "1.7976931348623157e308",         "0.30000000000000004",     "2.2250738585072011e-308",
    "123456789012345678901234567890",
    // Boundaries of the exact path: mantissa at and past 2^53, exponent at and
    // past +-22, and truncation past 19 significant digits.
    "9007199254740992",        "9007199254740993",
    "9007199254740994",               "1e22",                    "1e23",
    "1e-22",                          "1e-23",                   "-1234.5678e-12",
    "1.2345678901234567890123",       "0.000000000000000000001", "12345678901234567890",
    "-0.0",
};

test "decode floats agree with std" {
    const a = std.testing.allocator;
    for (float_inputs) |in| {
        const mine = try json.decodeFromSliceLeaky(f64, a, in);
        const theirs = try std.fmt.parseFloat(f64, in);
        try testing.expectEqual(@as(u64, @bitCast(theirs)), @as(u64, @bitCast(mine)));
    }
}

test "decode f32 agrees with std" {
    const a = std.testing.allocator;
    for (float_inputs) |in| {
        const mine = try json.decodeFromSliceLeaky(f32, a, in);
        const theirs = try std.fmt.parseFloat(f32, in);
        try testing.expectEqual(@as(u32, @bitCast(theirs)), @as(u32, @bitCast(mine)));
    }
}

test "floats agree with std when trickled one byte at a time" {
    const a = std.testing.allocator;
    const T = struct { x: f64 };
    var doc_buf: [128]u8 = undefined;
    for (float_inputs) |in| {
        const doc = try std.fmt.bufPrint(&doc_buf, "{{\"x\":{s}}}", .{in});
        // An 8-byte buffer forces most of these across a fill, so the fast path
        // declines and the general path has to produce identical bits.
        var buffer: [8]u8 = undefined;
        var trickle = TrickleReader.init(&buffer, doc);
        const mine = try json.decodeLeaky(T, a, &trickle.reader);
        const theirs = try std.fmt.parseFloat(f64, in);
        try testing.expectEqual(@as(u64, @bitCast(theirs)), @as(u64, @bitCast(mine.x)));
    }
}

// ------------------------------------------------------------------ strings

test "decode string escapes and surrogate pairs" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "\"plain\"", .want = "plain" },
        .{ .in = "\"a\\\"b\\\\c\\/d\"", .want = "a\"b\\c/d" },
        .{ .in = "\"\\b\\f\\n\\r\\t\"", .want = "\x08\x0c\n\r\t" },
        .{ .in = "\"\\u0041\\u00e9\\u20ac\"", .want = "A\u{e9}\u{20ac}" },
        .{ .in = "\"\\ud83d\\ude00\"", .want = "\u{1f600}" },
        .{ .in = "\"caf\u{e9} \u{fc}ber\"", .want = "caf\u{e9} \u{fc}ber" },
        // Escape beyond the 16-byte scan chunk, so the scan resumes mid-string.
        .{ .in = "\"0123456789abcdefghij\\nklmnopqrstuvwxyz\"", .want = "0123456789abcdefghij\nklmnopqrstuvwxyz" },
    };
    for (cases) |c| {
        const got = try json.decodeFromSliceLeaky([]const u8, a, c.in);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "reject malformed escapes" {
    const a = std.testing.allocator;
    try testing.expectError(error.InvalidSurrogatePair, json.decodeFromSliceLeaky([]const u8, a, "\"\\ud83d\""));
    try testing.expectError(error.InvalidSurrogatePair, json.decodeFromSliceLeaky([]const u8, a, "\"\\udc00x\""));
    try testing.expectError(error.InvalidSurrogatePair, json.decodeFromSliceLeaky([]const u8, a, "\"\\ud83dx\""));
    try testing.expectError(error.InvalidEscape, json.decodeFromSliceLeaky([]const u8, a, "\"\\q\""));
    try testing.expectError(error.InvalidEscape, json.decodeFromSliceLeaky([]const u8, a, "\"\\u00zz\""));
}

test "encode escapes what std.json escapes" {
    try expectEncodes("quote\" back\\ nl\n tab\t", "\"quote\\\" back\\\\ nl\\n tab\\t\"");
    try expectEncodes("ctl\x01 del\x7f", "\"ctl\\u0001 del\x7f\"");
    try expectEncodes("caf\u{e9}", "\"caf\u{e9}\"");
}

// ------------------------------------------------------------------ structs

const Simple = struct { id: u64, name: []const u8, active: bool, score: f64 };

test "struct round trip" {
    const a = std.testing.allocator;
    const value: Simple = .{ .id = 42, .name = "alice", .active = true, .score = 1.25 };
    try expectEncodes(value, "{\"id\":42,\"name\":\"alice\",\"active\":true,\"score\":1.25}");

    const decoded = try json.decodeFromSlice(Simple, a, "{\"id\":42,\"name\":\"alice\",\"active\":true,\"score\":1.25}");
    defer decoded.deinit();
    try testing.expectEqual(@as(u64, 42), decoded.value.id);
    try testing.expectEqualStrings("alice", decoded.value.name);
    try testing.expect(decoded.value.active);
    try testing.expectEqual(@as(f64, 1.25), decoded.value.score);
}

test "optionals, defaults and omitted fields" {
    const a = std.testing.allocator;
    const T = struct { req: []const u8, opt: ?u32, dflt: u8 = 7 };

    try expectEncodes(T{ .req = "x", .opt = null }, "{\"req\":\"x\",\"dflt\":7}");
    try expectEncodes(T{ .req = "x", .opt = 3 }, "{\"req\":\"x\",\"opt\":3,\"dflt\":7}");

    const v = try json.decodeFromSliceLeaky(T, a, "{\"req\":\"x\"}");
    defer a.free(v.req);
    try testing.expectEqual(@as(?u32, null), v.opt);
    try testing.expectEqual(@as(u8, 7), v.dflt);

    // On error a leaky decode leaves partial allocations behind by contract,
    // so these run against an arena rather than the testing allocator.
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try testing.expectError(error.MissingField, json.decodeFromSliceLeaky(T, arena.allocator(), "{}"));
    try testing.expectError(error.UnknownField, json.decodeFromSliceLeaky(T, arena.allocator(), "{\"req\":\"x\",\"nope\":1}"));
}

test "omit_null_fields off" {
    const T = struct {
        opt: ?u32,
        pub fn jsonFormat() json.StructOptions {
            return .{ .omit_null_fields = false };
        }
    };
    try expectEncodes(T{ .opt = null }, "{\"opt\":null}");
}

test "custom field names" {
    const T = struct {
        user_id: u32,
        display_name: []const u8,

        pub fn jsonFormat() json.StructOptions {
            return .{ .key = .custom };
        }
        pub fn jsonFieldName(comptime field: std.meta.FieldEnum(@This())) []const u8 {
            return switch (field) {
                .user_id => "userId",
                .display_name => "displayName",
            };
        }
    };
    const a = std.testing.allocator;
    try expectEncodes(T{ .user_id = 1, .display_name = "z" }, "{\"userId\":1,\"displayName\":\"z\"}");

    const v = try json.decodeFromSliceLeaky(T, a, "{\"userId\":1,\"displayName\":\"z\"}");
    defer a.free(v.display_name);
    try testing.expectEqual(@as(u32, 1), v.user_id);
}

test "skip_unknown_fields steps over every value shape" {
    const T = struct {
        keep: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .skip_unknown_fields = true };
        }
    };
    const a = std.testing.allocator;
    const doc =
        \\{"a":{"nested":[1,2,{"deep":"str\"esc"}]},"b":[[]],"c":null,"d":true,
        \\ "e":-1.5e3,"keep":9,"f":"tail"}
    ;
    const v = try json.decodeFromSliceLeaky(T, a, doc);
    try testing.expectEqual(@as(u8, 9), v.keep);
}

test "nested structs, slices and fixed arrays" {
    const Inner = struct { n: i32, tag: []const u8 };
    const Outer = struct { inner: Inner, list: []const Inner, fixed: [3]u8, empty: []const u32 };
    const a = std.testing.allocator;

    const doc =
        \\{"inner":{"n":-3,"tag":"t"},
        \\ "list":[{"n":1,"tag":"a"},{"n":2,"tag":"b"}],
        \\ "fixed":[1,2,3],"empty":[]}
    ;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const v = try json.decodeFromSliceLeaky(Outer, arena.allocator(), doc);
    try testing.expectEqual(@as(i32, -3), v.inner.n);
    try testing.expectEqual(@as(usize, 2), v.list.len);
    try testing.expectEqualStrings("b", v.list[1].tag);
    try testing.expectEqual([3]u8{ 1, 2, 3 }, v.fixed);
    try testing.expectEqual(@as(usize, 0), v.empty.len);
}

test "enums and tagged unions" {
    const Color = enum { red, green, blue };
    const Shape = union(enum) { circle: f64, rect: [2]u32, none };
    const a = std.testing.allocator;

    try expectEncodes(Color.green, "\"green\"");
    try testing.expectEqual(Color.blue, try json.decodeFromSliceLeaky(Color, a, "\"blue\""));
    try testing.expectError(error.InvalidEnumTag, json.decodeFromSliceLeaky(Color, a, "\"mauve\""));

    try expectEncodes(Shape{ .circle = 2.5 }, "{\"circle\":2.5}");
    try expectEncodes(Shape{ .rect = .{ 3, 4 } }, "{\"rect\":[3,4]}");

    const s = try json.decodeFromSliceLeaky(Shape, a, "{\"rect\":[3,4]}");
    try testing.expectEqual([2]u32{ 3, 4 }, s.rect);
    const n = try json.decodeFromSliceLeaky(Shape, a, "{\"none\":null}");
    try testing.expectEqual(Shape.none, n);
}

test "trailing data is rejected" {
    const a = std.testing.allocator;
    try testing.expectError(error.TrailingData, json.decodeFromSliceLeaky(u8, a, "1 2"));
    try testing.expectError(error.TrailingData, json.decodeFromSliceLeaky(u8, a, "1 junk"));
    // Trailing whitespace alone is fine.
    try testing.expectEqual(@as(u8, 1), try json.decodeFromSliceLeaky(u8, a, " 1 \n "));
}

// ------------------------------------------------------------------ streaming

/// Hands over one byte per fill, out of a caller-sized buffer: a value can
/// straddle a fill, and the reader's buffer can be smaller than the value.
const TrickleReader = struct {
    data: []const u8,
    pos: usize = 0,
    reader: std.Io.Reader,

    fn init(buffer: []u8, data: []const u8) TrickleReader {
        return .{
            .data = data,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TrickleReader = @fieldParentPtr("reader", r);
        if (self.pos >= self.data.len) return error.EndOfStream;
        if (!limit.nonzero()) return 0;
        try w.writeByte(self.data[self.pos]);
        self.pos += 1;
        return 1;
    }
};

test "decode from a trickling stream at every buffer size" {
    const a = std.testing.allocator;
    const doc =
        \\{"id":18446744073709551615,"name":"a name with \"escapes\" and \u00e9",
        \\ "active":false,"score":-1.7976931348623157e308}
    ;
    for ([_]usize{ 8, 9, 16, 32, 200 }) |buffer_len| {
        var buffer: [200]u8 = undefined;
        var trickle = TrickleReader.init(buffer[0..buffer_len], doc);
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();

        const v = try json.decodeLeaky(Simple, arena.allocator(), &trickle.reader);
        try testing.expectEqual(@as(u64, std.math.maxInt(u64)), v.id);
        try testing.expectEqualStrings("a name with \"escapes\" and \u{e9}", v.name);
        try testing.expect(!v.active);
        try testing.expectEqual(@as(f64, -1.7976931348623157e308), v.score);
    }
}

test "a string far larger than the reader buffer" {
    const a = std.testing.allocator;
    const long = "x" ** 500;
    const doc = "{\"s\":\"" ++ long ++ "\"}";
    const T = struct { s: []const u8 };

    for ([_]usize{ 8, 16, 64 }) |buffer_len| {
        var buffer: [64]u8 = undefined;
        var trickle = TrickleReader.init(buffer[0..buffer_len], doc);
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const v = try json.decodeLeaky(T, arena.allocator(), &trickle.reader);
        try testing.expectEqualStrings(long, v.s);
    }
}

test "a skipped value far larger than the reader buffer" {
    const a = std.testing.allocator;
    const long = "y" ** 400;
    const doc = "{\"skipped\":{\"deep\":[\"" ++ long ++ "\",1,2]},\"keep\":5}";
    const T = struct {
        keep: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .skip_unknown_fields = true };
        }
    };
    var buffer: [16]u8 = undefined;
    var trickle = TrickleReader.init(&buffer, doc);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const v = try json.decodeLeaky(T, arena.allocator(), &trickle.reader);
    try testing.expectEqual(@as(u8, 5), v.keep);
}

test "an object key longer than any field name is handled without allocating" {
    const a = std.testing.allocator;
    const T = struct {
        id: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .skip_unknown_fields = true };
        }
    };
    const doc = "{\"" ++ ("k" ** 300) ++ "\":1,\"id\":2}";
    var buffer: [16]u8 = undefined;
    var trickle = TrickleReader.init(&buffer, doc);
    const v = try json.decodeLeaky(T, a, &trickle.reader);
    try testing.expectEqual(@as(u8, 2), v.id);
}

test "an escaped key still matches its field" {
    const a = std.testing.allocator;
    const T = struct { id: u8 };
    const v = try json.decodeFromSliceLeaky(T, a, "{\"\\u0069d\":3}");
    try testing.expectEqual(@as(u8, 3), v.id);
}

// ------------------------------------------------------------ interop

test "our output parses as std.json, and we parse std.json's output" {
    const a = std.testing.allocator;
    const value: Simple = .{ .id = 1234567890123, .name = "quote\" and \\ and \n", .active = true, .score = 0.1 };

    var mine: [1024]u8 = undefined;
    const ours = try encodeToBuf(value, &mine);

    const via_std = try std.json.parseFromSlice(Simple, a, ours, .{});
    defer via_std.deinit();
    try testing.expectEqualStrings(value.name, via_std.value.name);
    try testing.expectEqual(value.id, via_std.value.id);
    try testing.expectEqual(value.score, via_std.value.score);

    var theirs: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&theirs);
    try std.json.Stringify.value(value, .{}, &w);

    const via_ours = try json.decodeFromSlice(Simple, a, w.buffered());
    defer via_ours.deinit();
    try testing.expectEqualStrings(value.name, via_ours.value.name);
    try testing.expectEqual(value.score, via_ours.value.score);
}

test "encodeAlloc" {
    const a = std.testing.allocator;
    const out = try json.encodeAlloc(a, Simple{ .id = 1, .name = "n", .active = false, .score = 2 });
    defer a.free(out);
    try testing.expectEqualStrings("{\"id\":1,\"name\":\"n\",\"active\":false,\"score\":2}", out);
}

// ------------------------------------------------------------ custom formats

/// The example from the README, kept here so the documentation is tested.
const Point = struct {
    x: f64,
    y: f64,

    pub fn jsonWrite(self: Point, encoder: json.Encoder) !void {
        try encoder.write(&[_]f64{ self.x, self.y });
    }

    pub fn jsonRead(decoder: *json.Decoder) !Point {
        const pair = try decoder.value([2]f64);
        return .{ .x = pair[0], .y = pair[1] };
    }
};

test "custom jsonWrite and jsonRead" {
    const a = std.testing.allocator;
    try expectEncodes(Point{ .x = 1.5, .y = -2.5 }, "[1.5,-2.5]");

    const p = try json.decodeFromSliceLeaky(Point, a, "[1.5,-2.5]");
    try testing.expectEqual(@as(f64, 1.5), p.x);
    try testing.expectEqual(@as(f64, -2.5), p.y);

    // Also as a nested field, so the hook is reached through a struct.
    const Wrapper = struct { at: Point, label: []const u8 };
    try expectEncodes(
        Wrapper{ .at = .{ .x = 0, .y = 3 }, .label = "z" },
        "{\"at\":[0,3],\"label\":\"z\"}",
    );
    const w = try json.decodeFromSliceLeaky(Wrapper, a, "{\"at\":[0,3],\"label\":\"z\"}");
    defer a.free(w.label);
    try testing.expectEqual(@as(f64, 3), w.at.y);
}
