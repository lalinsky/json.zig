//! Runs JSONTestSuite (github.com/nst/JSONTestSuite) against the library.
//!
//! The suite names each case by its expected outcome:
//!
//!   y_*  must be accepted
//!   n_*  must be rejected
//!   i_*  implementation-defined; behaviour is reported, nothing is asserted
//!
//! Each case runs through two entry points. `validate` takes documents of any
//! shape. The typed pass decodes into a set of candidate Zig types: a `y_`
//! case passes if any candidate accepts it, an `n_` case only if every
//! candidate refuses.

const std = @import("std");
const json = @import("json");
const build_options = @import("build_options");

const Failure = struct {
    name: []const u8,
    detail: []const u8,
};

/// The exact type each must-accept case decodes into, derived from the case
/// itself. Naming the type per case means a pass says the typed decoder read
/// that document as that shape, not that one of a pile of types happened to
/// swallow it.
const typed_cases = .{
    .{ "y_array_arraysWithSpaces.json", []const []const i64 },
    .{ "y_array_empty-string.json", []const []const u8 },
    .{ "y_array_empty.json", []const i64 },
    .{ "y_array_ending_with_newline.json", []const []const u8 },
    .{ "y_array_false.json", []const bool },
    .{ "y_array_null.json", []const ?u8 },
    .{ "y_array_with_1_and_newline.json", []const i64 },
    .{ "y_array_with_leading_space.json", []const i64 },
    .{ "y_array_with_several_null.json", []const ?i64 },
    .{ "y_array_with_trailing_space.json", []const i64 },
    .{ "y_number.json", []const f64 },
    .{ "y_number_0e+1.json", []const f64 },
    .{ "y_number_0e1.json", []const f64 },
    .{ "y_number_after_space.json", []const i64 },
    .{ "y_number_double_close_to_zero.json", []const f64 },
    .{ "y_number_int_with_exp.json", []const f64 },
    .{ "y_number_minus_zero.json", []const i64 },
    .{ "y_number_negative_int.json", []const i64 },
    .{ "y_number_negative_one.json", []const i64 },
    .{ "y_number_negative_zero.json", []const i64 },
    .{ "y_number_real_capital_e.json", []const f64 },
    .{ "y_number_real_capital_e_neg_exp.json", []const f64 },
    .{ "y_number_real_capital_e_pos_exp.json", []const f64 },
    .{ "y_number_real_exponent.json", []const f64 },
    .{ "y_number_real_fraction_exponent.json", []const f64 },
    .{ "y_number_real_neg_exp.json", []const f64 },
    .{ "y_number_real_pos_exponent.json", []const f64 },
    .{ "y_number_simple_int.json", []const i64 },
    .{ "y_number_simple_real.json", []const f64 },
    .{ "y_object.json", struct { asd: []const u8, dfg: []const u8 } },
    .{ "y_object_basic.json", struct { asd: []const u8 } },
    .{ "y_object_empty.json", struct {} },
    .{ "y_object_extreme_numbers.json", struct { min: f64, max: f64 } },
    .{ "y_object_long_strings.json", struct { x: []const struct { id: []const u8 }, id: []const u8 } },
    .{ "y_object_simple.json", struct { a: []const i64 } },
    .{ "y_object_string_unicode.json", struct { title: []const u8 } },
    .{ "y_object_with_newlines.json", struct { a: []const u8 } },
    .{ "y_string_1_2_3_bytes_UTF-8_sequences.json", []const []const u8 },
    .{ "y_string_accepted_surrogate_pair.json", []const []const u8 },
    .{ "y_string_accepted_surrogate_pairs.json", []const []const u8 },
    .{ "y_string_allowed_escapes.json", []const []const u8 },
    .{ "y_string_backslash_and_u_escaped_zero.json", []const []const u8 },
    .{ "y_string_backslash_doublequotes.json", []const []const u8 },
    .{ "y_string_comments.json", []const []const u8 },
    .{ "y_string_double_escape_a.json", []const []const u8 },
    .{ "y_string_double_escape_n.json", []const []const u8 },
    .{ "y_string_escaped_control_character.json", []const []const u8 },
    .{ "y_string_escaped_noncharacter.json", []const []const u8 },
    .{ "y_string_in_array.json", []const []const u8 },
    .{ "y_string_in_array_with_leading_space.json", []const []const u8 },
    .{ "y_string_last_surrogates_1_and_2.json", []const []const u8 },
    .{ "y_string_nbsp_uescaped.json", []const []const u8 },
    .{ "y_string_nonCharacterInUTF-8_U+10FFFF.json", []const []const u8 },
    .{ "y_string_nonCharacterInUTF-8_U+FFFF.json", []const []const u8 },
    .{ "y_string_null_escape.json", []const []const u8 },
    .{ "y_string_one-byte-utf-8.json", []const []const u8 },
    .{ "y_string_pi.json", []const []const u8 },
    .{ "y_string_reservedCharacterInUTF-8_U+1BFFF.json", []const []const u8 },
    .{ "y_string_simple_ascii.json", []const []const u8 },
    .{ "y_string_space.json", []const u8 },
    .{ "y_string_surrogates_U+1D11E_MUSICAL_SYMBOL_G_CLEF.json", []const []const u8 },
    .{ "y_string_three-byte-utf-8.json", []const []const u8 },
    .{ "y_string_two-byte-utf-8.json", []const []const u8 },
    .{ "y_string_u+2028_line_sep.json", []const []const u8 },
    .{ "y_string_u+2029_par_sep.json", []const []const u8 },
    .{ "y_string_uEscape.json", []const []const u8 },
    .{ "y_string_uescaped_newline.json", []const []const u8 },
    .{ "y_string_unescaped_char_delete.json", []const []const u8 },
    .{ "y_string_unicode.json", []const []const u8 },
    .{ "y_string_unicodeEscapedBackslash.json", []const []const u8 },
    .{ "y_string_unicode_2.json", []const []const u8 },
    .{ "y_string_unicode_U+10FFFE_nonchar.json", []const []const u8 },
    .{ "y_string_unicode_U+1FFFE_nonchar.json", []const []const u8 },
    .{ "y_string_unicode_U+200B_ZERO_WIDTH_SPACE.json", []const []const u8 },
    .{ "y_string_unicode_U+2064_invisible_plus.json", []const []const u8 },
    .{ "y_string_unicode_U+FDD0_nonchar.json", []const []const u8 },
    .{ "y_string_unicode_U+FFFE_nonchar.json", []const []const u8 },
    .{ "y_string_unicode_escaped_double_quote.json", []const []const u8 },
    .{ "y_string_utf8.json", []const []const u8 },
    .{ "y_string_with_del_character.json", []const []const u8 },
    .{ "y_structure_lonely_false.json", bool },
    .{ "y_structure_lonely_int.json", i64 },
    .{ "y_structure_lonely_negative_real.json", f64 },
    .{ "y_structure_lonely_null.json", ?u8 },
    .{ "y_structure_lonely_string.json", []const u8 },
    .{ "y_structure_lonely_true.json", bool },
    .{ "y_structure_string_empty.json", []const u8 },
    .{ "y_structure_trailing_newline.json", []const []const u8 },
    .{ "y_structure_true_in_array.json", []const bool },
    .{ "y_structure_whitespace_array.json", []const i64 },
};

