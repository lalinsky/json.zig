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

### Fixed
- Structs with a few dozen fields failing to compile with "evaluation exceeded 1000 backwards branches"

## [0.1.0] - 2026-09-16

Initial release.
