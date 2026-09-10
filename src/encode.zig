//! JSON encoding, specialized at comptime into the type being written.
//!
//! A struct's separator, key, quotes and colon collapse into a single comptime
//! string literal, so writing a field is one `writeAll` of a known constant
//! plus the value - there is no runtime state machine deciding whether a comma
//! is due.

const std = @import("std");
const Writer = std.Io.Writer;
const json = @import("json.zig");

pub const EncodeError = Writer.Error || error{NonFiniteFloat};

pub const EncodeOptions = struct {
    /// JSON cannot represent NaN or +/-Infinity. `JSON.stringify` in
    /// JavaScript emits `null` for them, which is the default here.
    non_finite: enum { null_value, fail } = .null_value,
};

/// Thin wrapper handed to a type's custom `jsonWrite` function. It carries the
/// options the encode was started with, so a custom serializer that calls back
/// into `write` honours them rather than silently reverting to the defaults.
pub const Encoder = struct {
    writer: *Writer,
    options: EncodeOptions = .{},

    pub fn write(self: Encoder, value: anytype) EncodeError!void {
        return encodeValue(@TypeOf(value), value, self.writer, self.options);
    }

    pub fn beginObject(self: Encoder) Writer.Error!void {
        return self.writer.writeByte('{');
    }

    pub fn endObject(self: Encoder) Writer.Error!void {
        return self.writer.writeByte('}');
    }

    pub fn beginArray(self: Encoder) Writer.Error!void {
        return self.writer.writeByte('[');
    }

    pub fn endArray(self: Encoder) Writer.Error!void {
        return self.writer.writeByte(']');
    }

    pub fn comma(self: Encoder) Writer.Error!void {
        return self.writer.writeByte(',');
    }

    pub fn writeKey(self: Encoder, key: []const u8) Writer.Error!void {
        try writeString(key, self.writer);
        try self.writer.writeByte(':');
    }

    pub fn writeStringValue(self: Encoder, s: []const u8) Writer.Error!void {
        return writeString(s, self.writer);
    }
};

pub fn encodeValue(
    comptime T: type,
    value: T,
    w: *Writer,
    opts: EncodeOptions,
) EncodeError!void {
    if (comptime std.meta.hasFn(T, "jsonWrite")) {
        return value.jsonWrite(Encoder{ .writer = w, .options = opts });
    }

    switch (@typeInfo(T)) {
        .void, .null => try w.writeAll("null"),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try writeInt(T, value, w),
        .float, .comptime_float => try writeFloat(T, value, w, opts),
        .optional => {
            if (value) |payload| return encodeValue(@TypeOf(payload), payload, w, opts);
            try w.writeAll("null");
        },
        .@"enum" => try writeString(@tagName(value), w),
        .enum_literal => try writeString(@tagName(value), w),
        .@"union" => try encodeUnion(T, value, w, opts),
        .@"struct" => try encodeStruct(T, value, w, opts),
        .array => |arr| {
            if (arr.child == u8) return writeString(&value, w);
            try encodeSlice(arr.child, &value, w, opts);
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child == u8) return writeString(value, w);
                try encodeSlice(ptr.child, value, w, opts);
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| {
                    if (arr.child == u8) return writeString(value, w);
                    try encodeSlice(arr.child, value, w, opts);
                },
                else => try encodeValue(ptr.child, value.*, w, opts),
            },
            else => @compileError("json: cannot encode " ++ @typeName(T)),
        },
        else => @compileError("json: cannot encode " ++ @typeName(T)),
    }
}

fn encodeSlice(comptime Child: type, items: []const Child, w: *Writer, opts: EncodeOptions) EncodeError!void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeByte(',');
        try encodeValue(Child, item, w, opts);
    }
    try w.writeByte(']');
}

