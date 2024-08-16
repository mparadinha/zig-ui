const std = @import("std");
const Allocator = std.mem.Allocator;
const zig_ui = @import("../zig_ui.zig");
const gl = zig_ui.gl;
const vec2 = zig_ui.vec2;
const vec3 = zig_ui.vec3;
const vec4 = zig_ui.vec4;

/// Generic GPU geometry buffer.
pub const VertexBuffer = struct {
    vao: u32,
    // TODO: multiple VBO with one attribute per VBO instead all attribs in one
    vbo: u32,
    // TODO: support index/element buffer
    elem_size: usize,
    n_elems: usize,
    // TODO: support keeping around a (CPU side) copy of the GPU data inside
    // this data structure instead of outside of it; may be helpfull in some cases.

    pub const Attrib = struct {
        /// gl.FLOAT, etc.
        type: gl.GLenum,
        /// e.g. len=2 for vec2
        len: usize,

        pub fn size(self: Attrib) usize {
            return sizeOfGLType(self.type) * self.len;
        }

        pub fn fromType(comptime T: type) Attrib {
            return switch (@typeInfo(T)) {
                .Float => |float| switch (float.bits) {
                    32 => .{ .type = gl.FLOAT, .len = 1 },
                    64 => .{ .type = gl.DOUBLE, .len = 1 },
                    else => @compileError(@typeName(T) ++ " not supported."),
                },
                .Int => |int| .{
                    .type = switch (int.signedness) {
                        .signed => switch (int.bits) {
                            8 => gl.BYTE,
                            16 => gl.SHORT,
                            32 => gl.INT,
                            else => @compileError(@typeName(T) ++ " not supported."),
                        },
                        .unsigned => switch (int.bits) {
                            8 => gl.UNSIGNED_BYTE,
                            16 => gl.UNSIGNED_SHORT,
                            32 => gl.UNSIGNED_INT,
                            else => @compileError(@typeName(T) ++ " not supported."),
                        },
                    },
                    .len = 1,
                },
                .Array => |array| blk: {
                    const child = Attrib.fromType(array.child);
                    break :blk .{ .type = child.type, .len = array.len };
                },
                else => @compileError(@typeName(T) ++ " not supported."),
            };
        }
    };

    /// Initialize and allocate GPU side buffer
    pub fn init(
        attribs: []const Attrib,
        n_elems: usize,
        // TODO: support multiple vbos?
    ) VertexBuffer {
        const elem_size = blk: {
            var sum: usize = 0;
            // TODO: don't assume element attribs are tighly packed?
            for (attribs) |attrib| sum += attrib.size();
            break :blk sum;
        };

        var vao: u32 = 0;
        gl.genVertexArrays(1, &vao);
        gl.bindVertexArray(vao);

        var vbo: u32 = 0;
        gl.genBuffers(1, &vbo);
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        var offset: usize = 0;
        for (attribs, 0..) |attrib, i| {
            const index: u32 = @intCast(i);
            const attrib_offset: ?*const anyopaque = if (offset == 0) null else @ptrFromInt(offset);
            // TODO: don't assume elements are tighly packed?
            switch (attrib.type) {
                gl.FLOAT => gl.vertexAttribPointer(index, @intCast(attrib.len), attrib.type, gl.FALSE, @intCast(elem_size), attrib_offset),
                gl.DOUBLE => gl.vertexAttribLPointer(index, @intCast(attrib.len), attrib.type, @intCast(elem_size), attrib_offset),
                gl.BYTE,
                gl.SHORT,
                gl.INT,
                gl.UNSIGNED_BYTE,
                gl.UNSIGNED_SHORT,
                gl.UNSIGNED_INT,
                => gl.vertexAttribIPointer(index, @intCast(attrib.len), attrib.type, @intCast(elem_size), attrib_offset),
                else => |gl_type| std.debug.panic("{}", .{gl_type}),
            }
            gl.enableVertexAttribArray(index);
            // TODO: don't assume element attribs are tighly packed?
            offset += attrib.size();
        }
        // TODO: support gl.STATIC_DRAW as well
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(n_elems * elem_size), null, gl.DYNAMIC_DRAW);

        return .{
            .vao = vao,
            .vbo = vbo,
            .elem_size = elem_size,
            .n_elems = n_elems,
        };
    }

    pub fn deinit(self: VertexBuffer) void {
        gl.deleteBuffers(1, &self.vbo);
        gl.deleteVertexArrays(1, &self.vao);
    }

    /// Update buffer data, sync with GPU
    pub fn update(self: VertexBuffer, data: []const u8) void {
        std.debug.assert(data.len == self.elem_size * self.n_elems);
        // TODO: support gl.STATIC_DRAW as well
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(data.len), @ptrCast(data.ptr), gl.DYNAMIC_DRAW);
    }

    pub fn draw(
        self: VertexBuffer,
        /// gl.LINE_STRIP, gl.TRIANGLES, etc.
        mode: gl.GLenum,
    ) void {
        gl.bindVertexArray(self.vao);
        gl.drawArrays(mode, 0, @intCast(self.n_elems));
    }

    fn sizeOfGLType(gl_type: gl.GLenum) usize {
        return switch (gl_type) {
            gl.UNSIGNED_BYTE => @sizeOf(u8),
            gl.UNSIGNED_SHORT => @sizeOf(u16),
            gl.UNSIGNED_INT => @sizeOf(u32),
            gl.FLOAT => @sizeOf(f32),
            gl.DOUBLE => @sizeOf(f64),
            else => |todo| std.debug.panic("'type: gl.GLenum = {}' not suppported", .{todo}),
        };
    }
};

