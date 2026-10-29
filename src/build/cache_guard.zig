//! Serialize cache maintenance and its following build. Process enumeration is
//! an additional check for Zig invocations that do not use the build wrapper.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Guard = struct {
    file: Io.File,

    pub fn release(self: *Guard, io: Io) void {
        // Windows can delay releasing a lock after closing its handle.
        self.file.unlock(io);
        self.file.close(io);
        self.* = undefined;
    }
};

/// Hold this guard until the real Zig build exits. Never remove the lock file:
/// other wrappers may already be waiting for a lock on the same file.
pub fn acquire(io: Io, repo_dir: Io.Dir) !Guard {
    return .{ .file = try repo_dir.createFile(io, ".zig-cache.lock", .{
        .truncate = false,
        .lock = .exclusive,
    }) };
}

/// Errors mean maintenance must be skipped. The wrapper's Zig invocation and
/// any Zig processes in its ancestry are excluded from the result.
pub fn isOtherZigRunning(io: Io, allocator: Allocator) !bool {
    var processes: std.ArrayList(Process) = .empty;
    defer processes.deinit(allocator);
    const self_pid: u32 = switch (builtin.os.tag) {
        .linux => blk: {
            try enumerateLinux(io, allocator, &processes);
            break :blk @intCast(std.os.linux.getpid());
        },
        .windows => blk: {
            try enumerateWindows(allocator, &processes);
            break :blk std.os.windows.GetCurrentProcessId();
        },
        else => return error.ProcessEnumerationUnsupported,
    };
    return containsOtherZig(allocator, processes.items, self_pid);
}

const Process = struct {
    pid: u32,
    parent: u32,
    is_zig: bool,
};

fn containsOtherZig(allocator: Allocator, processes: []const Process, self_pid: u32) !bool {
    var ancestors: std.ArrayList(u32) = .empty;
    defer ancestors.deinit(allocator);
    var pid = self_pid;
    while (pid != 0) {
        if (std.mem.containsAtLeastScalar(u32, ancestors.items, pid, 1))
            return error.InvalidProcessAncestry;
        try ancestors.append(allocator, pid);
        const process = for (processes) |process| {
            if (process.pid == pid) break process;
        } else {
            if (pid == self_pid) return error.IncompleteProcessSnapshot;
            // Windows retains the parent's PID after it exits. Unknown earlier
            // ancestors remain unexcluded, so a surviving Zig ancestor causes
            // a conservative skip rather than allowing maintenance to proceed.
            break;
        };
        pid = process.parent;
    }
    for (processes) |process| {
        if (process.is_zig and
            !std.mem.containsAtLeastScalar(u32, ancestors.items, process.pid, 1)) return true;
    }
    return false;
}

fn enumerateLinux(io: Io, allocator: Allocator, processes: *std.ArrayList(Process)) !void {
    var proc = try Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var iterator = proc.iterate();
    while (try iterator.next(io)) |entry| {
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{d}/status", .{pid});
        const file = proc.openFile(io, path, .{}) catch |err| switch (err) {
            // A process can exit while the snapshot is being collected.
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io);
        // procfs reports zero-length files; read the stream rather than its stat size.
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const status = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
        defer allocator.free(status);
        try processes.append(allocator, try parseLinuxStatus(pid, status));
    }
}

fn parseLinuxStatus(pid: u32, status: []const u8) !Process {
    var name: ?[]const u8 = null;
    var parent: ?u32 = null;
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.cutPrefix(u8, line, "Name:")) |value| {
            name = std.mem.trim(u8, value, " \t\r");
        } else if (std.mem.cutPrefix(u8, line, "PPid:")) |value| {
            parent = try std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r"), 10);
        }
    }
    return .{
        .pid = pid,
        .parent = parent orelse return error.InvalidProcessStatus,
        .is_zig = std.mem.eql(u8, name orelse return error.InvalidProcessStatus, "zig"),
    };
}

const windows = std.os.windows;
const ProcessEntry = extern struct {
    size: windows.DWORD = @sizeOf(ProcessEntry),
    usage: windows.DWORD = 0,
    pid: windows.DWORD = 0,
    heap_id: windows.ULONG_PTR = 0,
    module_id: windows.DWORD = 0,
    threads: windows.DWORD = 0,
    parent: windows.DWORD = 0,
    priority: windows.LONG = 0,
    flags: windows.DWORD = 0,
    executable: [windows.MAX_PATH]windows.WCHAR = @splat(0),
};

