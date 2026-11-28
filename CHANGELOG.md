# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Decoding sentinel-terminated slices such as `[:0]const u8`
- `DecodeOptions.allow_trailing_data`, to stop after the value instead of failing with `error.TrailingData`, for reading a stream of documents
- Non-exhaustive enums decode from a number as well as from a tag name

### Changed
- `decodeFromSlice`, `decodeFromSliceLeaky` and `validateFromSlice` return the new `SliceDecodeError`, which is `DecodeError` without `ReadFailed`, since a slice cannot fail to read. A `switch` on their errors that handles `error.ReadFailed` has to drop that prong
- Tuples are encoded as JSON arrays, with every element written including nulls, and decoded from arrays of the same length. They used to be objects keyed by field index
- A tuple is no longer accepted as the payload of an `as_tagged` union variant, since its elements have no names to hoist. It used to be flattened into members named `"0"`, `"1"` and so on

### Fixed
- Decoding into a sentinel-terminated array such as `[3:0]u8` left the sentinel undefined
- Encoding a value of a non-exhaustive enum that has no named tag panicked. It is now written as its integer
- A JSON array too short for the fixed-size array it was decoded into was reported as `error.InvalidNumber` when the elements are numbers or optional numbers. It is now `error.UnexpectedToken`, as for other element types and for tuples

## [0.2.0] - 2026-10-25

### Added
- Support for Zig 0.17, alongside 0.16
- Decoding single-item pointers (`*T`, `?*T`), which makes recursive types work

### Changed
- Encoding writes straight into the writer's buffer when there is room, with the writer marked `noalias`, which makes encoding about 26% faster on a string-heavy document and 14% on a small message
- Integers are written straight into the writer's buffer, and strings shorter than 16 bytes are escaped inline, about another 5% on a string-heavy document and 8% on a small message

### Fixed
- Structs with a few dozen fields failing to compile with "evaluation exceeded 1000 backwards branches"
- Strings were scanned wrong on big-endian targets with Zig 0.16, so decoding failed and encoding could leave characters unescaped

## [0.1.0] - 2026-09-16

Initial release.
