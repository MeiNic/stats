const std = @import("std");

var is_installed: ?bool = null;

pub fn isInstalled(gpa: std.mem.Allocator, io: std.Io) bool {
    if (is_installed) |v| {
        return v;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const run = std.process.run(arena.allocator(), io, .{
        .argv = &.{ "git", "--version" },
    }) catch {
        is_installed = false;
        return is_installed.?;
    };
    is_installed = switch (run.term) {
        .exited => |v| v == 0,
        else => false,
    };
    return is_installed.?;
}

pub fn currentCommit(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (!isInstalled(gpa, io)) return error.GitNotInstalled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const run = try std.process.run(arena.allocator(), io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
    });
    return try gpa.dupe(u8, run.stdout[0..8]);
}

/// Whether `email` is exactly (ignoring case) the address of one of the
/// `Co-authored-by:` trailer values in `coauthors` (separated by 0x03). Each
/// value looks like `Name <email>`; a bare `email` with no angle brackets is
/// also accepted.
fn hasCoauthor(coauthors: []const u8, email: []const u8) bool {
    var trailers = std.mem.splitScalar(u8, coauthors, '\x03');
    while (trailers.next()) |trailer| {
        const address = if (std.mem.lastIndexOfScalar(u8, trailer, '<')) |start|
            if (std.mem.indexOfScalarPos(u8, trailer, start, '>')) |end|
                trailer[start + 1 .. end]
            else
                trailer[start + 1 ..]
        else
            std.mem.trim(u8, trailer, " \t\r");
        if (std.ascii.eqlIgnoreCase(address, email)) return true;
    }
    return false;
}

test hasCoauthor {
    const trailers = "Bob <bob@x.com>\x03Alice <ba@x.com>";
    try std.testing.expect(hasCoauthor(trailers, "bob@x.com"));
    try std.testing.expect(hasCoauthor(trailers, "ba@x.com"));
    try std.testing.expect(!hasCoauthor(trailers, "a@x.com"));
    try std.testing.expect(!hasCoauthor(trailers, "bob@x.co"));
    try std.testing.expect(hasCoauthor(trailers, "BOB@X.com"));
    try std.testing.expect(hasCoauthor("bare@x.com", "bare@x.com"));
    try std.testing.expect(!hasCoauthor("", "bob@x.com"));
}

pub fn getLinesChanged(
    gpa: std.mem.Allocator,
    io: std.Io,
    login: []const u8,
    token: []const u8,
    repo: []const u8,
    emails: []const []const u8,
    count_coauthored: bool,
) !u32 {
    if (!isInstalled(gpa, io)) return error.GitNotInstalled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const repo_path = try std.mem.replaceOwned(u8, allocator, repo, "/", "_");
    const repo_url = try std.fmt.allocPrint(
        allocator,
        "https://{s}:{s}@github.com/{s}.git",
        .{ login, token, repo },
    );
    const clone = try std.process.run(allocator, io, .{
        .argv = &.{
            "git",
            "clone",
            "--bare",
            "--filter=blob:limit=1m",
            "--no-tags",
            "--single-branch",
            repo_url,
            repo_path,
        },
    });
    switch (clone.term) {
        .exited => |v| if (v != 0) return error.CloneFailed,
        else => return error.CloneFailed,
    }
    defer std.Io.Dir.cwd().deleteTree(io, repo_path) catch {};

    // Rather than filter with `git log --author`, which only matches the
    // commit's `Author:` header, emit one header line per commit (marked by
    // 0x01) carrying the author email and any `Co-authored-by:` trailers,
    // followed by that commit's `--numstat` output. This lets us match by
    // email in-process, so commits where the user is only recorded as a
    // co-author (e.g. squash-merged PRs, which GitHub authors to the PR
    // owner) can be counted when `count_coauthored` is set. Fields are
    // separated by 0x02, individual co-authors by 0x03.
    const log_args = &[_][]const u8{
        "git",
        "-C",
        repo_path,
        "log",
        "--numstat",
        "--pretty=tformat:\x01%ae\x02" ++
            "%(trailers:key=Co-authored-by,valueonly,separator=\x03)",
    };
    const log = try std.process.run(allocator, io, .{ .argv = log_args });
    switch (log.term) {
        .exited => |v| if (v != 0) return error.LogFailed,
        else => return error.LogFailed,
    }

    var lines_changed: u32 = 0;
    var matches = false;
    var lines = std.mem.splitScalar(u8, log.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '\x01') {
            const header = line[1..];
            const sep = std.mem.indexOfScalar(u8, header, '\x02') orelse
                header.len;
            const author = header[0..sep];
            const coauthors =
                if (sep < header.len) header[sep + 1 ..] else "";
            matches = false;
            for (emails) |email| {
                if (std.ascii.eqlIgnoreCase(author, email) or
                    (count_coauthored and hasCoauthor(coauthors, email)))
                {
                    matches = true;
                    break;
                }
            }
            continue;
        }
        if (!matches) continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const additions =
            std.fmt.parseUnsigned(u32, parts.next() orelse "0", 10) catch 0;
        const deletions =
            std.fmt.parseUnsigned(u32, parts.next() orelse "0", 10) catch 0;
        lines_changed += additions + deletions;
    }
    return lines_changed;
}
