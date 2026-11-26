// Lite shaders. Compiled at launch from source (no offline `metal` compiler with the CLT).
//
// Everything is drawn as instanced quads: the vertex shader is called 4 times per
// instance (a triangle strip of 2 triangles), and picks the quad corner from
// `vertex_id`. Per-instance data comes from a plain buffer indexed by `instance_id`,
// so no vertex descriptors are needed. Positions are in *pixels*, top-left origin;
// the vertex shader converts to Metal's clip space (-1…1, y up).
//
// Struct layouts must match `RectInstance` / `GlyphInstance` in Instances.swift.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewportSize; // drawable size in pixels
};

struct RectInstance {
    short2 origin;  // px
    short2 size;    // px
    uint   color;   // 0xRRGGBBAA, straight (non-premultiplied) alpha
};

struct GlyphInstance {
    short2  origin;    // px, top-left of the glyph bitmap on screen
    ushort2 size;      // px
    ushort2 atlasPos;  // px, top-left of the glyph in its atlas page
    uint    color;     // 0xRRGGBBAA, used for grayscale glyphs
    uint    flags;     // bit 0: colour glyph (sample the RGBA page)
};

constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

static float4 unpack_color(uint c) {
    return float4((c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF) / 255.0;
}

static float4 to_clip(float2 px, float2 viewport) {
    float2 ndc = px / viewport * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

// MARK: - Solid rectangles (cell backgrounds, cursor, underlines, overlay panel)

struct RectOut {
    float4 position [[position]];
    float4 color;
};

vertex RectOut rect_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           const device RectInstance *instances [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    RectInstance r = instances[iid];
    float2 p = float2(r.origin) + corners[vid] * float2(r.size);
    float4 c = unpack_color(r.color);
    RectOut out;
    out.position = to_clip(p, u.viewportSize);
    out.color = float4(c.rgb * c.a, c.a); // premultiply for blending
    return out;
}

fragment float4 rect_fragment(RectOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Glyphs from the atlas

struct GlyphOut {
    float4 position [[position]];
    float2 atlasCoord; // in atlas pixels
    float4 color;
    uint   flags [[flat]];
};

vertex GlyphOut glyph_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device GlyphInstance *instances [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    GlyphInstance g = instances[iid];
    float2 corner = corners[vid];
    GlyphOut out;
    out.position = to_clip(float2(g.origin) + corner * float2(g.size), u.viewportSize);
    out.atlasCoord = float2(g.atlasPos) + corner * float2(g.size);
    out.color = unpack_color(g.color);
    out.flags = g.flags;
    return out;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                               texture2d<float> grayAtlas [[texture(0)]],
                               texture2d<float> colorAtlas [[texture(1)]]) {
    // Glyph quads are pixel-aligned and the same size as their bitmap, so nearest
    // sampling in pixel coordinates copies texels 1:1 (no blur).
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    if (in.flags & 1u) {
        return colorAtlas.sample(s, in.atlasCoord); // already premultiplied RGBA (emoji)
    }
    // Grayscale page stores coverage (how much of the pixel the glyph covers).
    float coverage = grayAtlas.sample(s, in.atlasCoord).r;
    float a = in.color.a * coverage;
    return float4(in.color.rgb * a, a);
}
