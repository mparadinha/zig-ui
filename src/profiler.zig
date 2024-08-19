const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root");

const zig_ui = @import("../zig_ui.zig");
const gl = zig_ui.gl;
const vec2 = zig_ui.vec2;
const vec4 = zig_ui.vec4;
const uvec2 = zig_ui.uvec2;
const UI = @import("UI.zig");
const utils = @import("utils.zig");
const sliceAsBytes = utils.sliceAsBytes;
const reduceSlice = utils.reduceSlice;
const binOpSlices = utils.binOpSlices;
const gfx = @import("graphics.zig");

pub const root_has_prof = @hasDecl(root, "prof") and @TypeOf(root.prof) == Profiler;
pub var dummy = DummyProfiler{};
const prof = if (root_has_prof) &root.prof else &dummy;

pub const DummyProfiler = struct {
    pub fn markFrame(_: *@This()) void {}
    pub fn startZoneN(_: *@This(), _: []const u8) void {}
    pub fn stopZone(_: *@This()) void {}

    pub const ZoneIterator = struct {
        pub fn next(_: *ZoneIterator) ?*Zone {
            return null;
        }
    };
    pub fn zoneIterator(_: *@This(), _: bool, _: bool) ZoneIterator {
        return .{};
    }
};

pub const Profiler = struct {
    zone_table: ZoneTable = .{},
    zone_stack: std.BoundedArray(*Zone, max_zone_nesting) = .{},
    frame_times: [Zone.number_of_samples]f32 = [_]f32{0} ** Zone.number_of_samples,
    frame_start: Zone.Timestamp = 0,
    frame_idx: usize = 0,
    self_zone: Zone = .{ .name = "Profiler", .color = defaultColor("Profiler") },

    display_cfg: DisplayConfig = .{},
    display_cfg_name_filter_buf: [100]u8 = undefined,
    display_cfg_init_done: bool = false,

    pub const DisplayConfig = struct {
        mode: Mode = .sample_time,
        max_y: f32 = 0,
        include_children: bool = true,
        name_filter: UI.TextInput = .{ .buffer = &.{}, .bufpos = 0, .cursor = 0, .mark = 0 },

        pub const Mode = enum { sample_time, call_count };

        pub const max_y_leeway_multiplier = 1.05;
    };

    const ZoneTable = utils.StaticHashTable([]const u8, Zone, bucket_count, bucket_entries);
    pub const bucket_count = 32;
    pub const bucket_entries = 5;
    pub const max_zone_nesting = 32;

    pub fn markFrame(self: *Profiler) void {
        // don't count start up as 1st frame
        if (self.frame_start == 0) {
            self.frame_start = Zone.timestamp();
            return;
        }

        const frame_slice_idx = (self.frame_idx % self.frame_times.len);

        var zone_iter = self.zoneIterator(true, true, true);
        while (zone_iter.next()) |zone| zone.commit(frame_slice_idx);

        const new_frame_start = Zone.timestamp();
        const elapsed_ns: f32 = @floatFromInt(new_frame_start - self.frame_start);
        self.frame_start = new_frame_start;

        self.frame_times[frame_slice_idx] = elapsed_ns / std.time.ns_per_s;
        self.frame_idx += 1;
    }

    fn defaultColor(name: []const u8) vec4 {
        const hash = ZoneTable.hashFromKey(name);
        return UI.colorFromRGB(
            @intCast((hash >> 0) & 0xff),
            @intCast((hash >> 8) & 0xff),
            @intCast((hash >> 16) & 0xff),
        );
    }

    pub fn startZoneN(self: *Profiler, comptime name: []const u8) void {
        self.self_zone.start();
        defer _ = self.self_zone.stop();

        const hash = comptime ZoneTable.hashFromKey(name);
        const gop = self.zone_table.getOrPutHash(hash) catch @panic("OOM");
        const zone = gop.value;
        if (!gop.found_existing) {
            zone.* = .{ .name = name, .color = comptime defaultColor(name) };
        }
        zone.start();
        self.zone_stack.append(zone) catch @panic("OOM");
    }

    pub fn stopZone(self: *Profiler) void {
        self.self_zone.start();
        defer _ = self.self_zone.stop();

        const zone = self.zone_stack.pop();
        const zone_time = zone.elapsed();
        if (zone.stop() and self.zone_stack.len > 0) {
            const parent = self.zone_stack.slice()[self.zone_stack.len - 1];
            parent.acc_child_sample += zone_time;
        }
    }

    pub const ZoneIterator = struct {
        profiler: *Profiler,
        include_profiler: bool,
        include_disabled: bool,
        include_hidden: bool,
        zone_it: ZoneTable.Iterator,
        returned_profiler_zone: bool = false,

        pub fn next(self: *ZoneIterator) ?*Zone {
            var next_zone: ?*Zone = null;
            while (next_zone == null) {
                if (self.include_profiler and !self.returned_profiler_zone) {
                    self.returned_profiler_zone = true;
                    next_zone = &self.profiler.self_zone;
                } else {
                    next_zone = if (self.zone_it.next()) |entry| entry.value else null;
                }
                if (next_zone) |zone| {
                    if ((!self.include_disabled and !zone.enabled) or
                        (!self.include_hidden and !zone.display))
                    {
                        next_zone = null; // try next zone
                    }
                } else break;
            }
            return next_zone;
        }
    };

    pub fn zoneIterator(
        self: *Profiler,
        include_profiler: bool,
        include_disabled: bool,
        include_hidden: bool,
    ) ZoneIterator {
        return .{
            .profiler = self,
            .include_profiler = include_profiler,
            .include_disabled = include_disabled,
            .include_hidden = include_hidden,
            .zone_it = self.zone_table.iterator(),
        };
    }
};