fn encodeUnion(comptime T: type, value: T, w: *Writer, opts: EncodeOptions) EncodeError!void {
    const info = @typeInfo(T).@"union";
    if (info.tag_type == null) @compileError("json: cannot encode untagged union " ++ @typeName(T));

    switch (comptime json.unionFormat(T)) {
        .as_object => {
            try w.writeByte('{');
            switch (value) {
                inline else => |payload, tag| {
                    try w.writeAll(comptime "\"" ++ escapedLiteral(@tagName(tag)) ++ "\":");
                    try encodeValue(@TypeOf(payload), payload, w, opts);
                },
            }
            try w.writeByte('}');
        },
        .as_tagged => |tagged| {
            switch (value) {
                inline else => |payload, tag| {
                    const Payload = @TypeOf(payload);
                    if (Payload != void and @typeInfo(Payload) != .@"struct") {
                        @compileError("json: as_tagged needs a struct or void payload, but " ++
                            @typeName(T) ++ "." ++ @tagName(tag) ++ " is " ++ @typeName(Payload));
                    }
                    try w.writeAll(comptime "{\"" ++ escapedLiteral(tagged.tag_field) ++
                        "\":\"" ++ escapedLiteral(@tagName(tag)) ++ "\"");
                    // The tag is always present, so every hoisted field is
                    // preceded by a comma - no first-member bookkeeping.
                    if (Payload != void) try encodeStructFieldsAfter(Payload, payload, w, opts);
                    try w.writeByte('}');
                },
            }
        },
    }
}

/// Writes a struct's members as `,"name":value`, for an object that already
/// has at least one member.
fn encodeStructFieldsAfter(comptime T: type, value: T, w: *Writer, opts: EncodeOptions) EncodeError!void {
    const options = comptime json.structOptions(T);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const omit = options.omit_null_fields and
            @typeInfo(f.type) == .optional and
            @field(value, f.name) == null;
        if (!omit) {
            try w.writeAll(comptime ",\"" ++ escapedLiteral(fieldKey(T, f.name)) ++ "\":");
            try encodeValue(f.type, @field(value, f.name), w, opts);
        }
    }
}

/// Escapes a comptime-known string for embedding between quotes. Field names
/// and union tags are written as literals rather than through `writeString`,
/// so they have to be escaped here or a name containing a quote, a backslash
/// or a control character produces invalid JSON. Zig allows any bytes in an
/// identifier via `@"..."`, so this applies to plain field names too, not only
/// custom ones.
pub fn escapedLiteral(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| {
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                0x0c => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x00...0x07, 0x0b, 0x0e...0x1f => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
                else => &[_]u8{c},
            };
        }
        return out;
    }
}

fn fieldKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    const options = comptime json.structOptions(T);
    return switch (options.key) {
        .field_name => field_name,
        .custom => T.jsonFieldName(@field(std.meta.FieldEnum(T), field_name)),
    };
}

/// Whether any field can be left out at runtime. When none can, the commas are
/// comptime-known and the whole object header collapses to string literals.
fn canOmitFields(comptime T: type) bool {
    const options = comptime json.structOptions(T);
    if (!options.omit_null_fields) return false;
    for (@typeInfo(T).@"struct".fields) |f| {
        if (@typeInfo(f.type) == .optional) return true;
    }
    return false;
}

fn encodeStruct(comptime T: type, value: T, w: *Writer, opts: EncodeOptions) EncodeError!void {
    const fields = @typeInfo(T).@"struct".fields;
    const options = comptime json.structOptions(T);

    try w.writeByte('{');
    if (comptime !canOmitFields(T)) {
        inline for (fields, 0..) |f, i| {
            const prefix = comptime (if (i == 0) "\"" else ",\"") ++ escapedLiteral(fieldKey(T, f.name)) ++ "\":";
            try w.writeAll(prefix);
            try encodeValue(f.type, @field(value, f.name), w, opts);
        }
    } else {
        var first = true;
        inline for (fields) |f| {
            const omit = options.omit_null_fields and
                @typeInfo(f.type) == .optional and
                @field(value, f.name) == null;
            if (!omit) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll(comptime "\"" ++ escapedLiteral(fieldKey(T, f.name)) ++ "\":");
                try encodeValue(f.type, @field(value, f.name), w, opts);
            }
        }
    }
    try w.writeByte('}');
}

