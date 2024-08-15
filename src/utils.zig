const std = @import("std");
const Allocator = std.mem.Allocator;
const zig_ui = @import("../zig_ui.zig");
const vec4 = zig_ui.vec4;
const uvec4 = zig_ui.uvec4;

const prof = &@import("root").prof;

pub fn colorFromRGB(r: u8, g: u8, b: u8) vec4 {
    return colorFromRGBA(r, g, b, 0xff);
}

pub fn colorFromRGBA(r: u8, g: u8, b: u8, a: u8) vec4 {
    return @as(vec4, @floatFromInt(uvec4{ r, g, b, a })) / @as(vec4, @splat(255));
}

pub fn reduceSlice(comptime T: type, comptime op: std.builtin.ReduceOp, values: []const T) T {
    prof.startZoneN("reduceSlice(" ++ @typeName(T) ++ ", ." ++ @tagName(op) ++ ")");
    defer prof.stopZone();

    const Len = std.simd.suggestVectorLength(T) orelse 1;
    const V = @Vector(Len, T);

    var result: T = switch (op) {
        .And => ~0,
        .Or => 0,
        .Xor => @panic("TODO"),
        .Min => switch (@typeInfo(T)) {
            .Int => std.math.maxInt(T),
            .Float => std.math.floatMax(T),
            else => |todo| @panic("TODO: " ++ @tagName(todo)),
        },
        .Max => switch (@typeInfo(T)) {
            .Int => std.math.minInt(T),
            .Float => std.math.floatMin(T),
            else => |todo| @panic("TODO: " ++ @tagName(todo)),
        },
        .Add => 0,
        .Mul => 1,
    };

    var idx: usize = 0;
    while (idx + Len < values.len) {
        const vec_result = @reduce(op, @as(V, values[idx..][0..Len].*));
        result = @reduce(op, @Vector(2, T){ result, vec_result });
        idx += Len;
    }
    for (values[idx..]) |v| result = @reduce(op, @Vector(2, T){ result, v });

    return result;
}

pub const BinOp = enum { Add, Sub, Mul, Div };
pub fn binOpSlices(comptime T: type, comptime op: BinOp, dst: []T, lhs: []const T, rhs: []const T) void {
    std.debug.assert(dst.len == lhs.len and dst.len == rhs.len);

    const Len = std.simd.suggestVectorLength(T) orelse 1;
    const V = @Vector(Len, T);

    var idx: usize = 0;
    while (idx + Len < dst.len) {
        const vec_lhs: V = lhs[idx..][0..Len].*;
        const vec_rhs: V = rhs[idx..][0..Len].*;
        const vec_result = switch (op) {
            .Add => vec_lhs + vec_rhs,
            .Sub => vec_lhs - vec_rhs,
            .Mul => vec_lhs * vec_rhs,
            .Div => vec_lhs / vec_rhs,
        };
        dst[idx..][0..Len].* = vec_result;
        idx += Len;
    }
    for (dst[idx..]) |*v| v.* = switch (op) {
        .Add => lhs[idx] + rhs[idx],
        .Sub => lhs[idx] - rhs[idx],
        .Mul => lhs[idx] * rhs[idx],
        .Div => lhs[idx] / rhs[idx],
    };
}

/// note: Not all objects are guaranteed to have unique memory representations.
/// Some examples are:
/// - floats (there's multiple bit patterns for NaN, inf., +0 vs -0, etc.)
/// - non packed structs (padding byte values are undefined)
/// This hash table will treats those as if they where distinct values.
pub fn StaticHashTable(
    comptime K: type,
    comptime V: type,
    comptime initial_bucket_count: usize,
    comptime bucket_entries: usize,
) type {
    return struct {
        buckets: BucketList = .{
            .prealloc_segment = [_]Bucket{.{}} ** initial_bucket_count,
            .len = initial_bucket_count,
        },

        pub const Entry = struct { hash: u64, value: V };
        pub const Bucket = std.BoundedArray(Entry, bucket_entries);
        pub const BucketList = std.SegmentedList(Bucket, initial_bucket_count);

        const Self = @This();

        pub fn hashFromKey(key: K) u64 {
            return if (K == []const u8)
                std.hash.Wyhash.hash(0, key)
            else
                std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        }

        pub const GOP = struct {
            value: *V,
            found_existing: bool,
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.buckets.deinit(allocator);
        }

        pub fn getOrPut(self: *Self, key: K) !GOP {
            return self.getOrPutHash(hashFromKey(key));
        }

        pub fn getOrPutHash(self: *Self, hash: u64) !GOP {
            const bucket_idx = hash % self.buckets.len;
            const bucket: *Bucket = self.buckets.at(bucket_idx);
            for (bucket.slice()) |*entry| {
                if (entry.hash == hash) return .{ .value = &entry.value, .found_existing = true };
            }
            try bucket.append(.{ .hash = hash, .value = undefined });
            return .{ .value = &bucket.buffer[bucket.len - 1].value, .found_existing = false };
        }

        pub fn remove(self: *Self, key: K) void {
            const hash = hashFromKey(key);
            return self.removeHash(hash);
        }

        pub fn removeHash(self: *Self, hash: u64) void {
            const bucket_idx = hash % self.buckets.len;
            const bucket: *Bucket = self.buckets.at(bucket_idx);
            for (bucket.slice(), 0..) |entry, entry_idx| {
                if (entry.hash == hash) _ = bucket.swapRemove(entry_idx);
            }
        }

        pub fn grow(self: *Self, allocator: Allocator) !void {
            // allocate new segment in list
            const old_cap = self.buckets.len;
            const new_cap = old_cap * 2;
            try self.buckets.growCapacity(allocator, new_cap);

            // init new buckets
            self.buckets.len = new_cap;
            for (old_cap..new_cap) |idx| self.buckets.at(idx).* = .{};

            // re-organize values to new buckets
            for (0..old_cap) |bucket_idx| {
                const bucket: *Bucket = self.buckets.at(bucket_idx);
                var entry_idx: usize = 0;
                while (entry_idx < bucket.len) {
                    const hash = bucket.slice()[entry_idx].hash;
                    const new_bucket_idx = hash % self.buckets.len;
                    if (new_bucket_idx != bucket_idx) {
                        const entry = bucket.swapRemove(entry_idx);
                        try self.buckets.at(new_bucket_idx).append(entry);
                        continue;
                    }
                    entry_idx += 1;
                }
            }
        }

        pub const Iterator = struct {
            table: *Self,
            bucket_idx: usize = 0,
            entry_idx: usize = 0,

            pub const ItEntry = struct { hash: u64, value: *V };

            pub fn next(self: *Iterator) ?ItEntry {
                if (self.bucket_idx >= self.table.buckets.len) return null;
                while (self.entry_idx >= self.table.buckets.at(self.bucket_idx).len) {
                    self.entry_idx = 0;
                    self.bucket_idx += 1;
                    if (self.bucket_idx >= self.table.buckets.len) return null;
                }

                const entry = &self.table.buckets.at(self.bucket_idx).slice()[self.entry_idx];
                self.entry_idx += 1;
                return .{ .hash = entry.hash, .value = &entry.value };
            }

            /// Undo a call to `next`.
            pub fn back(self: *Iterator) void {
                while (self.entry_idx == 0) {
                    self.bucket_idx -= 1;
                    self.entry_idx = self.table.buckets.at(self.bucket_idx).len;
                }
                self.entry_idx -= 1;
            }

            /// Remove the last entry returned by `next` from the table.
            /// Use this instead of doing this removal 'manually' while
            /// iterating which might lead to skipping of elements.
            pub fn remove(self: *Iterator) void {
                self.back();
                const bucket: *Bucket = self.table.buckets.at(self.bucket_idx);
                _ = bucket.swapRemove(self.entry_idx);
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self };
        }
    };
}

