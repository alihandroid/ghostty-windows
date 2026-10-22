//! WGL has no application-scoped device: each native surface owns its DC
//! and context. This implements the shared renderer device interface without
//! introducing an EGL dependency or sharing contexts across windows.
const Device = @This();
const Allocator = @import("std").mem.Allocator;

pub const Options = struct {};

pub fn init(alloc: Allocator, _: Options) !*Device {
    const self = try alloc.create(Device);
    self.* = .{};
    return self;
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    alloc.destroy(self);
}