extern "kernel32" fn CreateToolhelp32Snapshot(flags: windows.DWORD, pid: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn Process32FirstW(snapshot: windows.HANDLE, process: *ProcessEntry) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Process32NextW(snapshot: windows.HANDLE, process: *ProcessEntry) callconv(.winapi) windows.BOOL;

fn enumerateWindows(allocator: Allocator, processes: *std.ArrayList(Process)) !void {
    const snapshot = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
    if (snapshot == windows.INVALID_HANDLE_VALUE) return error.ProcessSnapshotFailed;
    defer windows.CloseHandle(snapshot);
    var process: ProcessEntry = .{};
    if (!Process32FirstW(snapshot, &process).toBool()) return error.ProcessSnapshotFailed;
    while (true) {
        const length = std.mem.findScalar(u16, &process.executable, 0) orelse
            return error.InvalidProcessExecutable;
        try processes.append(allocator, .{
            .pid = process.pid,
            .parent = process.parent,
            .is_zig = isWindowsZig(process.executable[0..length]),
        });
        if (Process32NextW(snapshot, &process).toBool()) continue;
        if (windows.GetLastError() != .NO_MORE_FILES) return error.ProcessSnapshotFailed;
        break;
    }
}

fn isWindowsZig(name: []const u16) bool {
    const expected = "zig.exe";
    if (name.len != expected.len) return false;
    for (name, expected) |actual, want| {
        if (actual > 127 or std.ascii.toLower(@intCast(actual)) != want) return false;
    }
    return true;
}

test "cache guard excludes its own Zig ancestors but detects another Zig" {
    const allocator = std.testing.allocator;
    var processes = [_]Process{
        .{ .pid = 1, .parent = 0, .is_zig = false },
        .{ .pid = 10, .parent = 1, .is_zig = true },
        .{ .pid = 11, .parent = 10, .is_zig = true },
        .{ .pid = 20, .parent = 1, .is_zig = false },
    };
    try std.testing.expect(!try containsOtherZig(allocator, &processes, 11));
    processes[3].is_zig = true;
    try std.testing.expect(try containsOtherZig(allocator, &processes, 11));
}

test "cache guard refuses incomplete or cyclic process ancestry" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.IncompleteProcessSnapshot, containsOtherZig(allocator, &.{}, 11));
    try std.testing.expectError(error.InvalidProcessAncestry, containsOtherZig(allocator, &.{
        .{ .pid = 11, .parent = 10, .is_zig = false },
        .{ .pid = 10, .parent = 11, .is_zig = true },
    }, 11));
}

test "cache guard stops ancestry at an exited parent" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try containsOtherZig(allocator, &.{
        .{ .pid = 11, .parent = 10, .is_zig = false },
    }, 11));
    try std.testing.expect(try containsOtherZig(allocator, &.{
        .{ .pid = 11, .parent = 10, .is_zig = false },
        .{ .pid = 9, .parent = 1, .is_zig = true },
    }, 11));
}

test "cache guard parses Linux process names and parents" {
    const process = try parseLinuxStatus(42, "Name:\tzig\nState:\tS (sleeping)\nPPid:\t12\n");
    try std.testing.expectEqual(@as(u32, 42), process.pid);
    try std.testing.expectEqual(@as(u32, 12), process.parent);
    try std.testing.expect(process.is_zig);
    try std.testing.expectError(error.InvalidProcessStatus, parseLinuxStatus(42, "Name:\tzig\n"));
}

test "cache guard recognizes Windows compiler names without matching other programs" {
    try std.testing.expect(isWindowsZig(std.unicode.utf8ToUtf16LeStringLiteral("Zig.EXE")));
    try std.testing.expect(!isWindowsZig(std.unicode.utf8ToUtf16LeStringLiteral("ziggy.exe")));
}

test "cache guard can enumerate the host process snapshot" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    _ = try isOtherZigRunning(std.testing.io, std.testing.allocator);
}

test "cache guard holds an exclusive lock until release" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var guard = try acquire(io, tmp.dir);
    const competing = tmp.dir.createFile(io, ".zig-cache.lock", .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    if (competing) |file| {
        file.close(io);
        guard.release(io);
        return error.ExpectedLockContention;
    } else |err| {
        try std.testing.expectEqual(error.WouldBlock, err);
    }
    guard.release(io);
    var second = try acquire(io, tmp.dir);
    second.release(io);
}