/// wrapper for `std.unicode.utf8ValidateSlice` with early-out
/// optimization for slices that only contains ASCII
// TODO: fully implement this using SIMD, theres a bunch of papers online on how to do that
pub fn utf8Validate(str: []const u8) bool {
    prof.startZoneN("utf8Validate");
    defer prof.stopZone();

    const vec_size = comptime std.simd.suggestVectorLength(u8) orelse 64 / 8;
    const V = @Vector(vec_size, u8);
    // TODO: make this better
    var chunk_start: usize = 0;
    while (chunk_start < str.len) {
        const rest_of_str = str[chunk_start..];

        // TODO: we can prob. fill this in a smarted way without if/else, just a single @max
        const chunk: V = if (rest_of_str.len < vec_size) chunk: {
            var chunk: V = @splat(0);
            for (rest_of_str, 0..) |char, idx| chunk[idx] = char;
            break :chunk chunk;
        } else str[chunk_start..][0..vec_size].*;

        const topbit: V = @splat(0x80);
        _ = topbit;

        const any_non_ascii = @reduce(.Or, chunk & @as(V, @splat(0x80)) != @as(V, @splat(0)));
        if (any_non_ascii) {
            break;
        } else {
            chunk_start += vec_size;
        }
    }

    if (chunk_start > str.len) {
        return true;
    } else {
        return std.unicode.utf8ValidateSlice(str[chunk_start..]);
    }
}

pub const Utf8Iterator = struct {
    bytes: []const u8,
    idx: usize = 0,
    ascii_until: ?usize = null,

    pub fn next(self: *Utf8Iterator) ?u21 {
        if (self.idx >= self.bytes.len) return null;

        if (self.ascii_until) |idx| {
            if (self.idx < idx) {
                defer self.idx += 1;
                return self.bytes[self.idx];
            }
        }

        const Vlen = 32;
        const V = @Vector(Vlen, u8);

        const bytes_left = self.bytes[self.idx..];
        const byte_count = @min(bytes_left.len, Vlen);
        var bytes = [_]u8{0} ** Vlen;
        @memcpy(bytes[0..byte_count], bytes_left[0..byte_count]);

        const non_ascii = @as(V, bytes) & @as(V, @splat(0b1000_0000)) != @as(V, @splat(0));
        const first_non_ascii_idx: usize = std.simd.firstTrue(non_ascii) orelse 32;

        if (first_non_ascii_idx > 0) {
            self.ascii_until = self.idx + first_non_ascii_idx;
            return self.next();
        } else {
            return self.decodeNext() catch std.unicode.replacement_character;
        }
    }

    fn decodeNext(self: *Utf8Iterator) !?u21 {
        const bytes = if (self.idx < self.bytes.len) self.bytes[self.idx..] else return null;

        // TODO: make this better with SIMD?
        const codepoint_len = try std.unicode.utf8ByteSequenceLength(bytes[0]);
        self.idx += codepoint_len;
        const codepoint_bytes = if (bytes.len < codepoint_len) return error.InvalidUtf8 else bytes[0..codepoint_len];
        return switch (codepoint_len) {
            1 => codepoint_bytes[0],
            2 => try std.unicode.utf8Decode2(codepoint_bytes),
            3 => try std.unicode.utf8Decode3(codepoint_bytes),
            4 => try std.unicode.utf8Decode4(codepoint_bytes),
            else => unreachable,
        };
    }

    pub fn peek(self: *Utf8Iterator) ?u21 {
        const saved = self.*;
        defer self.* = saved;
        return self.next();
    }
};
