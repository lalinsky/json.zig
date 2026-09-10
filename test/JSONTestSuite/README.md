# JSONTestSuite

The `test_parsing` cases from [nst/JSONTestSuite](https://github.com/nst/JSONTestSuite),
by Nicolas Seriot, accompanying *"Parsing JSON is a Minefield"*. MIT licensed;
see `LICENSE`.

Only `test_parsing` is vendored. The upstream repository is ~168 MB, almost all
of which is `parsers/` — bundled implementations used by upstream's own test
runner, which we have no use for. Vendoring the 1.6 MB we do need keeps
`zig build conformance` fast and offline instead of downloading 168 MB per run.

Case names carry their expected outcome: `y_` must be accepted, `n_` must be
rejected, `i_` is implementation-defined. See `test/conformance.zig`.
