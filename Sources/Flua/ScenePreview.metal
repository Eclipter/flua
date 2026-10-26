#include <metal_stdlib>
using namespace metal;

struct SceneVertex { float4 position [[position]]; float2 uv; };

vertex SceneVertex sceneVertex(uint id [[vertex_id]]) {
    float2 p = id == 0 ? float2(-1, -1) : (id == 1 ? float2(3, -1) : float2(-1, 3));
    return {float4(p, 0, 1), (p + 1) * 0.5};
}

static float3 over(float3 base, float4 paint) { return mix(base, paint.rgb, clamp(paint.a, 0.0f, 1.0f)); }
static float projection(float2 p, float2 a, float2 b) { return clamp(dot(p - a, b - a) / dot(b - a, b - a), 0.0f, 1.0f); }
static float4 gradient(float2 p, float2 a, float2 b, float4 c0, float4 c1, float4 c2) {
    float t = projection(p, a, b) * 2;
    return t < 1 ? mix(c0, c1, t) : mix(c1, c2, t - 1);
}
static float3 glow(float3 base, float2 p, float2 center, float2 radius, float4 color) {
    color.a *= max(0.0f, 1 - length((p - center) / radius));
    return over(base, color);
}
static float below(float y, float edge, float pixel) { return 1 - smoothstep(edge - pixel * 0.5f, edge + pixel * 0.5f, y); }
static float line(float y, float edge, float width, float pixel) {
    return clamp((width * 0.5f + pixel * 0.5f - abs(y - edge)) / pixel, 0.0f, min(1.0f, width / pixel));
}
static float ellipse(float2 p, float2 center, float2 radius, float2 pixel) {
    float2 r = max(radius, pixel * 0.5f);
    float coverage = clamp((1 - length((p - center) / r)) * min(r.x / pixel.x, r.y / pixel.y) + 0.5f, 0.0f, 1.0f);
    return coverage * min(1.0f, radius.x * radius.y * 4 / (pixel.x * pixel.y));
}
static float3 stars(float3 color, float2 p, float t, int count, float minY, float2 pixel, constant float *n) {
    for (int i = 0; i < count; ++i) {
        float radius = 0.00045f + n[i * 3 + 3] * 0.00075f;
        float2 r = float2(radius * 0.5f, radius * 0.85f);
        float2 center = float2(n[i * 3 + 1], minY + n[i * 3 + 2] * (1 - minY)) + r;
        if (any(abs(p - center) > max(r, pixel) * 2)) continue;
        float alpha = 0.18f + 0.54f * (0.5f + 0.5f * sin(t * 0.35f + i));
        color = over(color, float4(0.8f, 0.9f, 1, alpha * ellipse(p, center, r, pixel)));
    }
    return color;
}

static float3 aurora(float2 p, float t, float2 pixel, constant float *n) {
    float3 c = gradient(p, float2(0, 1), float2(0), float4(0.012f, 0.025f, 0.065f, 1),
        float4(0.025f, 0.11f, 0.16f, 1), float4(0.025f, 0.04f, 0.10f, 1)).rgb;
    c = glow(c, p, float2(0.65f), float2(0.65f, 0.55f), float4(0.05f, 0.36f, 0.33f, 0.3f));
    c = stars(c, p, t, 135, 0.39f, pixel, n);
    for (int ribbon = 6; ribbon >= 0; --ribbon) {
        float r = ribbon, phase = t * 0.10f + r * 0.22f;
        float h = 0.64f + r * 0.025f + 0.10f * sin(p.x * 5 + phase) + 0.075f * sin(p.x * 8.2f - phase * 0.6f);
        float thickness = 0.06f + 0.07f * (0.5f + 0.5f * sin(p.x * 7 + phase));
        float mask = (1 - below(p.y, h, pixel.y)) * below(p.y, h + thickness, pixel.y);
        float hue = r / 6;
        float4 paint = gradient(p, float2(0.2f, 0.54f), float2(0.8f, 0.98f),
            float4(0.10f + hue * 0.2f, 0.9f - hue * 0.3f, 0.62f + hue * 0.35f, 0),
            float4(0.1f, 0.95f, 0.69f, 0.15f), float4(0.35f, 0.6f, 1, 0));
        paint.a *= mask;
        c = over(c, paint);
    }
    for (int ridge = 0; ridge < 3; ++ridge) {
        float h = 0.20f + ridge * 0.034f + 0.03f * sin(p.x * 16 + ridge * 2) + 0.014f * sin(p.x * 43);
        c = over(c, float4(0.012f, 0.025f + (2 - ridge) * 0.008f, 0.045f + (2 - ridge) * 0.014f, below(p.y, h, pixel.y)));
    }
    c = glow(c, p, float2(0.6f, 0.075f), float2(0.55f, 0.14f), float4(0.06f, 0.45f, 0.40f, 0.26f));
    for (int i = 0; i < 28; ++i) {
        float width = 0.18f + n[i + 77] * 0.4f;
        float x = 0.55f - width / 2 + sin(t * 0.12f + i) * 0.012f;
        if (p.x < x || p.x > x + width) continue;
        float alpha = (0.025f + n[i + 10] * 0.04f) * line(p.y, i * 0.0057f, 0.00065f, pixel.y);
        c = over(c, float4(0.2f, 0.8f, 0.65f, alpha));
    }
    return c;
}