/// Must-accept cases with no entry above, and why.
const untypeable = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "y_array_heterogeneous.json", .why = "no static Zig type expresses [null, 1, \"1\", {}]" },
    .{ .name = "y_object_duplicated_key.json", .why = "duplicate keys, which this library rejects" },
    .{ .name = "y_object_duplicated_key_and_value.json", .why = "duplicate keys, which this library rejects" },
    .{ .name = "y_object_empty_key.json", .why = "a Zig identifier cannot be empty" },
    .{ .name = "y_object_escaped_null_in_key.json", .why = "a Zig identifier cannot contain a NUL" },
};

/// Concrete shapes the must-reject cases are tried against. None of them skip
/// unknown fields: a struct that skipped everything would be the validator
/// wearing a type, exercising none of the field matching the typed path exists
/// to test.
const reject_candidates = .{
    []const []const u8,
    []const f64,
    []const i64,
    []const bool,
    []const ?i64,
    []const []const i64,
    []const u8,
    bool,
    f64,
    i64,
    ?u8,
    struct {},
    struct { a: []const u8 },
    struct { a: []const i64 },
    struct { asd: []const u8 },
    struct { asd: []const u8, dfg: []const u8 },
    struct { min: f64, max: f64 },
    struct { id: []const u8, x: []const i64 },
    struct { title: []const u8 },
};

