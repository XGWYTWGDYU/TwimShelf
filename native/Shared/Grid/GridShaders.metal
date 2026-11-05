#include <metal_stdlib>
using namespace metal;

// The media grid (GridRenderer.swift): every tile is a rounded quad with an antialiased edge
// (research/MetalGridZoom), showing its thumbnail plus the app's badges.

// Must match `GridTileInstance` in GridRenderer.swift (stride 64).
struct GridTileInstance {
    float2 origin;      // points
    float  side;        // points
    float  alpha;
    uint   flags;       // bit0 has picture, bit1 video, bit2 selected
    uint   count;       // media in the post (badge when > 1)
    float2 pad;
    float4 radii;       // tl, tr, br, bl (points)
    float4 placeholder; // colour while the picture is not decoded, sRGB-encoded
};

struct GridUniforms {
    float2 viewSize;    // points
    float  scale;       // pixels per point
    float  pad;
};

struct GridVOut {
    float4 position [[position]];
    float2 local;       // points, 0…side
    float  side [[flat]];
    float  alpha [[flat]];
    uint   flags [[flat]];
    uint   count [[flat]];
    float4 radii [[flat]];
    float4 placeholder [[flat]];
};

vertex GridVOut gridTileVertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device GridTileInstance *tiles [[buffer(0)]],
                               constant GridUniforms &u [[buffer(1)]]) {
    const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    GridTileInstance t = tiles[iid];
    float2 c = corners[vid];
    float pad = 1.0 / u.scale;          // room for the antialiased edge
    float2 local = c * (t.side + 2 * pad) - pad;
    float2 p = t.origin + local;
    GridVOut o;
    o.position = float4(p.x / u.viewSize.x * 2 - 1, 1 - p.y / u.viewSize.y * 2, 0, 1);
    o.local = local;
    o.side = t.side;
    o.alpha = t.alpha;
    o.flags = t.flags;
    o.count = t.count;
    o.radii = t.radii;
    o.placeholder = t.placeholder;
    return o;
}

static float gridRoundedRectSDF(float2 p, float side, float4 r) {
    float2 h = float2(side * 0.5);
    float2 q = p - h;
    float rad = q.x < 0 ? (q.y < 0 ? r.x : r.w) : (q.y < 0 ? r.y : r.z);
    float2 d = abs(q) - h + rad;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rad;
}

static float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

static float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

/// Signed distance (negative inside) to a triangle, by its three edges.
static float triangleSDF(float2 q, float2 a, float2 b, float2 c) {
    float2 v[3] = { a, b, c };
    float o = sign(cross2(b - a, c - a));
    float m = -1e9;
    for (int i = 0; i < 3; i++) {
        float2 e = v[(i + 1) % 3] - v[i];
        m = max(m, -o * cross2(e, q - v[i]) / length(e));
    }
    return m;
}

/// Coverage (0…1) of a shape whose signed distance in points is d.
static float cover(float d, float scale) { return clamp(0.5 - d * scale, 0.0, 1.0); }

fragment float4 gridTileFragment(GridVOut in [[stage_in]],
                                 texture2d<float> picture [[texture(0)]],
                                 texture2d<float> digits [[texture(1)]],
                                 constant GridUniforms &u [[buffer(1)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float d = gridRoundedRectSDF(in.local, in.side, in.radii);
    float coverage = cover(d, u.scale);
    if (coverage <= 0) discard_fragment();
    float s = in.side;
    float2 p = in.local;
    float3 rgb = (in.flags & 1u) ? picture.sample(smp, clamp(p / s, 0.0, 1.0)).rgb : in.placeholder.rgb;

    // a video: a small play triangle bottom left (with a soft shadow), on tiles of 40 pt and up
    if ((in.flags & 2u) && s >= 40) {
        float2 q = p - float2(6, s - 18);                       // 12×12 box
        float tri = triangleSDF(q, float2(1.5, 0), float2(1.5, 12), float2(12, 6));
        rgb = mix(rgb, float3(0), cover(tri - 1.0, u.scale * 0.35) * 0.35);
        rgb = mix(rgb, float3(1), cover(tri, u.scale));
    }

    // a post of several media: their number bottom right, on tiles of 50 pt and up
    if (in.count > 1 && s >= 50) {
        uint n = in.count;
        uint nd = n < 10 ? 1 : n < 100 ? 2 : n < 1000 ? 3 : 4;
        float dh = 13.0, dw = dh * 0.56;
        float2 box = float2(p.x - (s - 6 - dw * float(nd)), p.y - (s - 6 - dh));
        if (box.x >= 0 && box.y >= 0 && box.x < dw * float(nd) && box.y < dh) {
            uint j = uint(box.x / dw);
            uint pw = 1; for (uint k = 0; k + 1 + j < nd; k++) pw *= 10;
            uint digit = (n / pw) % 10;
            float2 g = float2((float(digit) + fract(box.x / dw)) / 10.0, box.y / dh);
            float lod = max(0.0, log2(256.0 / max(dh * u.scale, 1.0)));
            float shadow = digits.sample(smp, g - float2(0.002, -0.03), level(lod)).r;
            float glyph = digits.sample(smp, g, level(lod)).r;
            rgb = mix(rgb, float3(0), shadow * 0.45);
            rgb = mix(rgb, float3(1), glyph);
        }
    }

    // selected: a light veil and a blue check circle top right
    if (in.flags & 4u) {
        rgb = mix(rgb, float3(1), 0.25);
        float2 cc = float2(s - 16, 16);
        float r = length(p - cc);
        rgb = mix(rgb, float3(0), cover(r - 12.5, u.scale * 0.4) * 0.3);
        rgb = mix(rgb, float3(1), cover(r - 11.0, u.scale));
        rgb = mix(rgb, float3(0.0, 0.48, 1.0), cover(r - 9.5, u.scale));
        float tick = min(segmentDistance(p, cc + float2(-4.2, 0.2), cc + float2(-1.2, 3.4)),
                         segmentDistance(p, cc + float2(-1.2, 3.4), cc + float2(4.4, -3.4)));
        rgb = mix(rgb, float3(1), cover(tick - 1.1, u.scale));
    }

    float a = coverage * in.alpha;
    return float4(rgb * a, a);   // premultiplied
}
