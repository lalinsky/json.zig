# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A truncated document is now `error.EndOfStream` instead of `error.UnexpectedEndOfInput`, including a literal, number or surrogate pair cut off at the end. The slice functions return the new `SliceDecodeError`, which does not include `ReadFailed`.

## [0.1.0] - 2026-09-16

Initial release.