/// Formats at the value's own precision. Widening to f64 first would lose
/// digits for f80/f128, and would turn a finite value that exceeds f64's range
/// into an infinity - reported as `null` or an error for a number that is
/// perfectly representable in its own type.
fn writeFloat(comptime T: type, value: T, w: *Writer, opts: EncodeOptions) EncodeError!void {
    const Float = if (T == comptime_float) f64 else T;
    const v: Float = value;
    if (!std.math.isFinite(v)) {
        switch (opts.non_finite) {
            .null_value => return w.writeAll("null"),
            .fail => return error.NonFiniteFloat,
        }
    }
    // Shortest representation that round-trips, via std's Ryu implementation.
    //
    // This calls the renderer directly rather than going through
    // `w.print("{}")`, which reaches `Writer.printFloat` - and that sizes its
    // scratch buffer for f64 no matter what type it was handed, so a wide
    // f80/f128 value silently renders as the literal text "(float)". Sizing
    // the buffer for the actual type is what makes those types work at all.
    // For f32 and f64 the bytes are identical either way.
    var buf: [std.fmt.float.bufferSize(.decimal, Float)]u8 = undefined;
    const rendered = std.fmt.float.render(&buf, v, .{ .mode = .decimal }) catch |err| switch (err) {
        // `bufferSize` is defined as the capacity this mode and type need.
        error.BufferTooSmall => unreachable,
    };
    try w.writeAll(rendered);
}

const digits2: [200]u8 = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |n| {
        t[n * 2] = '0' + n / 10;
        t[n * 2 + 1] = '0' + n % 10;
    }
    break :blk t;
};

/// Two decimal digits per iteration into a stack buffer, written back to
/// front. Same output as `print("{}")` without the formatting machinery.
fn writeInt(comptime T: type, value: T, w: *Writer) Writer.Error!void {
    const Int = if (T == comptime_int) i64 else T;
    const bits = @typeInfo(Int).int.bits;
    if (bits > 64) return w.print("{}", .{value});

    const v: Int = value;
    const neg = v < 0;
    var x: u64 = if (neg) @intCast(-@as(i128, v)) else @intCast(v);

    var buf: [21]u8 = undefined;
    var i: usize = buf.len;
    while (x >= 100) {
        const r: usize = @intCast(x % 100);
        x /= 100;
        i -= 2;
        buf[i..][0..2].* = digits2[r * 2 ..][0..2].*;
    }
    if (x >= 10) {
        i -= 2;
        buf[i..][0..2].* = digits2[@as(usize, @intCast(x)) * 2 ..][0..2].*;
    } else {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x));
    }
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    try w.writeAll(buf[i..]);
}

/// Escapes `"`, `\` and the C0 control characters; everything else, high bytes
/// included, passes through untouched. Chunks with nothing to escape are
/// emitted as a single run rather than byte by byte.
pub fn writeString(str: []const u8, w: *Writer) Writer.Error!void {
    try w.writeByte('"');

    const V = @Vector(16, u8);
    const quote: V = @splat('"');
    const backslash: V = @splat('\\');
    const space: V = @splat(0x20);

    var cursor: usize = 0;
    var i: usize = 0;
    while (i + 16 <= str.len) {
        const chunk: V = str[i..][0..16].*;
        const hits: u16 = @bitCast((chunk == quote) | (chunk == backslash) | (chunk < space));
        if (hits == 0) {
            i += 16;
            continue;
        }
        const at = i + @ctz(hits);
        try w.writeAll(str[cursor..at]);
        try writeEscape(str[at], w);
        cursor = at + 1;
        i = at + 1;
    }
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (c == '"' or c == '\\' or c < 0x20) {
            try w.writeAll(str[cursor..i]);
            try writeEscape(c, w);
            cursor = i + 1;
        }
    }
    try w.writeAll(str[cursor..]);
    try w.writeByte('"');
}

fn writeEscape(c: u8, w: *Writer) Writer.Error!void {
    switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            try w.writeAll("\\u");
            try w.printInt(c, 16, .lower, .{ .width = 4, .fill = '0' });
        },
    }
}