/// Decodes `bytes` as the exact type recorded for `name`, if there is one.
fn decodeAsRecordedType(gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) ?anyerror!void {
    inline for (typed_cases) |case| {
        if (std.mem.eql(u8, case[0], name)) {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            if (json.decodeFromSliceLeaky(case[1], arena.allocator(), bytes, .{})) |_| {
                return {};
            } else |err| {
                return err;
            }
        }
    }
    return null;
}

/// True if any concrete shape decodes `bytes` without error.
fn anyTypeDecodes(gpa: std.mem.Allocator, bytes: []const u8) bool {
    inline for (reject_candidates) |T| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (json.decodeFromSliceLeaky(T, arena.allocator(), bytes, .{})) |_| {
            return true;
        } else |_| {}
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var verbose = false;
    for (try init.minimal.args.toSlice(gpa)) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) verbose = true;
    }

    var dir = try std.Io.Dir.cwd().openDir(io, build_options.suite_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var y_pass: usize = 0;
    var n_pass: usize = 0;
    var typed_y: usize = 0;
    var typed_y_unmatched: usize = 0;
    var typed_n_pass: usize = 0;
    var i_accepted: usize = 0;
    var i_rejected: usize = 0;
    var failures: std.ArrayList(Failure) = .empty;

    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 24));
        const result = json.validateFromSlice(bytes);

        // The typed pass. `y_` decodes as the one type recorded for that case;
        // `n_` has to be refused by every concrete shape.
        switch (name[0]) {
            'y' => {
                if (decodeAsRecordedType(gpa, name, bytes)) |outcome| {
                    if (outcome) |_| {
                        typed_y += 1;
                    } else |err| {
                        try failures.append(gpa, .{
                            .name = name,
                            .detail = try std.fmt.allocPrint(gpa, "typed decode failed with {t}", .{err}),
                        });
                    }
                } else {
                    typed_y_unmatched += 1;
                }
            },
            'n' => if (anyTypeDecodes(gpa, bytes)) {
                try failures.append(gpa, .{
                    .name = name,
                    .detail = "typed decode accepted a document that must be rejected",
                });
            } else {
                typed_n_pass += 1;
            },
            else => {},
        }

        switch (name[0]) {
            'y' => if (result) |_| {
                y_pass += 1;
            } else |err| {
                try failures.append(gpa, .{
                    .name = name,
                    .detail = try std.fmt.allocPrint(gpa, "should be accepted, got {t}", .{err}),
                });
            },
            'n' => if (result) |_| {
                try failures.append(gpa, .{
                    .name = name,
                    .detail = "should be rejected, was accepted",
                });
            } else |_| {
                n_pass += 1;
            },
            'i' => if (result) |_| {
                i_accepted += 1;
                if (verbose) std.debug.print("  i accepted  {s}\n", .{name});
            } else |err| {
                i_rejected += 1;
                if (verbose) std.debug.print("  i rejected  {s} ({t})\n", .{ name, err });
            },
            else => {},
        }
    }

    const y_total = y_pass + countPrefix(failures.items, 'y');
    const n_total = n_pass + countPrefix(failures.items, 'n');

    std.debug.print(
        \\JSONTestSuite: {d} cases
        \\  y_ (must accept):  {d}/{d}
        \\  n_ (must reject):  {d}/{d}
        \\  i_ (either):       {d} accepted, {d} rejected
        \\typed decode into real Zig types
        \\  y_ decoded:        {d}/{d} as their own type
        \\  n_ refused by all: {d}/{d}
        \\
    , .{
        names.items.len, y_pass,  y_total,
        n_pass,          n_total, i_accepted,
        i_rejected,      typed_y, y_total,
        typed_n_pass,    n_total,
    });

    if (typed_y_unmatched != 0) {
        std.debug.print("\nnot typed:\n", .{});
        for (untypeable) |u| std.debug.print("  {s}: {s}\n", .{ u.name, u.why });
    }

    if (failures.items.len != 0) {
        std.debug.print("\n{d} failures:\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  {s}: {s}\n", .{ f.name, f.detail });
        std.process.exit(1);
    }
}

fn countPrefix(failures: []const Failure, prefix: u8) usize {
    var n: usize = 0;
    for (failures) |f| {
        if (f.name[0] == prefix) n += 1;
    }
    return n;
}
