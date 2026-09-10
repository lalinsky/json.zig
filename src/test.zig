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

// ------------------------------------------------------------ review fixes

test "skipped values must be well formed" {
    const T = struct {
        keep: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .skip_unknown_fields = true };
        }
    };
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Counting brackets alone would accept all of these.
    const bad = [_][]const u8{
        "{\"bad\":{\"x\":[}],\"keep\":1}",
        "{\"bad\":[},\"keep\":1}",
        "{\"bad\":{]},\"keep\":1}",
        "{\"bad\":[1,,2],\"keep\":1}",
        "{\"bad\":{\"a\" 1},\"keep\":1}",
        "{\"bad\":{1:2},\"keep\":1}",
        "{\"bad\":[1 2],\"keep\":1}",
        "{\"bad\":{\"a\":},\"keep\":1}",
    };
    for (bad) |doc| {
        try testing.expectError(error.UnexpectedToken, json.decodeFromSliceLeaky(T, alloc, doc));
    }

    // Well-formed skips still work, including nesting and escapes.
    const good = try json.decodeFromSliceLeaky(
        T,
        alloc,
        "{\"bad\":{\"x\":[1,{\"y\":[\"a\\\"b\",null,true]}]},\"keep\":7}",
    );
    try testing.expectEqual(@as(u8, 7), good.keep);
}

test "unescaped control characters are rejected" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(error.UnescapedControlCharacter, json.decodeFromSliceLeaky([]const u8, alloc, "\"a\nb\""));
    try testing.expectError(error.UnescapedControlCharacter, json.decodeFromSliceLeaky([]const u8, alloc, "\"a\x00b\""));
    try testing.expectError(error.UnescapedControlCharacter, json.decodeFromSliceLeaky([]const u8, alloc, "\"a\tb\""));
    try testing.expectError(error.UnescapedControlCharacter, json.decodeFromSliceLeaky([]const u8, alloc, "\"a\x1fb\""));
    // 0x7f is not a C0 control character and stays legal.
    const del = try json.decodeFromSliceLeaky([]const u8, alloc, "\"a\x7fb\"");
    try testing.expectEqualStrings("a\x7fb", del);

    // Also in keys, and past the 16-byte scan block.
    const T = struct { @"0123456789abcdefghij": u8 };
    try testing.expectError(error.UnescapedControlCharacter, json.decodeFromSliceLeaky(T, alloc, "{\"0123456789abcdefghij\nx\":1}"));
    // And inside a value being skipped.
    const S = struct {
        keep: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .skip_unknown_fields = true };
        }
    };
    try testing.expectError(error.UnescapedControlCharacter, json.decodeFromSliceLeaky(S, alloc, "{\"bad\":\"a\nb\",\"keep\":1}"));
}

test "floats encode at their own precision" {
    // f32 renders as an f32, not as the f64 it widens to.
    try expectEncodes(@as(f32, 0.1), "0.1");
    try expectEncodes(@as(f64, 0.1), "0.1");
    try expectEncodes(@as(f16, 1.5), "1.5");

    // Finite values outside f64's range must survive rather than become null
    // or the literal text "(float)".
    var buf: [512]u8 = undefined;
    const wide = try encodeToBuf(@as(f128, 1e400), &buf);
    try testing.expect(wide[0] == '1');
    try testing.expect(std.mem.indexOf(u8, wide, "float") == null);
    try testing.expectEqual(@as(f128, 1e400), try std.fmt.parseFloat(f128, wide));

    const wide80 = try encodeToBuf(@as(f80, 1e400), &buf);
    try testing.expectEqual(@as(f80, 1e400), try std.fmt.parseFloat(f80, wide80));
}

test "names baked into the output are escaped" {
    const Quoted = struct {
        a: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .key = .custom };
        }
        pub fn jsonFieldName(comptime f: std.meta.FieldEnum(@This())) []const u8 {
            return switch (f) {
                .a => "a\"b\\c\nd",
            };
        }
    };
    try expectEncodes(Quoted{ .a = 1 }, "{\"a\\\"b\\\\c\\nd\":1}");

    // A Zig field name can contain anything via @"...".
    const Weird = struct { @"x\"y": u8 };
    try expectEncodes(Weird{ .@"x\"y" = 2 }, "{\"x\\\"y\":2}");

    const a = std.testing.allocator;
    const back = try json.decodeFromSliceLeaky(Weird, a, "{\"x\\\"y\":2}");
    try testing.expectEqual(@as(u8, 2), back.@"x\"y");

    // Union tags too.
    const U = union(enum) { @"t\"g": u8 };
    try expectEncodes(U{ .@"t\"g" = 3 }, "{\"t\\\"g\":3}");
}

