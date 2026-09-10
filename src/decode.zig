//! JSON decoding, specialized at comptime into the destination type.
//!
//! There is no tokenizer and no `Token` values: the function that parses a
//! struct is generated from that struct's fields, and bytes go straight into
//! the result.
//!
//! Reading goes through `std.Io.Reader`, so a document can arrive in pieces.
//! Since JSON has no length prefixes, every scan works over whatever the
//! reader currently has buffered, consumes it, and asks for more - which means
//! a value may be far larger than the reader's buffer.

const std = @import("std");
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const escapedLiteral = @import("encode.zig").escapedLiteral;

pub const DecodeError = error{
    /// A byte appeared where the grammar does not allow it.
    UnexpectedToken,
    /// The document ended in the middle of a value.
    UnexpectedEndOfInput,
    /// Trailing content after the top-level value.
    TrailingData,
    InvalidNumber,
    /// The number is well-formed but does not fit the destination type.
    NumberOutOfRange,
    /// A number longer than `max_number_len` bytes.
    NumberTooLong,
    InvalidEscape,
    /// A byte below 0x20 appeared inside a string without being escaped, which
    /// RFC 8259 forbids.
    UnescapedControlCharacter,
    /// A `\uD800`-`\uDBFF` escape not followed by a low surrogate, or a lone
    /// low surrogate.
    InvalidSurrogatePair,
    /// An object key that matches no field, when the type has not opted into
    /// `skip_unknown_fields`.
    UnknownField,
    /// A field with no default and no optional type was absent.
    MissingField,
    /// Nesting deeper than `max_depth`.
    DepthLimitExceeded,
    /// A string did not name any tag of the destination enum or union.
    InvalidEnumTag,
    ReadFailed,
    OutOfMemory,
};

/// Widest mantissa and decimal exponent for which Clinger's exact path holds:
/// both the mantissa and 10^|exp| must be exactly representable, so the single
/// multiply (or divide) rounds once and is therefore correctly rounded.
/// Types not listed here always take the `std.fmt.parseFloat` path.
const ClingerLimits = struct { max_mantissa: u64, max_exp: i32 };

fn clingerLimits(comptime T: type) ?ClingerLimits {
    return switch (T) {
        f64 => .{ .max_mantissa = 1 << 53, .max_exp = 22 },
        f32 => .{ .max_mantissa = 1 << 24, .max_exp = 10 },
        else => null,
    };
}

const pow10_f64 = [23]f64{
    1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
};
const pow10_f32 = [11]f32{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10 };

