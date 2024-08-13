const std = @import("std");
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

pub fn StaticHashTable(
    comptime K: type,
    comptime V: type,
    comptime bucket_count: usize,
    comptime bucket_entries: usize,
) type {
    return struct {
        buckets: [bucket_count]Bucket = [_]Bucket{.{}} ** bucket_count,

        pub const Bucket = std.BoundedArray(Entry, bucket_entries);
        pub const Entry = struct { key: K, value: V, hash: u64 };

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

        pub fn getOrPut(self: *Self, key: K) !GOP {
            return self.getOrPutHash(key, hashFromKey(key));
        }

        pub fn getOrPutHash(self: *Self, key: K, hash: u64) !GOP {
            const bucket_idx = hash % self.buckets.len;
            const bucket = &self.buckets[bucket_idx];
            for (bucket.slice()) |*entry| {
                if (entry.hash == hash) return .{ .value = &entry.value, .found_existing = true };
            }
            try bucket.append(.{ .key = key, .value = undefined, .hash = hash });
            return .{ .value = &bucket.buffer[bucket.len - 1].value, .found_existing = false };
        }

        pub fn remove(self: *Self, key: K) void {
            const hash = Self.hashFromKey(key);
            const idx = self.indexFromHash(hash).?;
            _ = self.buckets[idx.bucket].swapRemove(idx.entry);
        }

        const EntryIdx = struct { bucket: usize, entry: usize };

        fn indexFromHash(self: *Self, hash: u64) ?EntryIdx {
            const bucket_idx = hash % self.buckets.len;
            const bucket = &self.buckets[bucket_idx];
            for (bucket.slice(), 0..) |entry, entry_idx| {
                if (entry.hash == hash) return .{ .bucket = bucket_idx, .entry = entry_idx };
            }
            return null;
        }

        pub const Iterator = struct {
            buckets: []Bucket,
            bucket_idx: usize = 0,
            entry_idx: usize = 0,

            pub const ItEntry = struct { key: *const K, value: *V, hash: u64 };

            pub fn next(self: *Iterator) ?ItEntry {
                if (self.bucket_idx >= self.buckets.len) return null;
                while (self.entry_idx >= self.buckets[self.bucket_idx].len) {
                    self.entry_idx = 0;
                    self.bucket_idx += 1;
                    if (self.bucket_idx >= self.buckets.len) return null;
                }

                const entry = &(self.buckets[self.bucket_idx].slice()[self.entry_idx]);
                self.entry_idx += 1;
                return .{ .key = &entry.key, .value = &entry.value, .hash = entry.hash };
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .buckets = &self.buckets };
        }
    };
}
