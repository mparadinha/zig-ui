#version 330 core

layout (points) in;
layout (triangle_strip, max_vertices = 6) out;

uniform vec2 screen_size;

in VS_Out {
    vec2 btm_left_pos;
    vec2 top_right_pos;

    vec2 btm_left_uv;
    vec2 top_right_uv;

    vec4 top_left_color;
    vec4 btm_left_color;
    vec4 top_right_color;
    vec4 btm_right_color;

    vec4 corner_radii;

    float edge_softness;
    vec4 border_thickness;

    vec2 clip_rect_min;
    vec2 clip_rect_max;

    uint which_font;
} gs_in[];

out GS_Out {
    vec2 uv;
    vec4 color;
    flat vec2 rect_size;
    flat vec2 rect_center;
    flat vec4 corner_radii;
    flat float edge_softness;
    flat vec4 border_thickness;
    flat vec2 clip_rect_min;
    flat vec2 clip_rect_max;
    flat uint which_font;
} gs_out;

void main() {
    vec2 btm_left_pos = gs_in[0].btm_left_pos;
    vec2 top_right_pos = gs_in[0].top_right_pos;
    vec2 btm_right_pos = vec2(top_right_pos.x, btm_left_pos.y);
    vec2 top_left_pos = vec2(btm_left_pos.x, top_right_pos.y);

    vec2 btm_left_uv = gs_in[0].btm_left_uv;
    vec2 top_right_uv = gs_in[0].top_right_uv;
    vec2 btm_right_uv = vec2(top_right_uv.x, btm_left_uv.y);
    vec2 top_left_uv = vec2(btm_left_uv.x, top_right_uv.y);

    // some things are the same for all verts of the quad
    gs_out.rect_size = top_right_pos - btm_left_pos;
    gs_out.rect_center = (btm_left_pos + top_right_pos) / 2;
    gs_out.corner_radii = gs_in[0].corner_radii;
    gs_out.edge_softness = gs_in[0].edge_softness;
    gs_out.border_thickness = gs_in[0].border_thickness;
    gs_out.clip_rect_min = gs_in[0].clip_rect_min;
    gs_out.clip_rect_max = gs_in[0].clip_rect_max;
    gs_out.which_font = gs_in[0].which_font;

    // sometimes rects get cut off 1px short on the right side, I'm not sure why
    // (I think it's related to when rect/quad borders are not centered on a pixel)
    // so just make the quad 1px bigger to the right so that extra pixel gets
    // computed/rasterized and the rects don't get cut off
    float extra_px_x = ceil(btm_right_pos.x) - btm_right_pos.x;
    if (extra_px_x == 0) extra_px_x = 1;
    btm_right_pos.x += extra_px_x;
    top_right_pos.x += extra_px_x;
    // fix UVs after expanding quad to the right
    vec2 uv_per_px = (top_right_uv - btm_left_uv) / gs_out.rect_size;
    btm_right_uv.x += extra_px_x * uv_per_px.x;
    top_right_uv.x += extra_px_x * uv_per_px.x;
    // and sometimes the same problem happens upwards instead of to the right
    float extra_px_y = (ceil(top_right_pos.y) + 0.49) - top_right_pos.y;
    if (extra_px_y == 0) extra_px_y = 1;
    top_left_pos.y  += extra_px_y;
    top_right_pos.y += extra_px_y;
    // fix uv after adding this 1px to the right
    top_left_uv.y  += extra_px_y * uv_per_px.y;
    top_right_uv.y += extra_px_y * uv_per_px.y;

    gl_Position  = vec4((btm_left_pos / screen_size) * 2 - vec2(1), 0, 1);
    gs_out.uv    = btm_left_uv;
    gs_out.color = gs_in[0].btm_left_color;
    EmitVertex();
    gl_Position  = vec4((btm_right_pos / screen_size) * 2 - vec2(1), 0, 1);
    gs_out.uv    = btm_right_uv;
    gs_out.color = gs_in[0].btm_right_color;
    EmitVertex();
    gl_Position  = vec4((top_right_pos / screen_size) * 2 - vec2(1), 0, 1);
    gs_out.uv    = top_right_uv;
    gs_out.color = gs_in[0].top_right_color;
    EmitVertex();
    EndPrimitive();

    gl_Position  = vec4((btm_left_pos / screen_size) * 2 - vec2(1), 0, 1);
    gs_out.uv    = btm_left_uv;
    gs_out.color = gs_in[0].btm_left_color;
    EmitVertex();
    gl_Position  = vec4((top_right_pos / screen_size) * 2 - vec2(1), 0, 1);
    gs_out.uv    = top_right_uv;
    gs_out.color = gs_in[0].top_right_color;
    EmitVertex();
    gl_Position  = vec4((top_left_pos / screen_size) * 2 - vec2(1), 0, 1);
    gs_out.uv    = top_left_uv;
    gs_out.color = gs_in[0].top_left_color;
    EmitVertex();
    EndPrimitive();
}