pub const Texture = struct {
    id: u32, // sometimes also called the 'name' of the texture
    width: u32,
    height: u32,
    tex_type: u32, // TEXTURE_2D, etc.
    format: u32, // RED, RGB, etc.

    // notes about textures in OpenGL:
    // - 'texture' objects just hold state about the texture (size, sampler type, format, etc.)
    // - 'image' functions change the underlying image data, not the state
    // https://stackoverflow.com/questions/8866904/differences-and-relationship-between-glactivetexture-and-glbindtexture

    pub const Param = struct { name: u32, value: u32 };

    pub fn init(width: u32, height: u32, format: u32, data: ?[]const u8, tex_type: u32, params: []const Param) Texture {
        var self = Texture{
            .id = undefined,
            .width = width,
            .height = height,
            .tex_type = tex_type,
            .format = format,
        };

        gl.genTextures(1, &self.id);
        gl.bindTexture(tex_type, self.id);
        for (params) |param| gl.texParameteri(tex_type, param.name, @as(i32, @intCast(param.value)));
        self.updateData(data);
        gl.generateMipmap(tex_type);

        return self;
    }

    pub fn updateData(self: Texture, data: ?[]const u8) void {
        gl.bindTexture(self.tex_type, self.id);
        // zig fmt: off
        gl.texImage2D(
            self.tex_type, 0, @intCast(self.format),
            @intCast(self.width), @intCast(self.height), 0,
            self.format, gl.UNSIGNED_BYTE,
            if (data) |ptr| @ptrCast(&ptr[0]) else null,
        );
        // zig fmt: on
    }

    pub fn deinit(self: Texture) void {
        gl.deleteTextures(1, &self.id);
    }

    pub fn bind(self: Texture, texture_unit: u32) void {
        gl.activeTexture(gl.TEXTURE0 + texture_unit);
        gl.bindTexture(self.tex_type, self.id);
    }
};

