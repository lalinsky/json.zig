# json.zig

Static JSON encoding and decoding for Zig, driven by your types. Designed to be used for APIs with strict schemas.

Everything is comptime-specialized into the type being encoded or decoded:
there is no `Value`, no tokenizer, and no runtime schema. Encoding writes to a
`std.Io.Writer` and decoding reads from a `std.Io.Reader`, so both work against
sockets and files, not only complete buffers. Due to the static nature, it's much
faster than `std.json`, especially at decoding.

## Installation

1) Add json.zig as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/lalinsky/json.zig?ref=v0.1.0"
```

2) In your `build.zig`, add the `json` module as a dependency of your program:

```zig
const json = b.dependency("json", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("json", json.module("json"));
```

Requires Zig 0.16.0.

## Usage

```zig
const std = @import("std");
const json = @import("json");

const Message = struct {
    name: []const u8,
    age: u8,
};

var buffer: std.Io.Writer.Allocating = .init(allocator);
defer buffer.deinit();

try json.encode(Message{ .name = "John", .age = 20 }, &buffer.writer);
// {"name":"John","age":20}

const decoded = try json.decodeFromSlice(Message, allocator, buffer.written());
defer decoded.deinit();

std.debug.assert(decoded.value.age == 20);
```

`decodeFromSlice` creates an arena of its own for the decoded value, which is
what `deinit` frees. If you are already decoding into memory you release in one
go, such as a per-request arena or a fixed buffer, use `decodeFromSliceLeaky`
instead. It allocates straight from the allocator you give it, so there is
nothing to deinit, and it avoids a second arena inside your own:

```zig
var arena: std.heap.ArenaAllocator = .init(allocator);
defer arena.deinit();

const message = try json.decodeFromSliceLeaky(Message, arena.allocator(), bytes);
```

On failure a leaky decode does not release what it already allocated, so give
it an allocator you can discard wholesale. `decode` owns an arena and frees it
on error.

There is also `json.encodeAlloc(gpa, value)` when you just want a slice.

## Streaming

`decodeLeaky` takes a reader, and `decode` does too:

```zig
const message = try json.decodeLeaky(Message, arena.allocator(), &reader);
```

The reader's buffer may be far smaller than the values being decoded. Strings,
numbers and skipped values are all consumed incrementally, so a 1 MB string
decodes fine through a 64-byte buffer. The buffer must hold at least 8 bytes.

## Validating without decoding

`json.validate` checks that a reader holds exactly one well-formed JSON
document, without building anything from it:

```zig
try json.validate(&reader);
try json.validateFromSlice(bytes);
```

It allocates nothing, and it accepts and rejects exactly what the decoder does,
since it runs the same scanner, string, number and nesting code.

Strings are validated as UTF-8 on the way in, so a decoded `[]const u8` is
always well-formed. Pure-ASCII strings do not pay for the check: the scan
detects non-ASCII bytes in the same pass that finds the end of the string.

## Struct options

By default a struct is an object keyed by field name, and optional fields that
are null are left out entirely. Change that by declaring `jsonFormat`:

```zig
const Message = struct {
    user_id: u32,
    nickname: ?[]const u8,

    pub fn jsonFormat() json.StructOptions {
        return .{
            .key = .custom,
            .skip_unknown_fields = true,
            .omit_null_fields = false,
        };
    }

    pub fn jsonFieldName(comptime field: std.meta.FieldEnum(@This())) []const u8 {
        return switch (field) {
            .user_id => "userId",
            .nickname => "nickname",
        };
    }
};
```

A field appearing twice in one object is `error.DuplicateField`, matching
`std.json`. `skip_unknown_fields` steps over object members whose key matches no field,
instead of failing with `error.UnknownField`. It lets a consumer read documents
from a newer producer that added fields. Missing fields are already accepted
without any option, as long as they have a default value or are optional.

## Union formats

A tagged union is encoded as a one-member object keyed by the variant name:

```json
{"circle":{"radius":2.5}}
```

Declaring `jsonFormat` switches it to the flattened form, where the variant's
own fields sit next to a tag field:

```zig
const Shape = union(enum) {
    circle: struct { radius: f64 },
    rect: struct { w: u32, h: u32 },

    pub fn jsonFormat() json.UnionFormat {
        return .{ .as_tagged = .{ .tag_field = "type", .skip_unknown_fields = false } };
    }
};
```

```json
{"type":"circle","radius":2.5}
```

`as_tagged` needs every variant to carry a struct or `void`, since there is
nothing to hoist otherwise, and the tag must be the object's **first** member.
Anything else would mean buffering the whole object before knowing which
variant to build, which a streaming decoder cannot do.

## Custom formats

A type can take over its own encoding entirely:

```zig
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
```

## Type mapping

| Zig | JSON |
| --- | --- |
| `bool` | `true` / `false` |
| integers | number |
| floats | number (`null` for NaN and infinities) |
| `[]const u8` | string (validated as UTF-8) |
| slices, arrays | array |
| structs | object |
| `?T` | `null`, or the encoding of `T` |
| enums | string naming the tag |
| tagged unions | one-member object, or flattened (see below) |
| `void` | `null` |

Encoding a NaN or infinity as `null` matches what JavaScript's
`JSON.stringify` does. Pass `.{ .non_finite = .fail }` to
`encodeWithOptions` to get `error.NonFiniteFloat` instead.

## Design

The speed comes from doing less work rather than from tricks. There is no
tokenizer: the function that decodes a struct is generated from that struct's
fields, and bytes go straight into the result. Object keys are matched as whole
comptime-known tokens rather than read as strings and looked up, integers
accumulate in the same pass that finds the end of the number, strings are
scanned in blocks and copied in runs, and reads take a fast path directly out
of the reader's buffer when the value is already there.

## Limitations

Maps and dynamic documents (there is no `Value` type), untagged unions, and
comments or trailing commas in input.

Nesting deeper than 256 levels is rejected.

## Conformance

`zig build conformance` runs [JSONTestSuite][suite], the standard suite for
RFC 8259 parsers. All 95 must-accept and 188 must-reject cases pass.

Of the 35 cases the suite leaves implementation-defined, this library rejects
invalid UTF-8, malformed `\u` surrogate pairs, UTF-16 input, byte-order marks,
and nesting past its depth limit. It accepts numbers that overflow or underflow
the destination type, which decode to infinity or zero.

Its cases are vendored under `test/JSONTestSuite`, so the run is offline and
needs no network.

[suite]: https://github.com/nst/JSONTestSuite

## License

MIT