/// Parses a float out of `window` in a single pass, collecting the mantissa and
/// decimal exponent as it finds the end of the number.
///
/// Returns null - having consumed nothing - when the number runs to the end of
/// the window, since it may continue in the next fill; the caller then takes
/// the general path, which is what makes this safe to be approximate about.
///
/// When the number is complete but outside the range where one rounding is
/// provably enough - digits dropped, or mantissa/exponent too large - `value`
/// is null and `len` still reports its extent, so the caller can convert it
/// exactly without rescanning.
fn fastFloat(comptime T: type, window: []const u8) ?struct { value: ?T, len: usize, invalid: bool = false } {
    const limits = comptime clingerLimits(T).?;
    const table = comptime switch (T) {
        f64 => &pow10_f64,
        f32 => &pow10_f32,
        else => unreachable,
    };

    var i: usize = 0;
    const neg = window.len > 0 and window[0] == '-';
    if (neg) i = 1;

    var mantissa: u64 = 0;
    var ndigits: u32 = 0;
    var exp10: i32 = 0;
    var truncated = false;

    const int_start = i;
    while (i < window.len) : (i += 1) {
        const digit = window[i] -% '0';
        if (digit > 9) break;
        if (ndigits < 19) {
            mantissa = mantissa * 10 + digit;
            ndigits += 1;
        } else {
            exp10 += 1;
            truncated = true;
        }
    }
    const int_digits = i - int_start;
    var any_digits = int_digits > 0;
    // Leading zeros are not legal JSON, and neither is a leading `+`.
    if ((int_digits > 1 and window[int_start] == '0') or
        (window.len > 0 and window[0] == '+'))
    {
        return .{ .value = null, .len = i, .invalid = true };
    }

    if (i < window.len and window[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < window.len) : (i += 1) {
            const digit = window[i] -% '0';
            if (digit > 9) break;
            if (ndigits < 19) {
                mantissa = mantissa * 10 + digit;
                ndigits += 1;
                exp10 -= 1;
            } else truncated = true;
        }
        // A fraction must have at least one digit.
        if (i == frac_start) return .{ .value = null, .len = i, .invalid = true };
        any_digits = true;
    }
    if (!any_digits) return null;

    if (i < window.len and (window[i] == 'e' or window[i] == 'E')) {
        i += 1;
        var exp_neg = false;
        if (i < window.len and (window[i] == '-' or window[i] == '+')) {
            exp_neg = window[i] == '-';
            i += 1;
        }
        const exp_start = i;
        var e: i32 = 0;
        while (i < window.len) : (i += 1) {
            const digit = window[i] -% '0';
            if (digit > 9) break;
            if (e < 100_000) e = e * 10 + digit;
        }
        if (i == exp_start) return .{ .value = null, .len = i, .invalid = true };
        exp10 += if (exp_neg) -e else e;
    }

    // Reaching the end of the window means the number might not be over.
    if (i >= window.len) return null;

    if (truncated or
        mantissa > limits.max_mantissa or
        exp10 < -limits.max_exp or
        exp10 > limits.max_exp)
    {
        return .{ .value = null, .len = i };
    }

    const m: T = @floatFromInt(mantissa);
    const value = if (exp10 >= 0)
        m * table[@intCast(exp10)]
    else
        m / table[@intCast(-exp10)];
    return .{ .value = if (neg) -value else value, .len = i };
}

/// Checks `text` against RFC 8259's number grammar:
///
///     number = [ "-" ] int [ frac ] [ exp ]
///     int    = "0" / ( digit1-9 *DIGIT )
///     frac   = "." 1*DIGIT
///     exp    = ("e" / "E") [ "-" / "+" ] 1*DIGIT
///
/// `std.fmt.parseFloat` is more permissive than this - it takes a leading `+`,
/// a bare leading `.`, leading zeros - so the grammar has to be checked
/// separately rather than inferred from a successful parse.
fn validNumber(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;

    // int: a single zero, or a nonzero digit followed by any digits.
    if (i >= text.len) return false;
    if (text[i] == '0') {
        i += 1;
    } else if (text[i] >= '1' and text[i] <= '9') {
        while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    } else return false;

    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
        if (i == start) return false;
    }

    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
        const start = i;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
        if (i == start) return false;
    }

    return i == text.len;
}

/// JSON numbers are unbounded in the grammar; this is the longest run of
/// number bytes accepted, which is far past any value a f64 or i128 can hold.
pub const max_number_len = 512;

/// Guards against stack exhaustion from deeply nested input. Only reached by
/// recursive types, since nesting depth is otherwise bounded by the Zig type.
pub const max_depth = 256;