pub const Shader = struct {
    vert_id: u32,
    geom_id: ?u32 = null,
    frag_id: u32,
    prog_id: u32,
    name: []u8,
    allocator: Allocator,

    const Self = @This();

    const src_dir = "shaders";

    const ShaderType = enum { vertex, geometry, fragment };

    /// call `deinit` to cleanup
    pub fn from_srcs(
        allocator: Allocator,
        name: []const u8,
        srcs: struct {
            vertex: []const u8,
            geometry: ?[]const u8 = null,
            fragment: []const u8,
        },
    ) !Shader {
        var shader = Shader{
            .vert_id = 0,
            .frag_id = 0,
            .prog_id = 0,
            .name = allocator.dupe(u8, name) catch unreachable,
            .allocator = allocator,
        };
        errdefer allocator.free(shader.name);

        shader.vert_id = try shader.compile_src(srcs.vertex, .vertex);
        if (srcs.geometry) |src| shader.geom_id = try shader.compile_src(src, .geometry);
        shader.frag_id = try shader.compile_src(srcs.fragment, .fragment);

        const shader_ids = if (shader.geom_id) |geom_id|
            &[_]u32{ shader.vert_id, geom_id, shader.frag_id }
        else
            &[_]u32{ shader.vert_id, shader.frag_id };
        try shader.link(shader_ids);

        return shader;
    }

    /// call `deinit` to cleanup
    pub fn from_files(
        allocator: Allocator,
        name: []const u8,
        src_paths: struct {
            vertex: []const u8,
            geometry: ?[]const u8 = null,
            fragment: []const u8,
        },
    ) !Shader {
        const vert_src = try readFile(allocator, src_paths.vertex);
        defer allocator.free(vert_src);
        const geom_src = if (src_paths.geometry) |path| try readFile(allocator, path) else null;
        defer if (geom_src) |src| allocator.free(src);
        const frag_src = try readFile(allocator, src_paths.fragment);
        defer allocator.free(frag_src);
        return Shader.from_srcs(allocator, name, .{
            .vertex = vert_src,
            .geometry = geom_src,
            .fragment = frag_src,
        });
    }
    fn readFile(allocator: Allocator, path: []const u8) ![]const u8 {
        return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    }

    pub fn deinit(self: Shader) void {
        self.allocator.free(self.name);

        gl.detachShader(self.prog_id, self.vert_id);
        if (self.geom_id) |id| gl.detachShader(self.prog_id, id);
        gl.detachShader(self.prog_id, self.frag_id);

        gl.deleteShader(self.vert_id);
        if (self.geom_id) |id| gl.deleteShader(id);
        gl.deleteShader(self.frag_id);
        gl.deleteProgram(self.prog_id);
    }

    fn compile_src(self: *Shader, src: []const u8, shader_type: ShaderType) !u32 {
        if (src.len == 0) return error.EmptySource;

        const gl_shader_type: u32 = switch (shader_type) {
            .vertex => gl.VERTEX_SHADER,
            .geometry => gl.GEOMETRY_SHADER,
            .fragment => gl.FRAGMENT_SHADER,
        };
        const id: u32 = gl.createShader(gl_shader_type);
        gl.shaderSource(id, 1, &(&src[0]), &(@as(c_int, @intCast(src.len))));
        gl.compileShader(id);

        // check compilation errors
        var success: i32 = 0;
        gl.getShaderiv(id, gl.COMPILE_STATUS, &success);
        if (success == gl.FALSE) {
            var msg_buf: [0x1000]u8 = undefined;
            gl.getShaderInfoLog(id, 0x1000, null, &msg_buf[0]);
            std.log.info("{s} (type={s}) compile error:\n{s}", .{
                self.name,
                @tagName(shader_type),
                @as([*c]u8, &msg_buf[0]),
            });
            return error.FailedShaderCompile;
        }

        return id;
    }

    fn link(self: *Shader, ids: []const u32) !void {
        self.prog_id = gl.createProgram();
        for (ids) |shader_id| gl.attachShader(self.prog_id, shader_id);

        gl.linkProgram(self.prog_id);

        // check for linking errors
        var success: i32 = 0;
        gl.getProgramiv(self.prog_id, gl.LINK_STATUS, &success);
        if (success == gl.FALSE) {
            var msg_buf: [0x1000]u8 = undefined;
            gl.getProgramInfoLog(self.prog_id, 0x1000, null, &msg_buf[0]);
            std.log.info("{s} link error: {s}", .{ self.name, @as([*c]u8, &msg_buf[0]) });
            return error.FailedShaderLink;
        }
    }

    pub fn bind(self: Shader) void {
        gl.useProgram(self.prog_id);
    }

    pub fn uniform(self: Shader, name: []const u8) i32 {
        const loc = gl.getUniformLocation(self.prog_id, &name[0]);
        if (loc == -1) std.log.err("error getting uniform '{s}' from shader '{s}'", .{ name, self.name });
        // if (loc == -1) std.debug.panic("error getting uniform '{s}' from shader '{s}'", .{ name, self.name });
        return loc;
    }

    pub fn set(self: Shader, name: []const u8, obj: anytype) void {
        const obj_type = @TypeOf(obj);
        const loc = self.uniform(name);
        switch (obj_type) {
            i32 => gl.uniform1i(loc, obj),
            u32 => gl.uniform1ui(loc, obj),
            f32 => gl.uniform1f(loc, obj),
            bool => gl.uniform1ui(loc, @intFromBool(obj)),
            vec2 => gl.uniform2fv(loc, 1, &obj[0]),
            vec3 => gl.uniform3fv(loc, 1, &obj[0]),
            vec4 => gl.uniform4fv(loc, 1, &obj[0]),

            else => @compileError("need to implement Shader.set for type " ++ @typeName(obj_type)),
        }
    }
};
