# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-10

Initial release.

### Added
- Static JSON encoding to `std.Io.Writer` and decoding from `std.Io.Reader`,
  comptime-specialized into the type being encoded or decoded
- Support for bools, integers of any width, floats, strings, slices, fixed-size
  arrays, structs, optionals, enums, tagged unions and `void`
- `jsonFormat` struct options: `field_name` or `custom` keys,
  `skip_unknown_fields`, and `omit_null_fields`
- Two union encodings, selected with `jsonFormat`: a one-member object keyed by
  the variant name, or `as_tagged`, which hoists the variant's fields next to a
  tag field
- `jsonWrite` and `jsonRead` hooks for types that define their own format
- Values larger than the reader's buffer decode incrementally, so strings,
  numbers and skipped values are not limited by the buffer size
- Clinger's exact fast path for float decoding, falling back to
  `std.fmt.parseFloat` outside the range where a single rounding is provably
  correct
- `json.validate` and `json.validateFromSlice`, which check that input is one
  well-formed JSON document without building anything from it
- Strings are validated as UTF-8, matching `std.json`, simdjson and yyjson;
  a decoded `[]const u8` is always well-formed
- `zig build conformance`, running [JSONTestSuite][suite] as a lazy dependency;
  all 95 must-accept and 188 must-reject cases pass

[suite]: https://github.com/nst/JSONTestSuite
