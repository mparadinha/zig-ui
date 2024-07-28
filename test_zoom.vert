#version 330 core

layout (location = 0) in vec2 in_pos;

uniform vec2 total_size;
uniform vec2 region_size;
uniform vec2 region_btm_left;
uniform vec2 display_size;
uniform vec2 display_btm_left;

out vec2 pass_uv;

void main() {
    vec2 size = display_size / total_size;
    vec2 btm_left = display_btm_left / total_size;
    vec2 pos = (in_pos * size) + btm_left;
    gl_Position = vec4(2 * pos - vec2(1), 0, 1);

    vec2 uv_size = region_size / total_size;
    vec2 uv_btm_left = region_btm_left / total_size;
    pass_uv = (in_pos * uv_size) + uv_btm_left;
}