pub const Zone = struct {
    samples: [number_of_samples]f32 = [_]f32{0} ** number_of_samples,
    sample_counter: [number_of_samples]u32 = [_]u32{0} ** number_of_samples,
    child_samples: [number_of_samples]f32 = [_]f32{0} ** number_of_samples,

    start_timestamp: ?Timestamp = null,
    recursion_level: u8 = 0,
    acc_sample: Timestamp = 0,
    acc_counter: u32 = 0,
    acc_child_sample: Timestamp = 0,

    name: []const u8,
    color: vec4,
    display: bool = true,
    enabled: bool = true,

    pub const Timestamp = i128;
    // in testing locally I observed that `std.time.nanoTimestamp` took
    // around 38ns/call (20ns/call in release mode) while using `std.time.Timer`
    // took around 71ns/call (24ns/call in release mode)
    pub const timestamp = std.time.nanoTimestamp;

    const number_of_samples = 1024;

    pub fn start(self: *Zone) void {
        // for recursing functions we ignore the nested starts/stops
        if (self.start_timestamp) |_| {
            self.recursion_level += 1;
        } else {
            self.start_timestamp = timestamp();
        }
    }

    pub fn elapsed(self: *Zone) Timestamp {
        return timestamp() - self.start_timestamp.?;
    }

    /// Returns `false` when we are stopping inside a recursion
    pub fn stop(self: *Zone) bool {
        // for recursing functions we ignore the nested starts/stops time
        // but keep the call counter
        self.acc_counter += 1;
        if (self.recursion_level == 0) {
            self.acc_sample += self.elapsed();
            self.start_timestamp = null;
            return true;
        } else {
            self.recursion_level -= 1;
            return false;
        }
    }

    pub fn commit(self: *Zone, idx: usize) void {
        self.samples[idx] = @as(f32, @floatFromInt(self.acc_sample)) / std.time.ns_per_s;
        self.sample_counter[idx] = self.acc_counter;
        self.child_samples[idx] = @as(f32, @floatFromInt(self.acc_child_sample)) / std.time.ns_per_s;
        self.acc_sample = 0;
        self.acc_counter = 0;
        self.acc_child_sample = 0;
    }
};