static float3 cosmos(float2 p, float t, float2 pixel, constant float *n) {
    float3 c = mix(float3(0.008f, 0.012f, 0.04f), float3(0.025f, 0.018f, 0.08f), projection(p, float2(0), float2(1)));
    float drift = sin(t * 0.055f) * 0.035f;
    for (int i = 0; i < 9; ++i) {
        float u = float(i) / 8;
        float2 center = float2(-0.05f + u * 1.15f + drift, 0.28f + u * 0.4f + sin(i * 1.3f + t * 0.045f) * 0.055f);
        c = glow(c, p, center, float2(0.25f, 0.27f), float4(0.19f + u * 0.10f, 0.08f + u * 0.13f, 0.55f, 0.18f));
        c = glow(c, p, center + float2(0.045f, 0), float2(0.15f, 0.12f), float4(0.05f, 0.3f, 0.6f, 0.14f));
    }
    c = stars(c, p, t, 230, 0, pixel, n);
    float2 planet = float2(0.76f + drift * 0.15f, 0.47f);
    c = glow(c, p, planet, float2(0.139f, 0.241f), float4(0.25f, 0.39f, 0.75f, 0.22f));
    float4 paint = gradient(p, planet + float2(-0.12f, 0.16f), planet + float2(0.08f, -0.03f),
        float4(0.22f, 0.3f, 0.47f, 1), float4(0.035f, 0.048f, 0.10f, 1), float4(0.006f, 0.009f, 0.024f, 1));
    paint.a = ellipse(p, planet, float2(0.11f, 0.19f), pixel);
    c = over(c, paint);
    c = glow(c, p, float2(0.23f, 0.71f), float2(0.032f, 0.055f), float4(0.65f, 0.75f, 1, 0.65f));
    return over(c, float4(0.92f, 0.94f, 1, 0.95f * ellipse(p, float2(0.23f, 0.7099f), float2(0.0011f, 0.0019f), pixel)));
}

static float3 ocean(float2 p, float t, float2 pixel, constant float *n) {
    float3 c = gradient(p, float2(0, 1), float2(0), float4(0.018f, 0.043f, 0.10f, 1),
        float4(0.045f, 0.15f, 0.19f, 1), float4(0.008f, 0.04f, 0.075f, 1)).rgb;
    c = stars(c, p, t, 75, 0.57f, pixel, n);
    c = glow(c, p, float2(0.69f, 0.77f), float2(0.17f, 0.29f), float4(0.50f, 0.77f, 0.85f, 0.12f));
    c = over(c, float4(0.78f, 0.87f, 0.86f, 0.9f * ellipse(p, float2(0.69f, 0.7705f), float2(0.019f, 0.0325f), pixel)));
    c = glow(c, p, float2(0.66f, 0.46f), float2(0.65f, 0.20f), float4(0.09f, 0.47f, 0.53f, 0.2f));
    for (int row = 0; row < 34; ++row) {
        float depth = float(row) / 33;
        float base = 0.49f - pow(depth, 1.5f) * 0.57f;
        float amplitude = 0.0015f + pow(depth, 1.7f) * 0.025f;
        float phase = p.x * (24 - depth * 16) + t * (0.22f + depth * 0.28f) + row * 1.7f;
        float h = base + sin(phase) * amplitude + sin(p.x * 19 - t * 0.13f + depth * 7) * amplitude * 0.4f;
        c = over(c, float4(0.013f, 0.09f + depth * 0.025f, 0.14f + depth * 0.025f, below(p.y, h, pixel.y)));
        c = over(c, float4(0.19f, 0.64f, 0.68f, (0.10f + depth * 0.22f) * line(p.y, h, 0.0007f + depth * 0.0012f, pixel.y)));
        if (row % 2 == 0) {
            float reflection = 0.02f + depth * 0.17f;
            float x = 0.69f + sin(t * 0.2f + row) * reflection * 0.2f;
            if (abs(p.x - x) <= reflection)
                c = over(c, float4(0.66f, 0.84f, 0.81f, 0.17f * (1 - depth * 0.6f) * line(p.y, base, 0.001f, pixel.y)));
        }
    }
    return c;
}

