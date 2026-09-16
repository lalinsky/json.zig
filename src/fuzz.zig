//! Fuzz targets.
//!
//! Two invariants:
//!
//!   * a successful typed decode implies `validate` accepts the same bytes;
//!   * encoding a value, decoding it and encoding again yields identical bytes.
//!
//! `zig build test --fuzz` does not work on Zig 0.16.0, whose test runner does
//! not compile in fuzz mode. Until that is fixed the corpus below is what
//! runs, on every ordinary `zig build test`.
//!
//! `Smith` reads its input as a length-prefixed encoding rather than as raw
//! bytes, so corpus entries are wrapped by `asSmithSlice`. The same documents
//! are also driven directly, without `Smith`, by the test above the fuzz
//! target.

const std = @import("std");
const json = @import("json.zig");
const Smith = std.testing.Smith;

/// Destination types the fuzzer tries arbitrary input against. Between them
/// they reach the object, array, string, number, bool and null paths.
const shapes = .{
    []const u8,
    i64,
    u64,
    f64,
    bool,
    ?i32,
    []const i64,
    []const f64,
    []const []const u8,
    []const bool,
    struct { a: i64, b: []const u8 },
    struct { n: ?f64 = null, xs: []const i32 = &.{} },
};

/// Documents worth keeping in front of the fuzzer.
const documents: []const []const u8 = &.{
    ".5",                   "[.5]",                   "-.5",               "[1,]",
    "1e",                   "[1e]",                   "12.",               "[12.]",
    "01",                   "[01]",                   "+1",                "-0",
    "99999999999999999999", "[99999999999999999999]", "\"a\\u00e9\"",      "\"\\ud83d\\ude00\"",
    "\"\\ud800\"",          "\"a\tb\"",               "{\"a\":1,\"a\":2}", "{\"a\":1}",
    "[[[[[1]]]]]",          "{}",                     "[]",                "null",
    "true",                 "1e400",                  "\"abcd\"",          "[97,98,99,100]",
    " \n\t[1] \n",          "",
};

/// Wraps a document in the length-prefixed encoding `Smith.slice` expects.
fn asSmithSlice(comptime doc: []const u8) []const u8 {
    const len_le = std.mem.toBytes(std.mem.nativeToLittle(u32, doc.len));
    return len_le ++ doc;
}

const corpus: []const []const u8 = blk: {
    var out: [documents.len][]const u8 = undefined;
    for (documents, 0..) |doc, i| out[i] = asSmithSlice(doc);
    const frozen = out;
    break :blk &frozen;
};

/// Anything the typed decoder accepts has to be a document `validate` accepts.
fn checkDecodeImpliesValidate(input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (shapes) |T| {
        _ = arena.reset(.retain_capacity);
        if (json.decodeFromSliceLeaky(T, arena.allocator(), input, .{})) |_| {
            json.validateFromSlice(input) catch |err| {
                std.debug.print(
                    "decoded as {s} but validate rejected it with {t}\ninput: {s}\n",
                    .{ @typeName(T), err, input },
                );
                return error.DecodedAnInvalidDocument;
            };
        } else |_| {}
    }
}

test "decode implies validate" {
    for (documents) |doc| try checkDecodeImpliesValidate(doc);
}

test "fuzz: a successful decode implies a valid document" {
    try std.testing.fuzz({}, decodeImpliesValidate, .{ .corpus = corpus });
}

fn decodeImpliesValidate(_: void, smith: *Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    try checkDecodeImpliesValidate(buf[0..smith.slice(&buf)]);
}

const Tag = enum { alpha, beta, gamma };

const Payload = struct {
    b: bool,
    i: i64,
    u: u32,
    f: f64,
    s: []const u8,
    opt: ?i16,
    tag: Tag,
    fixed: [4]u8,
    list: []const i32,
};

test "fuzz: encoding and decoding agree" {
    try std.testing.fuzz({}, roundTrip, .{});
}

fn roundTrip(_: void, smith: *Smith) anyerror!void {
    // ASCII only: the encoder passes bytes through unchanged while the decoder
    // validates UTF-8, so arbitrary high bytes would fail the round trip for a
    // reason that is documented rather than a defect. Control characters and
    // quotes are included, since those exercise escaping.
    var sbuf: [128]u8 = undefined;
    const slen = smith.sliceWeightedBytes(&sbuf, &.{.rangeAtMost(u8, 0, 0x7f, 1)});

    var fixed: [4]u8 = undefined;
    for (&fixed) |*c| c.* = smith.value(u7);

    var list_buf: [16]i32 = undefined;
    const list_len = @min(smith.value(u4), list_buf.len);
    for (list_buf[0..list_len]) |*v| v.* = smith.value(i32);

    // JSON has no way to spell a NaN or an infinity, so the encoder writes
    // null for them by design; that is not a round trip.
    var f = smith.value(f64);
    if (!std.math.isFinite(f)) f = 0;

    const value: Payload = .{
        .b = smith.value(bool),
        .i = smith.value(i64),
        .u = smith.value(u32),
        .f = f,
        .s = sbuf[0..slen],
        .opt = if (smith.value(bool)) smith.value(i16) else null,
        .tag = smith.value(Tag),
        .fixed = fixed,
        .list = list_buf[0..list_len],
    };

    var first_buf: [8192]u8 = undefined;
    var w1: std.Io.Writer = .fixed(&first_buf);
    try json.encode(value, &w1);
    const first = w1.buffered();

    // What we emit must be valid JSON by our own reckoning.
    try json.validateFromSlice(first);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const back = json.decodeFromSliceLeaky(Payload, arena.allocator(), first, .{}) catch |err| {
        std.debug.print("could not decode our own output: {t}\n{s}\n", .{ err, first });
        return error.RoundTripFailed;
    };

    var second_buf: [8192]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&second_buf);
    try json.encode(back, &w2);
    try std.testing.expectEqualStrings(first, w2.buffered());
}