test "encode options reach custom serializers" {
    const T = struct {
        v: f64,
        pub fn jsonWrite(self: @This(), encoder: json.Encoder) !void {
            try encoder.write(self.v);
        }
    };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.NonFiniteFloat,
        json.encodeWithOptions(T{ .v = std.math.nan(f64) }, &w, .{ .non_finite = .fail }),
    );

    var w2: std.Io.Writer = .fixed(&buf);
    try json.encodeWithOptions(T{ .v = std.math.nan(f64) }, &w2, .{ .non_finite = .null_value });
    try testing.expectEqualStrings("null", w2.buffered());
}

test "validate accepts well-formed documents and allocates nothing" {
    const good = [_][]const u8{
        "null",                  "true",
        "0",                     "-1.5e3",
        "\"\"",                  "\"a\\u00e9\\ud83d\\ude00\"",
        "[]",                    "{}",
        "[1,2,3]",               "{\"a\":{\"b\":[1,{\"c\":null}]}}",
        " \t\r\n [ 1 , 2 ] \n ", "[[[[[[1]]]]]]",
    };
    for (good) |doc| try json.validateFromSlice(doc);
}

test "validate rejects malformed documents" {
    const bad = [_][]const u8{
        "",         "[",          "]",          "{",
        "{}}",      "[1,]",       "{\"a\":1,}", "{\"a\"}",
        "{a:1}",    "[}]",        "{\"x\":[}]", "tru",
        "[1 2]",    "\"unclosed", "\"a\nb\"",   "1 2",
        "{\"a\":}", "[,1]",       "nul",        "--1",
    };
    for (bad) |doc| {
        if (json.validateFromSlice(doc)) {
            std.debug.print("validate wrongly accepted: {s}\n", .{doc});
            return error.AcceptedInvalidDocument;
        } else |_| {}
    }
}

// ---------------------------------------------------------- utf-8 validation

const invalid_utf8 = [_][]const u8{
    "\"a\xc3\x28b\"", // bad continuation byte
    "\"\x80\"", // lone continuation byte
    "\"\xc0\xaf\"", // overlong two-byte form
    "\"\xe0\x80\xaf\"", // overlong three-byte form
    "\"\xed\xa0\x80\"", // surrogate encoded as UTF-8
    "\"\xf4\x90\x80\x80\"", // beyond U+10FFFF
    "\"\xf8\x88\x80\x80\x80\"", // five-byte form
    "\"caf\xc3\"", // truncated at the closing quote
    "\"\xe2\x82\"", // truncated three-byte sequence
};

const valid_utf8 = [_][]const u8{
    "\"\"",
    "\"plain ascii\"",
    "\"caf\xc3\xa9\"",
    "\"\xe2\x82\xac\"", // euro sign
    "\"\xf0\x9f\x98\x80\"", // emoji, four bytes
    "\"\x7f\"", // DEL is not a control character in JSON
    "\"mixed \xc3\xa9 and \xf0\x9f\x98\x80 and ascii tail\"",
    "\"\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80\"",
};

test "invalid utf-8 in strings is rejected" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for (invalid_utf8) |doc| {
        try testing.expectError(error.InvalidUtf8, json.decodeFromSliceLeaky([]const u8, arena.allocator(), doc));
        try testing.expectError(error.InvalidUtf8, json.validateFromSlice(doc));
    }
}

test "valid utf-8 is accepted" {
    const a = std.testing.allocator;
    for (valid_utf8) |doc| {
        try json.validateFromSlice(doc);
        const s = try json.decodeFromSliceLeaky([]const u8, a, doc);
        a.free(s);
    }
}

test "utf-8 validation across reader fills" {
    const a = std.testing.allocator;
    // One byte per fill means every multi-byte sequence straddles a fill.
    // Holding back a partial sequence rather than validating it is what keeps
    // these from being wrongly rejected.
    for (valid_utf8) |doc| {
        for ([_]usize{ 8, 9, 16 }) |buffer_len| {
            var buffer: [16]u8 = undefined;
            var trickle = TrickleReader.init(buffer[0..buffer_len], doc);
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            const s = try json.decodeLeaky([]const u8, arena.allocator(), &trickle.reader);
            try testing.expectEqualStrings(doc[1 .. doc.len - 1], s);
        }
    }
    // And invalid input stays invalid however it is chopped up.
    for (invalid_utf8) |doc| {
        var buffer: [8]u8 = undefined;
        var trickle = TrickleReader.init(&buffer, doc);
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expectError(
            error.InvalidUtf8,
            json.decodeLeaky([]const u8, arena.allocator(), &trickle.reader),
        );
    }
}

