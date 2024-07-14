const zig_ui = @import("../zig_ui.zig");
const vec4 = zig_ui.vec4;
const uvec4 = zig_ui.uvec4;

pub fn colorFromRGB(r: u8, g: u8, b: u8) vec4 {
    return colorFromRGBA(r, g, b, 0xff);
}

pub fn colorFromRGBA(r: u8, g: u8, b: u8, a: u8) vec4 {
    return @as(vec4, @floatFromInt(uvec4{ r, g, b, a })) / @as(vec4, @splat(255));
}
