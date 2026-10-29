//! Warn about local build cache growth on every development build. This tool
//! only reads file metadata; cache files may be changing in parallel with it.
const std = @import("std");

const limit_bytes: u64 = 20 * 1024 * 1024 * 1024;

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return;
    if (args.len != 2) return;

    // Cache maintenance must not prevent development when directories disappear
    // during a build or filesystem permissions prevent measuring them.
    check(init.io, init.gpa, args[1]) catch {};
}

fn check(io: std.Io, allocator: std.mem.Allocator, cache_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, cache_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const file = entry.dir.statFile(io, entry.basename, .{
            .follow_symlinks = false,
        }) catch continue;
        if (file.kind != .file) continue;
        total +|= file.size;
        if (total > limit_bytes) {
            std.debug.print(
                "Build cache files exceed 20 GiB ({s}). Review stale artifacts; see README.md#build-cache.\n",
                .{cache_path},
            );
            return;
        }
    }
}