pub const Decoder = struct {
    reader: *Reader,
    gpa: Allocator,
    depth: u16 = 0,

    // ------------------------------------------------------------ scanning

    /// Errors from the reader, mapped onto our set. `EndOfStream` in the
    /// middle of a value is malformed input, not a read failure.
    inline fn mapRead(err: Reader.Error) DecodeError {
        return switch (err) {
            error.EndOfStream => error.UnexpectedEndOfInput,
            error.ReadFailed => error.ReadFailed,
        };
    }

    /// Consumes whitespace. Hitting end of input is not an error here; the
    /// caller decides whether a value was required.
    fn skipWhitespace(d: *Decoder) DecodeError!void {
        while (true) {
            const window = d.reader.buffered();
            var i: usize = 0;
            while (i < window.len) : (i += 1) {
                switch (window[i]) {
                    ' ', '\t', '\n', '\r' => {},
                    else => {
                        d.reader.toss(i);
                        return;
                    },
                }
            }
            d.reader.toss(i);
            d.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }

    inline fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    /// One load and a compare when the next byte is already buffered and is
    /// not whitespace, which is every token boundary in minified JSON.
    /// Whitespace and refills go to `peekByteSlow`, which stays a real call so
    /// the inlined fast path remains small.
    inline fn peekByte(d: *Decoder) DecodeError!u8 {
        const r = d.reader;
        if (r.seek < r.end) {
            @branchHint(.likely);
            const c = r.buffer[r.seek];
            if (!isWhitespace(c)) return c;
        }
        return d.peekByteSlow();
    }

    fn peekByteSlow(d: *Decoder) DecodeError!u8 {
        try d.skipWhitespace();
        return d.reader.peekByte() catch |err| return mapRead(err);
    }

    /// Consumes `n` bytes known to be buffered.
    inline fn advance(d: *Decoder, n: usize) void {
        d.reader.seek += n;
    }

    inline fn expectByte(d: *Decoder, comptime c: u8) DecodeError!void {
        const r = d.reader;
        if (r.seek < r.end and r.buffer[r.seek] == c) {
            @branchHint(.likely);
            r.seek += 1;
            return;
        }
        return d.expectByteSlow(c);
    }

    fn expectByteSlow(d: *Decoder, comptime c: u8) DecodeError!void {
        if (try d.peekByteSlow() != c) return error.UnexpectedToken;
        d.reader.seek += 1;
    }

    /// Consumes a bare literal such as `true` or `null`. Assumes leading
    /// whitespace has already been skipped by a `peekByte`.
    inline fn expectLiteral(d: *Decoder, comptime lit: []const u8) DecodeError!bool {
        const r = d.reader;
        if (r.end - r.seek >= lit.len) {
            @branchHint(.likely);
            if (!std.mem.eql(u8, r.buffer[r.seek..][0..lit.len], lit)) return false;
            r.seek += lit.len;
            return true;
        }
        return d.expectLiteralSlow(lit);
    }

    /// Matches a comptime-known token against the buffer, consuming it on
    /// success and leaving the position untouched on failure. Both lengths are
    /// comptime-known, so the compare lowers to one or two word compares
    /// rather than a scan.
    inline fn tryToken(d: *Decoder, comptime lit: []const u8) bool {
        const r = d.reader;
        if (r.end - r.seek >= lit.len) {
            @branchHint(.likely);
            if (std.mem.eql(u8, r.buffer[r.seek..][0..lit.len], lit)) {
                r.seek += lit.len;
                return true;
            }
        }
        return false;
    }

    fn expectLiteralSlow(d: *Decoder, comptime lit: []const u8) DecodeError!bool {
        const window = d.reader.peek(lit.len) catch |err| switch (err) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!std.mem.eql(u8, window[0..lit.len], lit)) return false;
        d.reader.toss(lit.len);
        return true;
    }

    pub fn endOfDocument(d: *Decoder) DecodeError!void {
        try d.skipWhitespace();
        if (d.reader.bufferedLen() != 0) return error.TrailingData;
        d.reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        if (d.reader.bufferedLen() != 0) return error.TrailingData;
    }

    // ------------------------------------------------------------- values

    pub fn value(d: *Decoder, comptime T: type) DecodeError!T {
        if (comptime std.meta.hasFn(T, "jsonRead")) {
            return T.jsonRead(d);
        }

        switch (@typeInfo(T)) {
            .void => {
                _ = try d.peekByte();
                if (!try d.expectLiteral("null")) return error.UnexpectedToken;
                return {};
            },
            .bool => return d.boolean(),
            .int => return d.int(T),
            .float => return d.float(T),
            .optional => |o| {
                if (try d.peekByte() == 'n') {
                    if (!try d.expectLiteral("null")) return error.UnexpectedToken;
                    return null;
                }
                return try d.value(o.child);
            },
            .@"enum" => return d.enumValue(T),
            .@"union" => return d.unionValue(T),
            .@"struct" => return d.object(T),
            .array => |arr| return d.fixedArray(T, arr.child, arr.len),
            .pointer => |ptr| {
                if (ptr.size != .slice) @compileError("json: cannot decode " ++ @typeName(T));
                if (ptr.child == u8) return d.string();
                return d.slice(T, ptr.child);
            },
            else => @compileError("json: cannot decode " ++ @typeName(T)),
        }
    }

    fn boolean(d: *Decoder) DecodeError!bool {
        switch (try d.peekByte()) {
            't' => {
                if (!try d.expectLiteral("true")) return error.UnexpectedToken;
                return true;
            },
            'f' => {
                if (!try d.expectLiteral("false")) return error.UnexpectedToken;
                return false;
            },
            else => return error.UnexpectedToken,
        }
    }

    /// Returns the number's bytes as one contiguous span.
    ///
    /// The common case borrows straight out of the reader's buffer; `buf` is
    /// only used when the number straddles a fill. The returned slice stays
    /// valid until the next read, which is enough because every caller parses
    /// it immediately and reads nothing in between.
    fn numberSpan(d: *Decoder, buf: []u8) DecodeError![]const u8 {
        _ = try d.peekByte();

        const r = d.reader;
        const window = r.buffer[r.seek..r.end];
        if (numberEnd(window)) |end| {
            @branchHint(.likely);
            if (end == 0) return error.InvalidNumber;
            r.seek += end;
            return window[0..end];
        }

        var len: usize = 0;
        while (true) {
            const chunk = d.reader.buffered();
            const scanned = numberEnd(chunk) orelse chunk.len;
            if (len + scanned > buf.len) return error.NumberTooLong;
            @memcpy(buf[len..][0..scanned], chunk[0..scanned]);
            len += scanned;
            d.reader.toss(scanned);
            if (scanned < chunk.len) {
                if (len == 0) return error.InvalidNumber;
                return buf[0..len];
            }
            d.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    if (len == 0) return error.UnexpectedEndOfInput;
                    return buf[0..len];
                },
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }

    /// Index of the first byte in `window` that cannot appear in a JSON
    /// number, or null if the window is all number bytes.
    inline fn numberEnd(window: []const u8) ?usize {
        for (window, 0..) |c, i| {
            switch (c) {
                '0'...'9', '-', '+', '.', 'e', 'E' => {},
                else => return i,
            }
        }
        return null;
    }

    fn int(d: *Decoder, comptime T: type) DecodeError!T {
        _ = try d.peekByte();

        // Fast path: accumulate the digits in the same pass that finds the end
        // of the number. Only taken when a terminator turns up inside the
        // buffer, which also proves the number was complete. Nothing is
        // consumed until it succeeds, so falling through stays correct.
        {
            const r = d.reader;
            const window = r.buffer[r.seek..r.end];
            var i: usize = @intFromBool(window.len > 0 and window[0] == '-');
            const neg = i == 1;
            const digits_start = i;
            var acc: u64 = 0;
            while (i < window.len) : (i += 1) {
                const digit = window[i] -% '0';
                if (digit > 9) break;
                acc = acc * 10 + digit;
            }
            const ndigits = i - digits_start;
            if (i < window.len and ndigits > 0 and ndigits < 19) {
                @branchHint(.likely);
                if (ndigits > 1 and window[digits_start] == '0') return error.InvalidNumber;
                switch (window[i]) {
                    // A number that continues is a float, not an integer.
                    '.', 'e', 'E', '+' => return error.InvalidNumber,
                    else => {},
                }
                r.seek += i;
                if (neg) {
                    if (@typeInfo(T).int.signedness == .unsigned) return error.NumberOutOfRange;
                    return std.math.cast(T, -@as(i64, @intCast(acc))) orelse error.NumberOutOfRange;
                }
                return std.math.cast(T, acc) orelse error.NumberOutOfRange;
            }
        }

        return d.intSlow(T);
    }

    fn intSlow(d: *Decoder, comptime T: type) DecodeError!T {
        var buf: [max_number_len]u8 = undefined;
        const text = try d.numberSpan(&buf);
        if (!validNumber(text)) return error.InvalidNumber;

        var i: usize = 0;
        const neg = text[0] == '-';
        if (neg or text[0] == '+') i += 1;
        const digits_start = i;

        var acc: u64 = 0;
        while (i < text.len) : (i += 1) {
            const digit = text[i] -% '0';
            if (digit > 9) break;
            acc = acc *% 10 +% digit;
        }
        const ndigits = i - digits_start;
        if (ndigits == 0) return error.InvalidNumber;
        // A JSON number may legally be `1.0` or `1e2` where an integer is
        // wanted; anything left over is not an integer.
        if (i != text.len) return error.InvalidNumber;

        if (ndigits >= 20) {
            return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
                error.Overflow => error.NumberOutOfRange,
                error.InvalidCharacter => error.InvalidNumber,
            };
        }
        if (neg) {
            if (@typeInfo(T).int.signedness == .unsigned) return error.NumberOutOfRange;
            const signed = -@as(i128, acc);
            return std.math.cast(T, signed) orelse error.NumberOutOfRange;
        }
        return std.math.cast(T, acc) orelse error.NumberOutOfRange;
    }

    fn float(d: *Decoder, comptime T: type) DecodeError!T {
        _ = try d.peekByte();

        if (comptime clingerLimits(T) != null) {
            const r = d.reader;
            if (fastFloat(T, r.buffer[r.seek..r.end])) |hit| {
                @branchHint(.likely);
                if (hit.invalid) return error.InvalidNumber;
                if (hit.value) |v| {
                    r.seek += hit.len;
                    return v;
                }
                // The number is complete but outside the exact range. Its
                // extent is already known, so hand the span straight to std
                // rather than scanning it a third time.
                const text = r.buffer[r.seek..][0..hit.len];
                const parsed = std.fmt.parseFloat(T, text) catch return error.InvalidNumber;
                r.seek += hit.len;
                return parsed;
            }
        }
        return d.floatSlow(T);
    }

    fn floatSlow(d: *Decoder, comptime T: type) DecodeError!T {
        var buf: [max_number_len]u8 = undefined;
        const text = try d.numberSpan(&buf);
        if (!validNumber(text)) return error.InvalidNumber;
        return std.fmt.parseFloat(T, text) catch error.InvalidNumber;
    }

    // ------------------------------------------------------------ strings

    /// Index of the first byte in `window` that ends a run of ordinary string
    /// content - a quote, a backslash, or an unescaped control character - 16
    /// bytes at a time.
    inline fn scanStringEnd(window: []const u8) ?usize {
        const V = @Vector(16, u8);
        const quote: V = @splat('"');
        const backslash: V = @splat('\\');
        const space: V = @splat(0x20);
        var i: usize = 0;
        while (i + 16 <= window.len) : (i += 16) {
            const chunk: V = window[i..][0..16].*;
            const hits: u16 = @bitCast((chunk == quote) | (chunk == backslash) | (chunk < space));
            if (hits != 0) return i + @ctz(hits);
        }
        while (i < window.len) : (i += 1) {
            const c = window[i];
            if (c == '"' or c == '\\' or c < 0x20) return i;
        }
        return null;
    }

    fn string(d: *Decoder) DecodeError![]u8 {
        try d.expectByte('"');

        // Fast path: the closing quote is already buffered and there are no
        // escapes, so the length is known and one exact-size allocation does
        // it. The general path below grows an ArrayList, which for a short
        // string costs several allocations.
        const r = d.reader;
        const window = r.buffer[r.seek..r.end];
        if (scanStringEnd(window)) |hit| {
            if (window[hit] == '"') {
                @branchHint(.likely);
                const out = try d.gpa.dupe(u8, window[0..hit]);
                r.seek += hit + 1;
                return out;
            }
            if (window[hit] < 0x20) return error.UnescapedControlCharacter;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(d.gpa);
        try d.stringBody(&out);
        return out.toOwnedSlice(d.gpa);
    }

    /// Consumes a string body up to and including its closing quote. Decoded
    /// content is appended to `out`, or discarded when it is null, which is
    /// what lets `skipValue` step over strings without allocating.
    fn stringBody(d: *Decoder, out: ?*std.ArrayList(u8)) DecodeError!void {
        while (true) {
            const window = d.reader.buffered();
            if (window.len == 0) {
                d.reader.fillMore() catch |err| return mapRead(err);
                continue;
            }
            const hit = scanStringEnd(window) orelse {
                if (out) |o| try o.appendSlice(d.gpa, window);
                d.reader.toss(window.len);
                d.reader.fillMore() catch |err| return mapRead(err);
                continue;
            };
            const c = window[hit];
            if (out) |o| try o.appendSlice(d.gpa, window[0..hit]);
            d.reader.toss(hit + 1);
            if (c == '"') return;
            if (c < 0x20) return error.UnescapedControlCharacter;
            try d.escape(out);
        }
    }

    fn escape(d: *Decoder, out: ?*std.ArrayList(u8)) DecodeError!void {
        const c = d.reader.takeByte() catch |err| return mapRead(err);
        var decoded: [4]u8 = undefined;
        var len: usize = 1;
        switch (c) {
            '"' => decoded[0] = '"',
            '\\' => decoded[0] = '\\',
            '/' => decoded[0] = '/',
            'b' => decoded[0] = 0x08,
            'f' => decoded[0] = 0x0c,
            'n' => decoded[0] = '\n',
            'r' => decoded[0] = '\r',
            't' => decoded[0] = '\t',
            'u' => {
                const first = try d.hex4();
                var code: u21 = first;
                if (first >= 0xd800 and first <= 0xdbff) {
                    const pair = d.reader.peek(2) catch |err| switch (err) {
                        error.EndOfStream => return error.InvalidSurrogatePair,
                        error.ReadFailed => return error.ReadFailed,
                    };
                    if (pair[0] != '\\' or pair[1] != 'u') return error.InvalidSurrogatePair;
                    d.reader.toss(2);
                    const low = try d.hex4();
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidSurrogatePair;
                    code = 0x10000 +
                        ((@as(u21, first) - 0xd800) << 10) +
                        (@as(u21, low) - 0xdc00);
                } else if (first >= 0xdc00 and first <= 0xdfff) {
                    return error.InvalidSurrogatePair;
                }
                len = std.unicode.utf8Encode(code, &decoded) catch return error.InvalidEscape;
            },
            else => return error.InvalidEscape,
        }
        if (out) |o| try o.appendSlice(d.gpa, decoded[0..len]);
    }

    fn hex4(d: *Decoder) DecodeError!u16 {
        const bytes = d.reader.peek(4) catch |err| return mapRead(err);
        var v: u16 = 0;
        for (bytes[0..4]) |c| {
            const digit: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidEscape,
            };
            v = v * 16 + digit;
        }
        d.reader.toss(4);
        return v;
    }

    // ------------------------------------------------------------ compound

    fn slice(d: *Decoder, comptime S: type, comptime Child: type) DecodeError!S {
        try d.expectByte('[');
        try d.pushDepth();
        defer d.depth -= 1;

        if (try d.peekByte() == ']') {
            d.advance(1);
            return &.{};
        }

        var list: std.ArrayList(Child) = .empty;
        errdefer list.deinit(d.gpa);
        while (true) {
            try list.append(d.gpa, try d.value(Child));
            switch (try d.peekByte()) {
                ',' => d.advance(1),
                ']' => {
                    d.advance(1);
                    break;
                },
                else => return error.UnexpectedToken,
            }
        }
        return list.toOwnedSlice(d.gpa);
    }

    fn fixedArray(d: *Decoder, comptime T: type, comptime Child: type, comptime n: usize) DecodeError!T {
        try d.expectByte('[');
        try d.pushDepth();
        defer d.depth -= 1;

        var result: T = undefined;
        inline for (0..n) |i| {
            if (i != 0) {
                if (try d.peekByte() != ',') return error.UnexpectedToken;
                d.advance(1);
            }
            result[i] = try d.value(Child);
        }
        try d.expectByte(']');
        return result;
    }

    fn enumValue(d: *Decoder, comptime T: type) DecodeError!T {
        var buf: [maxTagLen(T)]u8 = undefined;
        const name = (try d.boundedString(&buf)) orelse return error.InvalidEnumTag;
        inline for (@typeInfo(T).@"enum".fields) |f| {
            if (name.len == f.name.len and std.mem.eql(u8, name, f.name)) {
                return @field(T, f.name);
            }
        }
        return error.InvalidEnumTag;
    }

    /// Tagged unions are encoded as a one-member object, `{"tag":payload}`.
    fn unionValue(d: *Decoder, comptime T: type) DecodeError!T {
        const info = @typeInfo(T).@"union";
        if (info.tag_type == null) @compileError("json: cannot decode untagged union " ++ @typeName(T));

        try d.expectByte('{');
        try d.pushDepth();
        defer d.depth -= 1;

        var buf: [maxTagLen(T)]u8 = undefined;
        const name = (try d.boundedString(&buf)) orelse return error.InvalidEnumTag;
        try d.expectByte(':');

        var result: ?T = null;
        inline for (info.fields) |f| {
            if (result == null and name.len == f.name.len and std.mem.eql(u8, name, f.name)) {
                result = @unionInit(T, f.name, try d.value(f.type));
            }
        }
        if (result == null) return error.InvalidEnumTag;
        try d.expectByte('}');
        return result.?;
    }

    fn object(d: *Decoder, comptime T: type) DecodeError!T {
        const fields = @typeInfo(T).@"struct".fields;
        const options = comptime json.structOptions(T);

        try d.expectByte('{');
        try d.pushDepth();
        defer d.depth -= 1;

        var result: T = undefined;
        var seen = std.bit_set.StaticBitSet(fields.len).initEmpty();

        if (try d.peekByte() == '}') {
            d.advance(1);
        } else {
            // Producers emit fields in a stable order, so the next member is
            // almost always the next field. Its whole key token - quote, name,
            // quote, colon - is comptime-known, so try matching it outright
            // before falling back to reading the key as a string and searching
            // for it. A miss costs one failed compare and is always correct.
            var next_field: usize = 0;
            while (true) {
                var matched = false;

                if (comptime fields.len > 0) {
                    switch (next_field) {
                        inline 0...(fields.len - 1) => |idx| {
                            const token = comptime "\"" ++ escapedLiteral(jsonKey(T, fields[idx].name)) ++ "\":";
                            if (d.tryToken(token)) {
                                @field(result, fields[idx].name) = try d.value(fields[idx].type);
                                seen.set(idx);
                                next_field = idx + 1;
                                matched = true;
                            }
                        },
                        else => {},
                    }
                }

                if (!matched) {
                    var buf: [maxKeyLen(T)]u8 = undefined;
                    const key = try d.boundedString(&buf);
                    try d.expectByte(':');

                    if (key) |name| {
                        inline for (fields, 0..) |f, idx| {
                            const key_name = comptime jsonKey(T, f.name);
                            if (!matched and name.len == key_name.len and
                                std.mem.eql(u8, name, key_name))
                            {
                                @field(result, f.name) = try d.value(f.type);
                                seen.set(idx);
                                next_field = idx + 1;
                                matched = true;
                            }
                        }
                    }
                    if (!matched) {
                        if (!options.skip_unknown_fields) return error.UnknownField;
                        try d.skipValue();
                    }
                }

                switch (try d.peekByte()) {
                    ',' => d.advance(1),
                    '}' => {
                        d.advance(1);
                        break;
                    },
                    else => return error.UnexpectedToken,
                }
            }
        }

        inline for (fields, 0..) |f, idx| {
            if (!seen.isSet(idx)) {
                if (f.defaultValue()) |default| {
                    @field(result, f.name) = default;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(result, f.name) = null;
                } else {
                    return error.MissingField;
                }
            }
        }
        return result;
    }

    /// Reads a string that only needs to be compared, not kept. Returns null
    /// when it cannot possibly match - longer than any candidate - having
    /// consumed it either way, so no allocation is involved on any path.
    fn boundedString(d: *Decoder, buf: []u8) DecodeError!?[]const u8 {
        try d.expectByte('"');

        // Fast path: the whole key is buffered and unescaped.
        {
            const r = d.reader;
            const window = r.buffer[r.seek..r.end];
            if (scanStringEnd(window)) |hit| {
                if (window[hit] == '"') {
                    @branchHint(.likely);
                    r.seek += hit + 1;
                    if (hit > buf.len) return null;
                    @memcpy(buf[0..hit], window[0..hit]);
                    return buf[0..hit];
                }
                if (window[hit] < 0x20) return error.UnescapedControlCharacter;
            }
        }

        var len: usize = 0;
        var overflowed = false;

        while (true) {
            const window = d.reader.buffered();
            if (window.len == 0) {
                d.reader.fillMore() catch |err| return mapRead(err);
                continue;
            }
            const hit = scanStringEnd(window) orelse {
                if (len + window.len <= buf.len) {
                    @memcpy(buf[len..][0..window.len], window);
                    len += window.len;
                } else overflowed = true;
                d.reader.toss(window.len);
                d.reader.fillMore() catch |err| return mapRead(err);
                continue;
            };
            const c = window[hit];
            if (len + hit <= buf.len) {
                @memcpy(buf[len..][0..hit], window[0..hit]);
                len += hit;
            } else overflowed = true;
            d.reader.toss(hit + 1);
            if (c == '"') return if (overflowed) null else buf[0..len];
            if (c < 0x20) return error.UnescapedControlCharacter;

            // An escape in a key is rare; decode it into the same bounded
            // buffer so that `"id"` still matches the field `id`.
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(d.gpa);
            try d.escape(&scratch);
            if (len + scratch.items.len <= buf.len) {
                @memcpy(buf[len..][0..scratch.items.len], scratch.items);
                len += scratch.items.len;
            } else overflowed = true;
        }
    }

    /// Steps over one value of any shape, for unknown object members and for
    /// `json.validate`.
    ///
    /// This validates as it goes rather than counting brackets: a skipped
    /// subtree has to be well-formed JSON, so `{"x":[}]` is rejected instead of
    /// being waved through because the bracket counter happened to balance.
    pub fn skipValue(d: *Decoder) DecodeError!void {
        try d.pushDepth();
        defer d.depth -= 1;

        switch (try d.peekByte()) {
            '{' => {
                d.advance(1);
                if (try d.peekByte() == '}') {
                    d.advance(1);
                    return;
                }
                while (true) {
                    if (try d.peekByte() != '"') return error.UnexpectedToken;
                    d.advance(1);
                    try d.stringBody(null);
                    try d.expectByte(':');
                    try d.skipValue();
                    switch (try d.peekByte()) {
                        ',' => d.advance(1),
                        '}' => {
                            d.advance(1);
                            return;
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            '[' => {
                d.advance(1);
                if (try d.peekByte() == ']') {
                    d.advance(1);
                    return;
                }
                while (true) {
                    try d.skipValue();
                    switch (try d.peekByte()) {
                        ',' => d.advance(1),
                        ']' => {
                            d.advance(1);
                            return;
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            '"' => {
                d.advance(1);
                try d.stringBody(null);
            },
            't' => try d.expectLiteralOrFail("true"),
            'f' => try d.expectLiteralOrFail("false"),
            'n' => try d.expectLiteralOrFail("null"),
            '-', '0'...'9' => try d.skipNumber(),
            else => return error.UnexpectedToken,
        }
    }

    /// Kept out of `skipValue` so its number buffer is not part of every
    /// recursion frame.
    fn skipNumber(d: *Decoder) DecodeError!void {
        var buf: [max_number_len]u8 = undefined;
        const text = try d.numberSpan(&buf);
        if (!validNumber(text)) return error.InvalidNumber;
    }

    fn expectLiteralOrFail(d: *Decoder, comptime lit: []const u8) DecodeError!void {
        if (!try d.expectLiteral(lit)) return error.UnexpectedToken;
    }

    fn pushDepth(d: *Decoder) DecodeError!void {
        d.depth += 1;
        if (d.depth > max_depth) return error.DepthLimitExceeded;
    }
};

fn jsonKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    const options = comptime json.structOptions(T);
    return switch (options.key) {
        .field_name => field_name,
        .custom => T.jsonFieldName(@field(std.meta.FieldEnum(T), field_name)),
    };
}

fn maxKeyLen(comptime T: type) usize {
    comptime {
        var m: usize = 1;
        for (@typeInfo(T).@"struct".fields) |f| m = @max(m, jsonKey(T, f.name).len);
        return m;
    }
}

fn maxTagLen(comptime T: type) usize {
    comptime {
        var m: usize = 1;
        switch (@typeInfo(T)) {
            .@"enum" => |info| for (info.fields) |f| {
                m = @max(m, f.name.len);
            },
            .@"union" => |info| for (info.fields) |f| {
                m = @max(m, f.name.len);
            },
            else => unreachable,
        }
        return m;
    }
}
