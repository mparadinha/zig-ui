#version 330 core

#define BORDER_IDX_TOP    0u
#define BORDER_IDX_BOTTOM 1u
#define BORDER_IDX_LEFT   2u
#define BORDER_IDX_RIGHT  3u
#define BORDER_MASK_TOP    (1u << BORDER_IDX_TOP)
#define BORDER_MASK_BOTTOM (1u << BORDER_IDX_BOTTOM)
#define BORDER_MASK_LEFT   (1u << BORDER_IDX_LEFT)
#define BORDER_MASK_RIGHT  (1u << BORDER_IDX_RIGHT)
#define BORDER_MASK_ALL     0x0000000fu

layout (pixel_center_integer) in vec4 gl_FragCoord;

in GS_Out {
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
} fs_in;

uniform vec2 screen_size;
// TODO: merge these 3 into a single atlas
uniform sampler2D text_atlas;
uniform sampler2D text_bold_atlas;
uniform sampler2D icon_atlas;

out vec4 FragColor;

bool rectContains(vec2 rect_min, vec2 rect_max, vec2 point) {
    return rect_min.x <= point.x && point.x <= rect_max.x &&
           rect_min.y <= point.y && point.y <= rect_max.y;
}

float rectSDF(vec2 point, vec2 center, vec2 half_size) {
    point = abs(point - center);
    vec2 dist = point - half_size;
    float corner_dist = length(point - half_size);
    return dist.x > 0 && dist.y > 0 ? corner_dist : max(dist.x, dist.y);
}

float roundedRectSDF(vec2 point, vec2 center, vec2 half_size, vec4 corner_radii) {
    float corner_radius = corner_radii[
        (point.x > center.x ? 1 : 0) + (point.y < center.y ? 2 : 0)
    ];
    half_size -= vec2(corner_radius);
    float dist = rectSDF(point, center, half_size);
    dist -= corner_radius;
    return dist;
}

// `center`: distance from the edge to the center of the border
float toBorder(float dist, float center, float border_size) {
    return abs(dist - center) - border_size / 2;
}

uint currentBorders(vec2 pixel_coord, vec2 rect_center, vec2 rect_half_size, vec4 thickness) {
    vec2 rel_coord = pixel_coord - rect_center;
    uint border_mask = 0u;
    if (rel_coord.y >   rect_half_size.y - thickness[BORDER_IDX_TOP])     border_mask |= BORDER_MASK_TOP;
    if (rel_coord.y < -(rect_half_size.y - thickness[BORDER_IDX_BOTTOM])) border_mask |= BORDER_MASK_BOTTOM;
    if (rel_coord.x < -(rect_half_size.x - thickness[BORDER_IDX_LEFT]))   border_mask |= BORDER_MASK_LEFT;
    if (rel_coord.x >   rect_half_size.x - thickness[BORDER_IDX_RIGHT])   border_mask |= BORDER_MASK_RIGHT;
    return border_mask;
}
uint enabledBorders(vec4 borders_thickness) {
    uint border_mask = 0u;
    if (borders_thickness[BORDER_IDX_TOP]    >= 0) border_mask |= BORDER_MASK_TOP;
    if (borders_thickness[BORDER_IDX_BOTTOM] >= 0) border_mask |= BORDER_MASK_BOTTOM;
    if (borders_thickness[BORDER_IDX_LEFT]   >= 0) border_mask |= BORDER_MASK_LEFT;
    if (borders_thickness[BORDER_IDX_RIGHT]  >= 0) border_mask |= BORDER_MASK_RIGHT;
    return border_mask;
}
float selectThickness(uint borders, vec4 borders_thickness) {
    float thickness = -1;
    if ((borders & BORDER_MASK_TOP)    != 0u) thickness = max(thickness, borders_thickness[BORDER_IDX_TOP]);
    if ((borders & BORDER_MASK_BOTTOM) != 0u) thickness = max(thickness, borders_thickness[BORDER_IDX_BOTTOM]);
    if ((borders & BORDER_MASK_LEFT)   != 0u) thickness = max(thickness, borders_thickness[BORDER_IDX_LEFT]);
    if ((borders & BORDER_MASK_RIGHT)  != 0u) thickness = max(thickness, borders_thickness[BORDER_IDX_RIGHT]);
    return thickness;
}

void main() {
    vec2 pixel_coord = gl_FragCoord.xy;
    vec4 rect_color = fs_in.color;
    vec2 rect_half_size = fs_in.rect_size / 2;
    vec2 rect_center = fs_in.rect_center;
    vec4 corner_radii = fs_in.corner_radii;
    float softness = fs_in.edge_softness;
    vec4 borders_thickness = fs_in.border_thickness;

    uint enabled_borders = enabledBorders(borders_thickness);
    uint current_borders = currentBorders(pixel_coord, rect_center, rect_half_size, borders_thickness);
    float thickness = selectThickness(current_borders, borders_thickness);
    bool is_border_enabled = (current_borders & enabled_borders) != 0u;

    vec2 rect_min = rect_center - rect_half_size;
    vec2 rect_max = rect_center + rect_half_size;

    // 0 = fully outside, 1 = fully inside, ]0,1[ = rect border somewhere in this pixel
    float inside_rect_pct = 1 - clamp(rectSDF(pixel_coord, rect_center, rect_half_size), 0, 1);
    bool inside_clip_rect = rectContains(fs_in.clip_rect_min, fs_in.clip_rect_max, pixel_coord);
    bool has_rounded_corners = (corner_radii == vec4(0));
    bool has_borders = borders_thickness != vec4(-1);

    FragColor = vec4(0);

    // clipping
    if (!inside_clip_rect) { return; }

    if (has_borders && !is_border_enabled) {
        // TODO: fix enabling/disabling of borders when corners are rounded
        if (has_rounded_corners) {
            return;
        } else {
            thickness = borders_thickness[0];
        }
    }

    float rect_dist = roundedRectSDF(pixel_coord, rect_center, rect_half_size, corner_radii);
    if (thickness >= 0) rect_dist = toBorder(rect_dist, -(thickness / 2), thickness);

    vec4 color = rect_color;
    if (softness != 0) {
        color.a *= smoothstep(-softness, softness, -rect_dist);
    } else if (rect_dist > 0) {
        color.a = 0;
    }

    float tex_alpha = 1;
    switch (fs_in.which_font) {
        case 0u: tex_alpha = texture(text_atlas, fs_in.uv).r; break;
        case 1u: tex_alpha = texture(text_bold_atlas, fs_in.uv).r; break;
        case 2u: tex_alpha = texture(icon_atlas, fs_in.uv).r; break;
    }
    if (fs_in.uv != vec2(0, 0) && inside_rect_pct != 0) color.a = tex_alpha;

    FragColor = color;
}

