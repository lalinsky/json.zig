# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `json.validate` and `json.validateFromSlice`, which check that input is one
  well-formed JSON document without building anything from it and without
  allocating
- `zig build conformance`, running [JSONTestSuite][suite] as a lazy dependency;
  all 95 must-accept and 188 must-reject cases pass

[suite]: https://github.com/nst/JSONTestSuite

### Fixed
- Numbers are checked against RFC 8259's grammar rather than being handed to
  `std.fmt.parseFloat`, which is more permissive: `--1`, `01`, `+1`, `1.`, `1e`
  and a bare leading `.` were all accepted
- Skipped values are now parsed rather than bracket-counted, so a malformed
  subtree such as `{"x":[}]` behind `skip_unknown_fields` is rejected instead
  of being accepted
- Unescaped control characters inside strings and object keys are rejected with
  `error.UnescapedControlCharacter`, as RFC 8259 requires
- Floats encode at their own precision instead of being widened to `f64` first,
  which lost digits for `f80`/`f128` and turned finite values outside `f64`'s
  range into `null`
- Struct field names and union tag names are escaped when written, so a name
  containing a quote, backslash or control character can no longer produce
  invalid JSON
- `EncodeOptions` are carried into custom `jsonWrite` serializers instead of
  being reset to defaults

## [0.1.0] - 2026-09-10

Initial release.

### Added
- Static JSON encoding to `std.Io.Writer` and decoding from `std.Io.Reader`,
  comptime-specialized into the type being encoded or decoded
- Support for bools, integers of any width, floats, strings, slices, fixed-size
  arrays, structs, optionals, enums, tagged unions and `void`
- `jsonFormat` struct options: `field_name` or `custom` keys,
  `skip_unknown_fields`, and `omit_null_fields`
- `jsonWrite` and `jsonRead` hooks for types that define their own format
- Values larger than the reader's buffer decode incrementally, so strings,
  numbers and skipped values are not limited by the buffer size
- Clinger's exact fast path for float decoding, falling back to
  `std.fmt.parseFloat` outside the range where a single rounding is provably
  correct