// TODO: remove this
fn helperShowNodeTableHist(ui: *UI) void {
    prof.startZoneN("helperShowNodeTableHist");
    defer prof.stopZone();

    ui.pushStyle(.{ .font_size = 14 });
    defer _ = ui.popStyle();
    _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.children(1) }, .x);
    defer _ = ui.popParent();
    const max_bar_height = 100; // in px
    var max_count: usize = 0;
    for (ui.node_table.buckets) |bucket| {
        max_count = @max(max_count, bucket.count());
    }
    for (ui.node_table.buckets, 0..) |bucket, idx| {
        _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.children(1) }, .y);
        defer _ = ui.popParent();
        _ = ui.addNodeF(.{
            .draw_text = true,
            .draw_background = true,
            .draw_border = true,
            .no_id = true,
            .disable_text_truncation = true,
        }, "{:0>2}", .{idx}, .{
            .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) },
            .text_align = .center,
        });
        const count = bucket.count();
        _ = ui.addNodeF(.{
            .draw_text = true,
            .no_id = true,
            .disable_text_truncation = true,
        }, "{:0>2}", .{count}, .{
            .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) },
            .text_align = .center,
        });
        const bar_size = max_bar_height * @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(max_count));
        _ = ui.addNode(.{
            .draw_border = true,
            .draw_background = true,
            .no_id = true,
        }, "", .{ .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.pixels(bar_size, 1) } });
    }
}
const ColInfo = struct {
    name: []const u8,
    size: f32, // in pixels
};
fn showTableHeader(ui: *UI, cols: []ColInfo, sorted_col: *usize, reverse: *bool) void {
    ui.startLine();
    defer ui.endLine();
    for (cols, 0..) |col, col_idx| {
        var flags = UI.button_flags;
        flags.draw_text = false;
        flags.draw_background = false;
        const btn = ui.addNodeF(flags, "###{}_header", .{col_idx}, .{
            .size = [2]UI.Size{ UI.Size.pixels(col.size, 1), UI.Size.children(1) },
            .cursor_type = .pointing_hand,
            .layout_axis = .x,
        });
        {
            ui.pushParent(btn);
            ui.spacer(.x, UI.Size.percent(1, 0));
            ui.label(col.name);
            ui.spacer(.x, UI.Size.percent(1, 0));
            if (sorted_col.* == col_idx) {
                ui.iconLabel(if (reverse.*) UI.Icons.down_open else UI.Icons.up_open);
            }
            _ = ui.popParent();
        }
        if (btn.signal.clicked) {
            if (sorted_col.* == col_idx) reverse.* = !reverse.*;
            sorted_col.* = col_idx;
        }
    }
}
fn startColEntry(ui: *UI, cols: []ColInfo, col_idx: *usize) void {
    const col_entry_p = ui.addNode(.{
        .draw_border = true,
        .no_id = true,
    }, "", .{
        .size = [2]UI.Size{ UI.Size.pixels(cols[col_idx.*].size, 1), UI.Size.children(1) },
        .layout_axis = .x,
    });
    ui.pushParent(col_entry_p);
}
fn endColEntry(ui: *UI, _: []ColInfo, col_idx: *usize) void {
    _ = ui.popParent(); // col_entry_p
    col_idx.* += 1;
}
var zone_table_cols = [_]ColInfo{
    .{ .name = "zone", .size = 275 },
    .{ .name = "% of frame", .size = 125 },
    .{ .name = "ms/frame", .size = 100 },
    .{ .name = "calls/frame", .size = 125 },
    .{ .name = "μs/call", .size = 100 },
};
var zone_table_sorted_col: usize = 1;
var zone_table_sorted_col_reverse: bool = true;
fn helperShowZoneTable(ui: *UI, profiler: *Profiler) void {
    prof.startZoneN("helperShowZoneTable");
    defer prof.stopZone();

    _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.children(1), UI.Size.percent(1, 0) }, .y);
    defer _ = ui.popParent();

    const n_samples = @min(Zone.number_of_samples, profiler.frame_idx);
    const frame_times = profiler.frame_times[0..n_samples];

    const TableEntry = struct {
        zone: *Zone,
        avg_pct_of_frame: f32,
        avg_s_per_frame: f32,
        avg_calls_per_frame: f32,
        avg_s_per_call: f32,

        pub fn fromZone(zone: *Zone, frame_samples: []const f32, used_samples: usize, include_children: bool) @This() {
            std.debug.assert(used_samples == frame_samples.len);
            const samples = zone.samples[0..used_samples];
            const child_samples = zone.child_samples[0..used_samples];
            const sample_counter = zone.sample_counter[0..used_samples];
            const total_pct_of_frame: f32 = sum: {
                var tmp_buf: [Zone.number_of_samples]f32 = undefined;
                const tmp = tmp_buf[0..used_samples];
                @memcpy(tmp, samples);
                if (!include_children) binOpSlices(f32, .Sub, tmp, tmp, child_samples);
                binOpSlices(f32, .Div, tmp, tmp, frame_samples);
                break :sum reduceSlice(f32, .Add, tmp);
            };
            const total_time = if (include_children)
                reduceSlice(f32, .Add, samples)
            else
                reduceSlice(f32, .Add, samples) - reduceSlice(f32, .Add, child_samples);
            const total_calls: f32 = @floatFromInt(reduceSlice(u32, .Add, sample_counter));
            const total_s_per_call = sum: {
                var tmp_buf: [Zone.number_of_samples]f32 = undefined;
                const tmp = tmp_buf[0..used_samples];
                @memcpy(tmp, samples);
                if (!include_children) binOpSlices(f32, .Sub, tmp, tmp, child_samples);
                var tmp_counter_buf: [Zone.number_of_samples]f32 = undefined;
                const tmp_counter = tmp_counter_buf[0..used_samples];
                for (tmp_counter, 0..) |*v, idx| v.* = @floatFromInt(@max(sample_counter[idx], 1));
                binOpSlices(f32, .Div, tmp, tmp, tmp_counter);
                break :sum reduceSlice(f32, .Add, tmp);
            };
            const n_samples_f: f32 = @floatFromInt(used_samples);
            return .{
                .zone = zone,
                .avg_pct_of_frame = total_pct_of_frame / n_samples_f,
                .avg_s_per_frame = total_time / n_samples_f,
                .avg_calls_per_frame = total_calls / n_samples_f,
                .avg_s_per_call = total_s_per_call / n_samples_f,
            };
        }
    };
    const table_lines = blk: {
        const line_count = (Profiler.bucket_count * Profiler.bucket_entries) + 1;
        var array = std.BoundedArray(TableEntry, line_count){};

        var zone_it = profiler.zoneIterator(true, false, true);
        while (zone_it.next()) |zone| {
            array.append(TableEntry.fromZone(zone, frame_times, n_samples, profiler.display_cfg.include_children)) catch unreachable;
        }

        prof.startZoneN("sort table entries");
        const SortCtx = struct { sort_col_idx: usize, reverse: bool };
        std.sort.insertion(TableEntry, array.slice(), SortCtx{
            .sort_col_idx = zone_table_sorted_col,
            .reverse = zone_table_sorted_col_reverse,
        }, (struct {
            pub fn func(ctx: SortCtx, lhs: TableEntry, rhs: TableEntry) bool {
                const less_than = switch (ctx.sort_col_idx) {
                    0 => blk: {
                        var idx: usize = 0;
                        while (idx < @min(lhs.zone.name.len, rhs.zone.name.len)) : (idx += 1) {
                            if (lhs.zone.name[idx] != rhs.zone.name[idx])
                                break :blk lhs.zone.name[idx] < rhs.zone.name[idx];
                        }
                        break :blk false;
                    },
                    1 => lhs.avg_pct_of_frame < rhs.avg_pct_of_frame,
                    2 => lhs.avg_s_per_frame < rhs.avg_s_per_frame,
                    3 => lhs.avg_calls_per_frame < rhs.avg_calls_per_frame,
                    4 => lhs.avg_s_per_call < rhs.avg_s_per_call,
                    else => unreachable,
                };
                return if (ctx.reverse) !less_than else less_than;
            }
        }).func);
        prof.stopZone();

        break :blk array;
    };

    showTableHeader(ui, &zone_table_cols, &zone_table_sorted_col, &zone_table_sorted_col_reverse);

    const table_lines_p = ui.pushLayoutParent(.{
        .clip_children = true,
        .scroll_children_y = true,
    }, "table_lines_p", [2]UI.Size{ UI.Size.children(1), UI.Size.percent(1, 0) }, .y);
    defer ui.popParentAssert(table_lines_p);

    for (table_lines.slice(), 0..) |entry, zone_idx| {
        const zone = entry.zone;

        const name_filter = profiler.display_cfg.name_filter.slice();
        if (name_filter.len > 0 and !std.mem.startsWith(u8, zone.name, name_filter)) continue;

        ui.startLine();
        defer ui.endLine();
        var col_idx: usize = 0;
        { // 'zone' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);

            ui.spacer(.x, UI.Size.pixels(ui.text_padding[0], 1));

            // TODO: turn this into a button that opens a color picker
            _ = ui.addNode(.{
                .draw_background = true,
                .no_id = true,
                .floating_y = true,
            }, "", .{
                .size = UI.Size.exact(.em, 1, 1),
                .bg_color = zone.color,
                .rel_pos = UI.RelativePlacement.match(.center),
            });

            ui.spacer(.x, UI.Size.pixels(ui.text_padding[0] / 2, 1));

            ui.pushTmpStyle(.{ .font_size = 0.7 * ui.topStyle().font_size, .alignment = .center });
            _ = ui.checkBoxF("###{}_zone_display", .{zone_idx}, &zone.display);

            ui.pushTmpStyle(.{ .size = UI.Size.text2(0.5, 1) });
            if (ui.textF("{s}###{}_name", .{ zone.name, zone_idx }).hovering) {
                ui.startTooltip(null);
                ui.label(zone.name);
                ui.endTooltip();
            }

            ui.spacer(.x, UI.Size.percent(1, 0));

            ui.pushTmpStyle(.{ .font_size = 0.7 * ui.topStyle().font_size, .alignment = .center });
            _ = ui.checkBoxF("###{}_zone_enable", .{zone_idx}, &zone.enabled);

            ui.spacer(.x, UI.Size.pixels(ui.text_padding[0], 1));
        }
        { // '% of frame' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:2.1}", .{100 * entry.avg_pct_of_frame});
        }
        { // 'ms/frame' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:3.2}", .{entry.avg_s_per_frame * std.time.ms_per_s});
        }
        { // 'calls/frame' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:2.1}", .{entry.avg_calls_per_frame});
        }
        { // 'μs/call' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:.1}", .{entry.avg_s_per_call * std.time.us_per_s});
        }
    }
}

