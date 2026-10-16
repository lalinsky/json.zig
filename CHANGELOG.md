# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Support for Zig 0.17, alongside 0.16
- Decoding single-item pointers (`*T`, `?*T`), which makes recursive types work

### Fixed
- Structs with a few dozen fields failing to compile with "evaluation exceeded 1000 backwards branches"

### Fixed
- Strings were scanned wrong on big-endian targets with Zig 0.16, so decoding failed and encoding could leave characters unescaped

## [0.1.0] - 2026-09-16

Initial release.