test "utf-8 is validated in keys and in skipped values" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Skipping = struct {
        keep: u8,
        pub fn jsonFormat() json.StructOptions {
            return .{ .skip_unknown_fields = true };
        }
    };
    try testing.expectError(error.InvalidUtf8, json.decodeFromSliceLeaky(Skipping, alloc, "{\"a\xc3\x28\":1,\"keep\":2}"));
    try testing.expectError(error.InvalidUtf8, json.decodeFromSliceLeaky(Skipping, alloc, "{\"other\":\"\xc0\xaf\",\"keep\":2}"));

    // A valid non-ASCII key still matches its field.
    const Accented = struct { @"caf\u{e9}": u8 };
    const v = try json.decodeFromSliceLeaky(Accented, alloc, "{\"caf\xc3\xa9\":7}");
    try testing.expectEqual(@as(u8, 7), v.@"caf\u{e9}");
}

// -------------------------------------------------- manual encoder building

/// A type that builds its JSON by hand rather than mirroring its fields,
/// exercising the `Encoder` helpers a custom `jsonWrite` has to use.
const Matrix = struct {
    rows: usize,
    cols: usize,
    data: []const f64,

    pub fn jsonWrite(self: Matrix, encoder: json.Encoder) !void {
        try encoder.beginObject();
        try encoder.writeKey("shape");
        try encoder.beginArray();
        try encoder.write(self.rows);
        try encoder.comma();
        try encoder.write(self.cols);
        try encoder.endArray();
        try encoder.comma();
        try encoder.writeKey("data");
        try encoder.write(self.data);
        try encoder.comma();
        try encoder.writeKey("note");
        try encoder.writeStringValue("needs \"escaping\"");
        try encoder.endObject();
    }

    pub fn jsonRead(decoder: *json.Decoder) !Matrix {
        const Raw = struct { shape: [2]usize, data: []const f64, note: []const u8 };
        const raw = try decoder.value(Raw);
        return .{ .rows = raw.shape[0], .cols = raw.shape[1], .data = raw.data };
    }
};

test "Encoder helpers build valid JSON" {
    const m: Matrix = .{ .rows = 2, .cols = 3, .data = &.{ 1, 2.5, 3, 4, 5, 6 } };
    try expectEncodes(
        m,
        "{\"shape\":[2,3],\"data\":[1,2.5,3,4,5,6],\"note\":\"needs \\\"escaping\\\"\"}",
    );

    // The hand-built output must be readable by std.json and by us.
    const a = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const encoded = try encodeToBuf(m, &buf);
    try json.validateFromSlice(encoded);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const back = try json.decodeFromSliceLeaky(Matrix, arena.allocator(), encoded);
    try testing.expectEqual(@as(usize, 2), back.rows);
    try testing.expectEqual(@as(usize, 3), back.cols);
    try testing.expectEqual(@as(f64, 2.5), back.data[1]);

    const via_std = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer via_std.deinit();
    try testing.expect(via_std.value == .object);
}

test "Encoder helpers carry options" {
    const T = struct {
        v: f64,
        pub fn jsonWrite(self: @This(), encoder: json.Encoder) !void {
            try encoder.beginArray();
            try encoder.write(self.v);
            try encoder.endArray();
        }
    };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.NonFiniteFloat,
        json.encodeWithOptions(T{ .v = std.math.inf(f64) }, &w, .{ .non_finite = .fail }),
    );
}

// ------------------------------------------------------------ union formats

const Circle = struct { radius: f64 };
const Rect = struct { w: u32, h: u32, label: ?[]const u8 = null };

/// Default: a one-member object keyed by the variant name.
const ShapeObject = union(enum) {
    circle: Circle,
    rect: Rect,
    scalar: f64,
    nothing: void,
};

/// Flattened: the variant's fields hoisted next to a tag field.
const ShapeTagged = union(enum) {
    circle: Circle,
    rect: Rect,
    nothing: void,

    pub fn jsonFormat() json.UnionFormat {
        return .{ .as_tagged = .{} };
    }
};

/// Same, with the tag field renamed and unknown members tolerated.
const Event = union(enum) {
    click: struct { x: i32, y: i32 },
    key: struct { code: u8 },

    pub fn jsonFormat() json.UnionFormat {
        return .{ .as_tagged = .{ .tag_field = "kind", .skip_unknown_fields = true } };
    }
};

test "unions as a one-member object" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectEncodes(ShapeObject{ .circle = .{ .radius = 2.5 } }, "{\"circle\":{\"radius\":2.5}}");
    try expectEncodes(ShapeObject{ .scalar = 1.5 }, "{\"scalar\":1.5}");
    try expectEncodes(ShapeObject{ .nothing = {} }, "{\"nothing\":null}");

    const c = try json.decodeFromSliceLeaky(ShapeObject, alloc, "{\"circle\":{\"radius\":2.5}}");
    try testing.expectEqual(@as(f64, 2.5), c.circle.radius);
    const n = try json.decodeFromSliceLeaky(ShapeObject, alloc, "{\"nothing\":null}");
    try testing.expectEqual(ShapeObject.nothing, n);

    try testing.expectError(error.UnknownUnionVariant, json.decodeFromSliceLeaky(ShapeObject, alloc, "{\"nope\":1}"));
}

