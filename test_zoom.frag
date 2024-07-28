#version 330 core

in vec2 pass_uv;

uniform sampler2D img;

out vec4 color;

void main() {
    color = vec4(texture(img, pass_uv).rgb, 1);
}