static float3 ember(float2 p, float t, float2 pixel, constant float *n) {
    float3 c = gradient(p, float2(0, 1), float2(0), float4(0.028f, 0.012f, 0.025f, 1),
        float4(0.11f, 0.025f, 0.025f, 1), float4(0.19f, 0.038f, 0.015f, 1)).rgb;
    c = glow(c, p, float2(0.46f, 0.02f), float2(0.8f, 0.75f), float4(0.75f, 0.18f, 0.025f, 0.32f));
    for (int i = 0; i < 7; ++i) {
        float phase = t * 0.12f + i * 0.9f;
        c = glow(c, p, float2(0.5f + sin(phase) * 0.2f, 0.13f + i * 0.055f), float2(0.36f, 0.15f), float4(0.70f, 0.15f, 0.045f, 0.08f));
    }
    for (int i = 0; i < 8; ++i) {
        float y = 0.07f + i * 0.025f + 0.045f * sin(p.x * 9 + t * 0.16f + i * 0.3f) + 0.018f * sin(p.x * 19 - t * 0.09f);
        c = over(c, float4(1, 0.36f + i * 0.035f, 0.10f, 0.055f * line(p.y, y, 0.001f + i * 0.00025f, pixel.y)));
    }
    for (int i = 0; i < 95; ++i) {
        float y = fract(n[i * 7 + 1] + t * (0.012f + n[i + 42] * 0.023f));
        float x = n[i * 7 + 3] + sin(t * 0.15f + i) * 0.027f * y;
        float radius = 0.0006f + n[i + 8] * 0.0012f;
        float alpha = sin(y * M_PI_F) * (0.3f + n[i + 33] * 0.6f);
        if (i % 7 == 0)
            c = glow(c, p, float2(x, y), float2(radius * 5, radius * 9), float4(1, 0.34f, 0.06f, alpha * 0.45f));
        float2 r = float2(radius, radius * (1.7f + n[i] * 1.7f)) * 0.5f;
        if (all(abs(p - float2(x, y) - r) < max(r, pixel) * 2))
            c = over(c, float4(1, 0.45f + n[i] * 0.4f, 0.15f, alpha * ellipse(p, float2(x, y) + r, r, pixel)));
    }
    return c;
}

static float3 artwork(float2 p, float2 size, texture2d<float> image) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 imageSize = float2(image.get_width(), image.get_height());
    float scale = max(size.x / imageSize.x, size.y / imageSize.y);
    float2 extent = imageSize * scale / size;
    return image.sample(imageSampler, (p - (1 - extent) / 2) / extent).rgb;
}

struct MotionSprite { float4 rect; float4 style; };
struct MotionVertex {
    float4 position [[position]];
    float2 uv;
    float2 artworkUV;
    float opacity;
    uint textureIndex [[flat]];
    uint masked [[flat]];
};

vertex MotionVertex motionVertex(uint id [[vertex_id]], uint instance [[instance_id]],
    constant MotionSprite *sprites [[buffer(0)]], constant float4 &frame [[buffer(1)]]) {
    float2 uv = float2(id & 1, id >> 1);
    MotionSprite sprite = sprites[instance];
    float2 offset = (uv - 0.5f) * sprite.rect.zw;
    float s = sin(sprite.style.x), c = cos(sprite.style.x);
    float2 point = sprite.rect.xy + float2(offset.x * c - offset.y * s, offset.x * s + offset.y * c);
    float2 p = frame.xy + point * frame.zw;
    return {float4(p * 2 - 1, 0, 1), uv, point, sprite.style.y, uint(sprite.style.z), uint(sprite.style.w)};
}

fragment float4 motionFragment(MotionVertex in [[stage_in]],
    array<texture2d<float>, 8> textures [[texture(0)]], texture2d<float> mask [[texture(8)]],
    constant float &dimming [[buffer(2)]]) {
    constexpr sampler spriteSampler(coord::normalized, address::clamp_to_zero, filter::linear, mip_filter::linear);
    float4 color = textures[in.textureIndex].sample(spriteSampler, in.uv) * in.opacity;
    if (in.masked != 0) color *= mask.sample(spriteSampler, in.artworkUV).a;
    color.rgb *= 1 - dimming;
    return color;
}

fragment float4 sceneComposite(SceneVertex in [[stage_in]], texture2d<float> color [[texture(0)]],
    constant float &dimming [[buffer(2)]]) {
    return float4(color.read(uint2(in.position.xy)).rgb * (1 - dimming), 1);
}

fragment float4 sceneFragment(SceneVertex in [[stage_in]], constant float4 &u [[buffer(0)]],
    constant float *noise [[buffer(1)]], constant float &dimming [[buffer(2)]], texture2d<float> image [[texture(0)]]) {
    float2 pixel = 1 / max(u.xy, float2(1));
    float3 color;
    switch (uint(u.w)) {
        case 1: color = cosmos(in.uv, u.z, pixel, noise); break;
        case 2: color = ocean(in.uv, u.z, pixel, noise); break;
        case 3: color = ember(in.uv, u.z, pixel, noise); break;
        case 4: case 5: case 6: case 7: color = artwork(in.uv, u.xy, image); break;
        default: color = aurora(in.uv, u.z, pixel, noise); break;
    }
    return float4(color * (1 - dimming), 1);
}
