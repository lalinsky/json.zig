//! Runs JSONTestSuite (github.com/nst/JSONTestSuite) against `json.validate`.
//!
//! The suite names each case by its expected outcome:
//!
//!   y_*  must be accepted
//!   n_*  must be rejected
//!   i_*  implementation-defined; behaviour is reported, nothing is asserted
//!
//! Validation is the right entry point for it: the suite feeds documents of
//! arbitrary shape, so there is no destination type to decode into, and
//! `validate` exercises the same scanner, string, number and nesting code the
//! typed decoder uses.

const std = @import("std");
const json = @import("json");
const build_options = @import("build_options");

const Failure = struct {
    name: []const u8,
    detail: []const u8,
};

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
    var i_accepted: usize = 0;
    var i_rejected: usize = 0;
    var failures: std.ArrayList(Failure) = .empty;

    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 24));
        const result = json.validateFromSlice(bytes);

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
        \\
    , .{ names.items.len, y_pass, y_total, n_pass, n_total, i_accepted, i_rejected });

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