pub fn showProfilerInfo(ui: *UI, profiler: *Profiler) UI.Rect {
    const w = ui.startWindow("profiler_window", UI.Size.exact(.percent, 1, 1), UI.RelativePlacement.simple(vec2{ 0, 0 }));
    defer ui.endWindow(w);

    if (!profiler.display_cfg_init_done) {
        profiler.display_cfg.name_filter = UI.TextInput.init(&profiler.display_cfg_name_filter_buf, "");
        profiler.display_cfg_init_done = true;
    }

    if (ui.toggleButton("Node table histogram", false).toggled) {
        helperShowNodeTableHist(ui);
    }
    {
        ui.startLine();
        defer ui.endLine();
        {
            _ = ui.addParent(.{ .no_id = true }, "", .{
                .size = UI.Size.children2(1, 1),
                .inner_padding = vec2{ ui.text_padding[0], 0 },
                .layout_axis = .x,
            });
            defer _ = ui.popParent();
            ui.label("Filter zone by name:");
            _ = ui.lineInput("zone_name_filter", &profiler.display_cfg.name_filter, .{
                .size = UI.Size.em(15, 1),
                .default_str = "<zone name>",
            });
        }
        _ = ui.namedCheckBox("Include children in zone time", &profiler.display_cfg.include_children);
        for ([_]bool{ true, false }) |val| {
            if (ui.buttonF("{s} all zones", .{if (val) "Show" else "Hide"}).clicked) {
                var zone_it = profiler.zoneIterator(true, true, true);
                while (zone_it.next()) |zone| zone.display = val;
            }
        }
        for ([_]bool{ true, false }) |val| {
            if (ui.buttonF("{s} all zones", .{if (val) "Enable" else "Disable"}).clicked) {
                var zone_it = profiler.zoneIterator(true, true, true);
                while (zone_it.next()) |zone| zone.enabled = val;
            }
        }
        if (ui.button("Clear previous frames").clicked) {
            var zone_it = profiler.zoneIterator(true, true, true);
            while (zone_it.next()) |zone| {
                @memset(&zone.samples, 0);
                @memset(&zone.sample_counter, 0);
                @memset(&zone.child_samples, 0);
            }
        }
        {
            const other_mode: Profiler.DisplayConfig.Mode = switch (profiler.display_cfg.mode) {
                .sample_time => .call_count,
                .call_count => .sample_time,
            };
            if (ui.buttonF("Switch graph to {s}", .{switch (other_mode) {
                .sample_time => "sample time",
                .call_count => "call counter",
            }}).clicked)
                profiler.display_cfg.mode = other_mode;
        }
    }
    {
        _ = ui.pushLayoutParent(.{ .no_id = true }, "", UI.Size.flexible(.percent, 1, 1), .x);
        defer _ = ui.popParent();

        helperShowZoneTable(ui, profiler);

        const profiler_graph_node = ui.addNode(.{
            .draw_border = true,
        }, "profiler_graph_node", .{
            .size = UI.Size.flexible(.percent, 1, 1),
        });

        { // graph y-axis scale
            _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.children(1), UI.Size.percent(1, 0) }, .y);
            defer _ = ui.popParent();

            const order_of_mag = std.math.pow(f32, 10, @ceil(std.math.log10(@abs(profiler.display_cfg.max_y))));
            const min_divisions = 5;
            const max_divisions = 10;
            var step = (order_of_mag / 10);
            while (profiler.display_cfg.max_y / step < min_divisions + 2) step /= 2;
            while (profiler.display_cfg.max_y / step > max_divisions - 2) step *= 2;
            const graph_px_height = profiler_graph_node.rect.size()[1];
            var value: f32 = step;
            while (value < profiler.display_cfg.max_y) : (value += step) {
                const pct = value / profiler.display_cfg.max_y;
                const px_pos = pct * graph_px_height;
                const str = switch (profiler.display_cfg.mode) {
                    .sample_time => ui.fmtTmpString("{d:.0}ms", .{value * std.time.ms_per_s}),
                    .call_count => ui.fmtTmpString("{d}", .{value}),
                };
                _ = ui.addNode(.{
                    .draw_text = true,
                    .floating_y = true,
                    .no_id = true,
                }, str, .{
                    .rel_pos = UI.RelativePlacement.absolute(.{ .center = vec2{ 0, px_pos } }),
                });
            }
        }

        return profiler_graph_node.rect;
    }
}

