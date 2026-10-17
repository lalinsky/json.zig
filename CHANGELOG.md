# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Support for Zig 0.17, alongside 0.16
- Decoding single-item pointers (`*T`, `?*T`), which makes recursive types work

### Changed
- Encoding writes straight into the writer's buffer when there is room, with the writer marked `noalias`, which makes encoding about 26% faster on a string-heavy document and 14% on a small message
- Integers are written straight into the writer's buffer, and strings shorter than 16 bytes are escaped inline, about another 5% on a string-heavy document and 8% on a small message
- Floats too long for the exact fast path, around 17 significant digits, are converted with Eisel-Lemire from the digits already collected instead of being parsed again by `std.fmt.parseFloat`, which cuts the instructions spent decoding a float-heavy document by about 15%

### Fixed
- Structs with a few dozen fields failing to compile with "evaluation exceeded 1000 backwards branches"

### Fixed
- Strings were scanned wrong on big-endian targets with Zig 0.16, so decoding failed and encoding could leave characters unescaped

## [0.1.0] - 2026-09-16

Initial release.
