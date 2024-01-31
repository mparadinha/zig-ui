const std = @import("std");
const clamp = std.math.clamp;
const zig_ui = @import("../zig_ui.zig");
const vec2 = zig_ui.vec2;
const vec4 = zig_ui.vec4;
const UI = @import("UI.zig");
const Node = UI.Node;
const Axis = UI.Axis;

pub fn layoutTree(self: *UI, root: *Node) void {
    solveIndependentSizes(self, root);
    solveDownwardDependent(self, root);
    solveUpwardDependent(self, root);
    solveViolations(self, root);
    solveFinalPos(self, root);
}

fn solveIndependentSizes(self: *UI, node: *Node) void {
    const work_fn = solveIndependentSizesWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveDownwardDependent(self: *UI, node: *Node) void {
    const work_fn = solveDownwardDependentWorkFn;
    layoutRecurseHelperPost(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPost(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveUpwardDependent(self: *UI, node: *Node) void {
    const work_fn = solveUpwardDependentWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveViolations(self: *UI, node: *Node) void {
    const work_fn = solveViolationsWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveFinalPos(self: *UI, node: *Node) void {
    const work_fn = solveFinalPosWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveIndependentSizesWorkFn(self: *UI, node: *Node, axis: Axis) void {
    const axis_idx: usize = @intFromEnum(axis);
    switch (node.size[axis_idx]) {
        .pixels => |pixels| node.calc_size[axis_idx] = pixels.value,
        // this is wrong for percent (the correct one is calculated later) but this gives
        // and upper bound on the size, which might be needed for "downward dependent" nodes
        // which have children with `Size.percent`
        .percent,
        .text,
        => {
            const text_size = node.text_rect.size();
            const text_padding = self.textPadding(node)[axis_idx];
            node.calc_size[axis_idx] = text_size[axis_idx] + 2 * text_padding;
        },
        else => {},
    }
}

fn solveDownwardDependentWorkFn(self: *UI, node: *Node, axis: Axis) void {
    _ = self;

    const axis_idx: usize = @intFromEnum(axis);
    const is_layout_axis = (axis == node.layout_axis);

    const child_funcs = struct {
        pub fn sumChildrenSizes(parent: *Node, idx: usize) f32 {
            var sum: f32 = 0;
            var child = parent.first;
            while (child) |child_node| : (child = child_node.next) {
                sum += child_node.calc_size[idx];
            }
            return sum;
        }
        pub fn maxChildrenSizes(parent: *Node, idx: usize) f32 {
            var max_so_far: f32 = 0;
            var child = parent.first;
            while (child) |child_node| : (child = child_node.next) {
                const child_size = switch (child_node.size[idx]) {
                    .percent => blk: {
                        if (@intFromEnum(child_node.layout_axis) == idx) {
                            break :blk sumChildrenSizes(child_node, idx);
                        } else {
                            break :blk sumChildrenSizes(child_node, idx);
                        }
                    },
                    else => child_node.calc_size[idx],
                };
                max_so_far = @max(max_so_far, child_size);
            }
            return max_so_far;
        }
    };

    switch (node.size[axis_idx]) {
        .children => {
            if (is_layout_axis) {
                node.calc_size[axis_idx] = child_funcs.sumChildrenSizes(node, axis_idx);
            } else {
                node.calc_size[axis_idx] = child_funcs.maxChildrenSizes(node, axis_idx);
            }
            node.calc_size[axis_idx] += 2 * node.padding[axis_idx];
        },
        else => {},
    }
}

fn solveUpwardDependentWorkFn(self: *UI, node: *Node, axis: Axis) void {
    const axis_idx: usize = @intFromEnum(axis);
    switch (node.size[axis_idx]) {
        .percent => |percent| {
            const parent_size = if (node.parent) |p|
                p.calc_size - p.padding * vec2{ 2, 2 }
            else
                self.screen_size;
            node.calc_size[axis_idx] = parent_size[axis_idx] * percent.value;
        },
        else => {},
    }
}

fn solveViolationsWorkFn(self: *UI, node: *Node, axis: Axis) void {
    if (node.child_count == 0) return;

    const axis_idx: usize = @intFromEnum(axis);
    const is_layout_axis = (axis == node.layout_axis);
    const arena = self.build_arena.allocator();

    const available_size = node.calc_size - node.padding * vec2{ 2, 2 };

    // collect sizing information about children
    var total_children_size: f32 = 0;
    var max_child_size: f32 = 0;
    var zero_strict_take_budget: f32 = 0;
    var other_children_leeway: f32 = 0;
    var zero_strict_children = std.ArrayList(*Node).initCapacity(arena, node.child_count) catch
        @panic("too many children");
    var other_children = std.ArrayList(*Node).initCapacity(arena, node.child_count) catch
        @panic("too many children");
    var child = node.first;
    while (child) |child_node| : (child = child_node.next) {
        if (switch (axis) {
            .x => child_node.flags.floating_x,
            .y => child_node.flags.floating_y,
        }) continue;

        const strictness = child_node.size[axis_idx].getStrictness();
        const child_size = child_node.calc_size[axis_idx];

        total_children_size += child_size;
        max_child_size = @max(max_child_size, child_size);
        if (strictness == 0) {
            zero_strict_take_budget += child_size;
            zero_strict_children.append(child_node) catch unreachable;
        } else {
            other_children_leeway += (1 - strictness);
            other_children.append(child_node) catch unreachable;
        }
    }

    const total_size = if (is_layout_axis) total_children_size else max_child_size;
    var overflow = @max(0, total_size - available_size[axis_idx]);

    // shrink zero strictness children as much as we can (to 0 size if needed) before
    // trying to shrink other children with strictness > 0
    const zero_strict_remove_amount = @min(overflow, zero_strict_take_budget);
    for (zero_strict_children.items) |z_child| {
        if (is_layout_axis) {
            const z_child_percent = z_child.calc_size[axis_idx] / zero_strict_take_budget;
            z_child.calc_size[axis_idx] -= zero_strict_remove_amount * z_child_percent;
        } else {
            const extra_size = z_child.calc_size[axis_idx] - available_size[axis_idx];
            z_child.calc_size[axis_idx] -= @max(0, extra_size);
        }
    }
    overflow -= zero_strict_remove_amount;

    // if there's still overflow, shrink the other children as much as we can
    // (proportionally to their strictness values, i.e least strict shrinks the most)
    if (overflow > 0) {
        var removed_amount: f32 = 0;
        for (other_children.items) |child_node| {
            const strictness = child_node.size[axis_idx].getStrictness();
            if (strictness == 1) continue;
            const child_size = child_node.calc_size[axis_idx];
            const child_take_budget = child_size * strictness;
            const leeway_percent = (1 - strictness) / other_children_leeway;
            const desired_remove_amount = if (is_layout_axis)
                overflow * leeway_percent
            else
                @max(0, child_size - available_size[axis_idx]);
            const true_remove_amount = @min(child_take_budget, desired_remove_amount);
            child_node.calc_size[axis_idx] -= true_remove_amount;
            removed_amount += true_remove_amount;
        }
        overflow -= removed_amount;
        std.debug.assert(overflow >= 0); // if overflow is negative we removed too much somewhere
    }

    // constrain scrolling to children size, i.e. don't scroll more than is possible
    node.scroll_offset[axis_idx] = switch (axis) {
        .x => clamp(node.scroll_offset[axis_idx], -overflow, 0),
        .y => clamp(node.scroll_offset[axis_idx], 0, overflow),
    };
}

fn solveFinalPosWorkFn(self: *UI, node: *Node, axis: Axis) void {
    const axis_idx: usize = @intFromEnum(axis);
    const is_layout_axis = (axis == node.layout_axis);
    const is_scrollable_axis = switch (axis) {
        .x => node.flags.scroll_children_x,
        .y => node.flags.scroll_children_y,
    };

    // window root nodes need a position too!
    if (node.parent == null) {
        const calc_rel_pos = node.rel_pos.calcRelativePos(node.calc_size, self.screen_size);
        node.calc_rel_pos[axis_idx] = calc_rel_pos[axis_idx];
        node.rect.min[axis_idx] = node.calc_rel_pos[axis_idx];
        node.rect.max[axis_idx] = node.calc_rel_pos[axis_idx] + node.calc_size[axis_idx];
        node.clip_rect = node.rect;
    }

    if (node.child_count == 0) return;

    // start layout at the top left
    var start_rel_pos: f32 = switch (axis) {
        .x => node.padding[0],
        .y => node.calc_size[1] - node.padding[1],
    };
    // when `scroll_children` is enabled start layout at an offset
    if (is_scrollable_axis) start_rel_pos += node.scroll_offset[axis_idx];

    // position all the children
    var rel_pos: f32 = start_rel_pos;
    var child = node.first;
    while (child) |child_node| : (child = child_node.next) {
        const is_floating = switch (axis) {
            .x => child_node.flags.floating_x,
            .y => child_node.flags.floating_y,
        };
        if (is_floating) {
            const calc_rel_pos = child_node.rel_pos.calcRelativePos(child_node.calc_size, node.calc_size);
            child_node.calc_rel_pos[axis_idx] = calc_rel_pos[axis_idx];
            continue;
        }

        if (is_layout_axis) {
            const rel_pos_advance = child_node.calc_size[axis_idx];
            switch (axis) {
                .x => {
                    child_node.calc_rel_pos[axis_idx] = rel_pos;
                    rel_pos += rel_pos_advance;
                },
                .y => {
                    rel_pos -= rel_pos_advance;
                    child_node.calc_rel_pos[axis_idx] = rel_pos;
                },
            }
        } else {
            switch (axis) {
                .x => child_node.calc_rel_pos[axis_idx] = start_rel_pos,
                .y => child_node.calc_rel_pos[axis_idx] = start_rel_pos - child_node.calc_size[axis_idx],
            }
        }
    }

    // calculate the final screen pixel rect
    child = node.first;
    while (child) |child_node| : (child = child_node.next) {
        child_node.rect.min[axis_idx] = node.rect.min[axis_idx] + child_node.calc_rel_pos[axis_idx];
        child_node.rect.max[axis_idx] = child_node.rect.min[axis_idx] + child_node.calc_size[axis_idx];
        // propagate the clipping to children
        child_node.clip_rect = if (node.flags.clip_children) node.rect else node.clip_rect;
    }
}

const LayoutWorkFn = fn (*UI, *Node, Axis) void;
const LayoutWorkFnArgs = struct { self: *UI, node: *Node, axis: Axis };
/// do the work before recursing
fn layoutRecurseHelperPre(comptime work_fn: LayoutWorkFn, args: LayoutWorkFnArgs) void {
    work_fn(args.self, args.node, args.axis);
    var child = args.node.first;
    while (child) |child_node| : (child = child_node.next) {
        layoutRecurseHelperPre(work_fn, .{ .self = args.self, .node = child_node, .axis = args.axis });
    }
}
/// do the work after recursing
fn layoutRecurseHelperPost(comptime work_fn: LayoutWorkFn, args: LayoutWorkFnArgs) void {
    var child = args.node.first;
    while (child) |child_node| : (child = child_node.next) {
        layoutRecurseHelperPost(work_fn, .{ .self = args.self, .node = child_node, .axis = args.axis });
    }
    work_fn(args.self, args.node, args.axis);
}