test "unions as a flattened tagged object" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectEncodes(ShapeTagged{ .circle = .{ .radius = 2.5 } }, "{\"type\":\"circle\",\"radius\":2.5}");
    try expectEncodes(
        ShapeTagged{ .rect = .{ .w = 3, .h = 4, .label = "box" } },
        "{\"type\":\"rect\",\"w\":3,\"h\":4,\"label\":\"box\"}",
    );
    // A null optional in the payload is still omitted.
    try expectEncodes(ShapeTagged{ .rect = .{ .w = 3, .h = 4 } }, "{\"type\":\"rect\",\"w\":3,\"h\":4}");
    // A void variant has nothing to hoist.
    try expectEncodes(ShapeTagged{ .nothing = {} }, "{\"type\":\"nothing\"}");

    const r = try json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"type\":\"rect\",\"w\":3,\"h\":4,\"label\":\"box\"}");
    try testing.expectEqual(@as(u32, 3), r.rect.w);
    try testing.expectEqualStrings("box", r.rect.label.?);

    // Payload field left out, filled from its default.
    const r2 = try json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"type\":\"rect\",\"w\":1,\"h\":2}");
    try testing.expectEqual(@as(?[]const u8, null), r2.rect.label);

    const n = try json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"type\":\"nothing\"}");
    try testing.expectEqual(ShapeTagged.nothing, n);

    // Round trip through both directions.
    for ([_]ShapeTagged{
        .{ .circle = .{ .radius = 0.5 } },
        .{ .rect = .{ .w = 7, .h = 8, .label = "l" } },
        .{ .nothing = {} },
    }) |v| {
        var buf: [128]u8 = undefined;
        const encoded = try encodeToBuf(v, &buf);
        try json.validateFromSlice(encoded);
        const back = try json.decodeFromSliceLeaky(ShapeTagged, alloc, encoded);
        try testing.expectEqual(std.meta.activeTag(v), std.meta.activeTag(back));
    }
}

test "as_tagged rejects a missing or misplaced tag" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The tag has to be the first member; a streaming decoder cannot go back.
    try testing.expectError(error.MissingUnionTag, json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"radius\":2.5,\"type\":\"circle\"}"));
    try testing.expectError(error.MissingUnionTag, json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"w\":1}"));
    try testing.expectError(error.UnknownUnionVariant, json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"type\":\"hexagon\"}"));
    // A void variant carrying fields is not that variant.
    try testing.expectError(error.UnknownField, json.decodeFromSliceLeaky(ShapeTagged, alloc, "{\"type\":\"nothing\",\"x\":1}"));
}

test "as_tagged with a renamed tag field and unknown members" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectEncodes(Event{ .click = .{ .x = 1, .y = 2 } }, "{\"kind\":\"click\",\"x\":1,\"y\":2}");

    const e = try json.decodeFromSliceLeaky(Event, alloc, "{\"kind\":\"click\",\"x\":1,\"extra\":{\"a\":[1,2]},\"y\":2}");
    try testing.expectEqual(@as(i32, 1), e.click.x);
    try testing.expectEqual(@as(i32, 2), e.click.y);

    // Nested inside a struct, and inside a slice.
    const Wrapper = struct { events: []const Event };
    const w = try json.decodeFromSliceLeaky(Wrapper, alloc, "{\"events\":[{\"kind\":\"click\",\"x\":1,\"y\":2},{\"kind\":\"key\",\"code\":65}]}");
    try testing.expectEqual(@as(usize, 2), w.events.len);
    try testing.expectEqual(@as(u8, 65), w.events[1].key.code);
}

test "as_tagged through a trickling reader" {
    const a = std.testing.allocator;
    const doc = "{\"type\":\"rect\",\"w\":30000,\"h\":40000,\"label\":\"a longer label \\u00e9\"}";
    for ([_]usize{ 8, 16, 64 }) |buffer_len| {
        var buffer: [64]u8 = undefined;
        var trickle = TrickleReader.init(buffer[0..buffer_len], doc);
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const v = try json.decodeLeaky(ShapeTagged, arena.allocator(), &trickle.reader);
        try testing.expectEqual(@as(u32, 30000), v.rect.w);
        try testing.expectEqualStrings("a longer label \u{e9}", v.rect.label.?);
    }
}