pub fn renderProfilerGraph(
    allocator: Allocator,
    profiler: *Profiler,
    rect: UI.Rect,
    fbsize: uvec2,
    target_ms_per_frame: f32,
) !void {
    prof.startZoneN(@src().fn_name);
    defer prof.stopZone();
    // TODO: change UI render backend to operate on primitives (lines, dots, triangles, rects)
    // instead of only supporting our special rects

    // TODO: don't recreate this every time, save it as part of profiler maybe?
    const shader = try gfx.Shader.from_srcs(allocator, "profiler_graph", .{
        .vertex =
        \\#version 330 core
        \\in float sample;
        \\uniform bool sample_is_uint;
        \\uniform uint sample_count;
        \\uniform float max_y;
        \\uniform vec2 btmleft;
        \\uniform vec2 size;
        \\uniform vec2 screen_size;
        \\out float pass_value;
        \\void main() {
        \\    float value = sample_is_uint ? float(floatBitsToInt(sample)) : sample;
        \\    vec2 pos_graph = vec2(gl_VertexID / float(max(1, sample_count) - 1), value / max_y);
        \\    vec2 pos_px = (pos_graph * size) + btmleft;
        \\    vec2 pos = (pos_px / screen_size) * 2 - vec2(1);
        \\    gl_Position = vec4(pos, 0, 1);
        \\    pass_value = value;
        \\}
        ,
        .fragment =
        \\#version 330 core
        \\in float pass_value;
        \\uniform float max_y;
        \\uniform vec4 color;
        \\out vec4 FragColor;
        \\void main() {
        \\    if (pass_value > max_y) discard;
        \\    FragColor = color;
        \\}
        ,
    });
    defer shader.deinit();

    // auto-size graph
    {
        profiler.display_cfg.max_y = 0;
        var zone_it = profiler.zoneIterator(true, false, false);
        while (zone_it.next()) |zone| {
            const max_sample = switch (profiler.display_cfg.mode) {
                .sample_time => blk: {
                    if (profiler.display_cfg.include_children) {
                        break :blk reduceSlice(f32, .Max, &zone.samples);
                    } else {
                        var tmp: [Zone.number_of_samples]f32 = undefined;
                        binOpSlices(f32, .Sub, &tmp, &zone.samples, &zone.child_samples);
                        break :blk reduceSlice(f32, .Max, &tmp);
                    }
                },
                .call_count => blk: {
                    const max_sample = reduceSlice(u32, .Max, &zone.sample_counter);
                    break :blk @as(f32, @floatFromInt(max_sample));
                },
            };
            profiler.display_cfg.max_y = @max(profiler.display_cfg.max_y, max_sample * 1.05);
        }
    }

    shader.bind();
    shader.set("btmleft", rect.min);
    shader.set("size", rect.size());
    shader.set("screen_size", @as(vec2, @floatFromInt(fbsize)));
    shader.set("max_y", profiler.display_cfg.max_y);
    var zone_it = profiler.zoneIterator(true, false, false);
    while (zone_it.next()) |zone| {
        const n_samples = Zone.number_of_samples;
        // TODO: don't create these buffers every time. create/alloc once then just update data
        const vert_buf = gfx.VertexBuffer.init(&.{.{ .type = gl.FLOAT, .len = 1 }}, n_samples);
        defer vert_buf.deinit();
        switch (profiler.display_cfg.mode) {
            .sample_time => {
                if (profiler.display_cfg.include_children) {
                    vert_buf.update(sliceAsBytes(f32, &zone.samples));
                } else {
                    var tmp: [Zone.number_of_samples]f32 = undefined;
                    binOpSlices(f32, .Sub, &tmp, &zone.samples, &zone.child_samples);
                    vert_buf.update(sliceAsBytes(f32, &tmp));
                }
            },
            .call_count => {
                vert_buf.update(sliceAsBytes(u32, &zone.sample_counter));
            },
        }
        shader.set("sample_is_uint", profiler.display_cfg.mode == .call_count);
        shader.set("sample_count", @as(u32, @intCast(n_samples)));
        shader.set("color", zone.color);
        vert_buf.draw(gl.LINE_STRIP);
    }
    // draw 60fps line
    if (profiler.display_cfg.mode == .sample_time) {
        const samples = &[_]f32{ target_ms_per_frame, target_ms_per_frame };

        const vert_buf = gfx.VertexBuffer.init(&.{.{ .type = gl.FLOAT, .len = 1 }}, samples.len);
        defer vert_buf.deinit();
        vert_buf.update(sliceAsBytes(f32, samples));
        shader.set("sample_is_uint", false);
        shader.set("sample_count", @as(u32, @intCast(samples.len)));
        shader.set("color", vec4{ 0, 0.9, 0, 1 });
        vert_buf.draw(gl.LINE_STRIP);
    }
}
