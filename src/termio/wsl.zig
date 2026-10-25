//! Share terminal metadata with WSL without exporting Windows-only paths as
//! Linux paths. This also lets manually installed shell integration find the
//! resources that belong to the running Windows build.
const std = @import("std");
const EnvMap = std.process.Environ.Map;

pub fn setup(env: *EnvMap) !void {
    const variables = [_][2][]const u8{
        .{ "TERM_PROGRAM", "u" },
        .{ "TERM_PROGRAM_VERSION", "u" },
        .{ "GHOSTTY_RESOURCES_DIR", "up" },
        .{ "GHOSTTY_SHELL_FEATURES", "u" },
    };
    for (variables) |variable| {
        if (env.get(variable[0]) == null) continue;
        const current = env.get("WSLENV") orelse "";
        var entries = std.mem.splitScalar(u8, current, ':');
        const present = while (entries.next()) |entry| {
            const name = entry[0 .. std.mem.indexOfScalar(u8, entry, '/') orelse entry.len];
            if (std.mem.eql(u8, name, variable[0])) break true;
        } else false;
        if (present) continue;
        const updated = try std.fmt.allocPrint(env.allocator, "{s}{s}{s}/{s}", .{
            current, if (current.len == 0) "" else ":", variable[0], variable[1],
        });
        defer env.allocator.free(updated);
        try env.put("WSLENV", updated);
    }
}

test "WSL environment exports terminal metadata and translates resource path" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "ghostty");
    try env.put("TERM_PROGRAM_VERSION", "test");
    try env.put("GHOSTTY_RESOURCES_DIR", "C:\\Ghostty\\share\\ghostty");
    try env.put("GHOSTTY_SHELL_FEATURES", "cursor,title");
    try setup(&env);
    const expected = "TERM_PROGRAM/u:TERM_PROGRAM_VERSION/u:GHOSTTY_RESOURCES_DIR/up:GHOSTTY_SHELL_FEATURES/u";
    try std.testing.expectEqualStrings(expected, env.get("WSLENV").?);
    try setup(&env);
    try std.testing.expectEqualStrings(expected, env.get("WSLENV").?);
}

test "WSL environment preserves user exports and omits absent metadata" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WSLENV", "CUSTOM/lp:TERM_PROGRAM/u");
    try env.put("TERM_PROGRAM", "ghostty");
    try env.put("GHOSTTY_RESOURCES_DIR", "C:\\Ghostty\\share\\ghostty");
    try setup(&env);
    try std.testing.expectEqualStrings(
        "CUSTOM/lp:TERM_PROGRAM/u:GHOSTTY_RESOURCES_DIR/up",
        env.get("WSLENV").?,
    );
}
