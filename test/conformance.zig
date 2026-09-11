//! Runs JSONTestSuite (github.com/nst/JSONTestSuite) against `json.validate`.
//!
//! The suite names each case by its expected outcome:
//!
//!   y_*  must be accepted
//!   n_*  must be rejected
//!   i_*  implementation-defined; behaviour is reported, nothing is asserted
//!
//! Two passes run over every case.
//!
//! `validate` handles documents of arbitrary shape, so it covers the whole
//! suite. But it is not the entry point callers use, and a decode-only bug can
//! hide behind it: `.5` was accepted by the typed decoder while `validate`
//! rejected it, with the suite green throughout.
//!
//! So a second pass decodes each case into real Zig types. A handful of
//! candidate types covers most of the suite - it is dominated by one-element
//! arrays - and for the must-reject cases the assertion is the strong one:
//! *every* candidate has to fail, since any success means the typed decoder
//! accepted a document JSON forbids.

const std = @import("std");
const json = @import("json");
const build_options = @import("build_options");

const Failure = struct {
    name: []const u8,
    detail: []const u8,
};

/// Decodes any JSON object: no fields of its own, and every member unknown.
const AnyObject = struct {
    pub fn jsonFormat() json.StructOptions {
        return .{ .skip_unknown_fields = true };
    }
};

/// Enough shapes to cover the suite. A `y_` case passes if any of them decodes
/// it; an `n_` case passes only if all of them refuse.
const candidates = .{
    []const []const u8,
    []const f64,
    []const i64,
    []const bool,
    []const ?i64,
    []const []const i64,
    []const AnyObject,
    []const u8,
    AnyObject,
    bool,
    f64,
    i64,
    ?u8,
};

/// True if any candidate type decodes `bytes` without error.
fn anyTypeDecodes(gpa: std.mem.Allocator, bytes: []const u8) bool {
    inline for (candidates) |T| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (json.decodeFromSliceLeaky(T, arena.allocator(), bytes)) |_| {
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
    var unmatched: std.ArrayList([]const u8) = .empty;

    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 24));
        const result = json.validateFromSlice(bytes);
        const typed = anyTypeDecodes(gpa, bytes);

        // The typed pass. For y_ a failure to match any candidate only means
        // the suite used a shape we did not list, so it is reported and not
        // counted against us. For n_ any success is a real defect.
        switch (name[0]) {
            'y' => if (typed) {
                typed_y += 1;
            } else {
                typed_y_unmatched += 1;
                try unmatched.append(gpa, name);
            },
            'n' => if (typed) {
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
        \\  y_ decoded:        {d} ({d} used a shape no candidate covers)
        \\  n_ refused by all: {d}/{d}
        \\
    , .{
        names.items.len, y_pass,  y_total,
        n_pass,          n_total, i_accepted,
        i_rejected,      typed_y, typed_y_unmatched,
        typed_n_pass,    n_total,
    });

    if (unmatched.items.len != 0) {
        // Not a defect: these are documents no static Zig type can express,
        // which is the trade this library makes by having no Value type.
        std.debug.print("\nno candidate type covers (heterogeneous shapes):\n", .{});
        for (unmatched.items) |n| std.debug.print("  {s}\n", .{n});
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
