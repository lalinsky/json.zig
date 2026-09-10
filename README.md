# json.zig

Static JSON encoding and decoding for Zig, driven by your types.

Everything is comptime-specialized into the type being encoded or decoded:
there is no `Value`, no tokenizer, and no runtime schema. Encoding writes to a
`std.Io.Writer` and decoding reads from a `std.Io.Reader`, so both work against
sockets and files, not only complete buffers.

It is faster than `std.json` — several times faster at decoding, and faster at
encoding for most payloads.

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
go — a per-request arena, or a fixed buffer — use `decodeFromSliceLeaky`
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

`skip_unknown_fields` steps over object members whose key matches no field,
instead of failing with `error.UnknownField`. It lets a consumer read documents
from a newer producer that added fields. Missing fields are already accepted
without any option, as long as they have a default value or are optional.

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
| `[]const u8` | string |
| slices, arrays | array |
| structs | object |
| `?T` | `null`, or the encoding of `T` |
| enums | string naming the tag |
| tagged unions | one-member object, `{"tag":payload}` |
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

One caveat worth knowing: float *encoding* has little headroom, because it is
dominated by shortest-round-trip formatting — `std.fmt`'s Ryu implementation,
the same one `std.json` uses. On a struct carrying an `f64` per record, that
formatting is about half of total encode time.

## Not supported

Maps and dynamic documents (there is no `Value` type), untagged unions, and
comments or trailing commas in input. Number syntax is validated by
`std.fmt.parseFloat` rather than strictly against the JSON grammar, so some
inputs JSON rejects — a leading `+`, a bare leading `.` — are accepted.

## License

MIT
