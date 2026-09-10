//! Static JSON encoding and decoding for Zig, driven by your types.
//!
//! Like msgpack.zig, everything is comptime-specialized into the destination
//! type: there is no `Value`, no tokenizer, and no runtime schema. Encoding
//! writes to a `std.Io.Writer` and decoding reads from a `std.Io.Reader`, so
//! both work against sockets and files, not just complete buffers.

const std = @import("std");

const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");

pub const EncodeOptions = encode_mod.EncodeOptions;
pub const EncodeError = encode_mod.EncodeError;
pub const Encoder = encode_mod.Encoder;

pub const DecodeError = decode_mod.DecodeError;
pub const Decoder = decode_mod.Decoder;

pub const StructOptions = struct {
    /// How struct fields map to object keys.
    key: Key = .field_name,
    /// Step over object members whose key matches no field instead of failing
    /// with `error.UnknownField`. Lets a consumer read documents from a newer
    /// producer that added fields.
    skip_unknown_fields: bool = false,
    /// Leave optional fields that are null out of the object entirely, rather
    /// than emitting `"field":null`.
    omit_null_fields: bool = true,

    pub const Key = union(enum) {
        /// Use the Zig field name verbatim.
        field_name,
        /// Use the name returned by the type's `jsonFieldName` function.
        custom,
    };
};

/// Structs are encoded as objects keyed by field name unless the type says
/// otherwise by declaring `pub fn jsonFormat() json.StructOptions`.
pub const default_struct_options: StructOptions = .{};

pub fn structOptions(comptime T: type) StructOptions {
    return if (std.meta.hasFn(T, "jsonFormat")) T.jsonFormat() else default_struct_options;
}

/// How a tagged union maps onto an object. A union picks one by declaring
/// `pub fn jsonFormat() json.UnionFormat`.
pub const UnionFormat = union(enum) {
    /// `{"circle":2.5}` — a one-member object keyed by the variant name.
    /// Works with any payload type, and is the default.
    as_object: AsObject,
    /// `{"type":"circle","radius":2.5}` — the variant's own fields hoisted to
    /// the top level next to a tag field. The payload must be a struct or
    /// `void`, since there is nothing to hoist otherwise.
    ///
    /// The tag must be the object's *first* member. Anything else would mean
    /// buffering the whole object before knowing which variant to build, which
    /// a streaming decoder cannot do.
    as_tagged: AsTagged,

    pub const AsObject = struct {};

    pub const AsTagged = struct {
        /// Key holding the variant name.
        tag_field: []const u8 = "type",
        /// Step over members that match neither the tag nor a field of the
        /// selected variant. See `StructOptions.skip_unknown_fields`.
        skip_unknown_fields: bool = false,
    };
};

pub const default_union_format: UnionFormat = .{ .as_object = .{} };

pub fn unionFormat(comptime T: type) UnionFormat {
    return if (std.meta.hasFn(T, "jsonFormat")) T.jsonFormat() else default_union_format;
}

// ---------------------------------------------------------------- encoding

/// Writes `value` as JSON. No whitespace is emitted.
pub fn encode(value: anytype, writer: *std.Io.Writer) EncodeError!void {
    return encode_mod.encodeValue(@TypeOf(value), value, writer, .{});
}

pub fn encodeWithOptions(
    value: anytype,
    writer: *std.Io.Writer,
    options: EncodeOptions,
) EncodeError!void {
    return encode_mod.encodeValue(@TypeOf(value), value, writer, options);
}

/// Encodes into an allocated slice owned by the caller.
pub fn encodeAlloc(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    errdefer buffer.deinit();
    try encode(value, &buffer.writer);
    return buffer.toOwnedSlice();
}

// ---------------------------------------------------------------- decoding

/// A decoded value together with the arena holding everything it points at.
pub fn Decoded(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

pub fn decode(
    comptime T: type,
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
) (DecodeError || std.mem.Allocator.Error)!Decoded(T) {
    var parsed: Decoded(T) = .{
        .arena = try gpa.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer gpa.destroy(parsed.arena);
    parsed.arena.* = .init(gpa);
    errdefer parsed.arena.deinit();

    parsed.value = try decodeLeaky(T, parsed.arena.allocator(), reader);
    return parsed;
}

/// Allocates directly from `gpa` with no arena of its own. Use it when you are
/// already decoding into memory you release in one go - a per-request arena, or
/// a fixed buffer.
///
/// On failure, allocations already made are *not* released: pass an allocator
/// you can throw away wholesale, or use `decode`, which owns an arena and frees
/// it on error.
pub fn decodeLeaky(
    comptime T: type,
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
) DecodeError!T {
    var decoder: Decoder = .{ .reader = reader, .gpa = gpa };
    const value = try decoder.value(T);
    try decoder.endOfDocument();
    return value;
}

/// Checks that `reader` holds exactly one well-formed JSON document, without
/// building anything from it. Useful on its own, and it is what lets the
/// grammar be tested independently of any particular destination type.
pub fn validate(reader: *std.Io.Reader) DecodeError!void {
    var decoder: Decoder = .{ .reader = reader, .gpa = failing_allocator };
    try decoder.skipValue();
    try decoder.endOfDocument();
}

pub fn validateFromSlice(bytes: []const u8) DecodeError!void {
    var reader: std.Io.Reader = .fixed(bytes);
    return validate(&reader);
}

/// Validation never keeps anything, so it never needs to allocate. Handing it
/// an allocator that always fails proves that, rather than asserting it.
const failing_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = struct {
            fn f(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
                return null;
            }
        }.f,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    },
};

pub fn decodeFromSlice(
    comptime T: type,
    gpa: std.mem.Allocator,
    bytes: []const u8,
) (DecodeError || std.mem.Allocator.Error)!Decoded(T) {
    var reader: std.Io.Reader = .fixed(bytes);
    return decode(T, gpa, &reader);
}

pub fn decodeFromSliceLeaky(
    comptime T: type,
    gpa: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!T {
    var reader: std.Io.Reader = .fixed(bytes);
    return decodeLeaky(T, gpa, &reader);
}

test {
    _ = encode_mod;
    _ = decode_mod;
    _ = @import("test.zig");
}
