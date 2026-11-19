/// The renderer's shaders, as Metal Shading Language source compiled at start-up with
/// `MTLDevice.makeLibrary(source:options:)`. No `.metal` files, so the package needs no
/// resource processing.
///
/// Conventions: colours are written to a non-sRGB 8-bit target as sRGB values, so every
/// fragment function ends in `toSRGB`. Depth is reversed (1 near, 0 far). The output is
/// premultiplied, because Quick Look composites the view over what is behind it.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FrameU {
        float4x4 viewProj;
        float4x4 view;
        float4x4 proj;
        float4x4 invView;
        float4 cameraPos;
        float4 params;       // x light intensity, y wire pull towards the camera, zw target size in pixels
        float4 solidTint;    // linear multiplier for the clay view
        float4 bgCentre;     // sRGB
        float4 bgBase;       // sRGB, w = alpha of the background
        float4 bgEdge;       // sRGB
        float4 gridCentreLine; // sRGB, w = opacity
        float4 gridLine;     // sRGB
        float4 gridAxisX;    // sRGB: the line along X through the middle
        float4 gridAxisZ;    // sRGB: the line along Z through the middle
        float4 gridPlace;    // xyz centre, w = edge length
        float4 shadowPlace;  // xyz centre on the floor, w = darkness at its middle
        float4 sunDir;       // xyz towards the main light, w = how bright it is in a mirror
        float4 sunColor;     // linear, times its strength
        float4 fillDir;
        float4 fillColor;
        float4 envSky;       // light from above, from below, and the same from everywhere
        float4 envGround;
        float4 envEven;
        float4 envLow;       // what a mirror shows looking down, and looking up
        float4 envHigh;
        float4 shadowSize;   // x and z half extents of the model, its height, and the brightness of the pool of light
    };

    struct DrawU {
        float4x4 model;
        float4x4 normalMatrix;
        float4 baseColor;    // linear; a is the opacity (one for an opaque draw), or the threshold of a cut-out
        float4 material;     // x metallic, y roughness, z point size in pixels, w mirrors the surroundings
        float4 flags;        // x view (0 solid, 1 textured, 2 normal), y maps in use (1 metallic, 2 roughness, 4 normal, 8 the colour image's alpha, 16 cut-out, 32 unlit material, 64 shadow colour image / point UVs), z pbr, w points have colours
        float4 emissive;     // linear light the surface gives off; w is one when an image multiplies it
        float4 shade;        // cartoon material: the shade colour (linear), w one when the material is one
        float4 toon;         // x the edge's shift, y its narrowness, z an image multiplies the shade, w outline width (metres; negative: share of the view's height)
        float4 line;         // the outline's colour (linear), w how much of the surface's colour shows in it
        float4 rim;          // the rim light's colour (linear), w how sharply it stays at the edge
        float4 rimMore;      // x the rim's lift, y how much the light dims rim and matcap, z the scale of the shift's image, w images in use (1 matcap, 2 rim, 4 shift, 8 outline width)
        float4 matcap;       // what multiplies the matcap (linear)
        float4 uvMove;       // how far the images have slid (x, y) and turned (z, radians) by now; w an image says how much of that each place gets
        float4 normalMap;    // x scales tangent-space X/Y; y is the source V convention
    };

    // A cartoon material's images slide and turn about their middle over time.
    float2 movedUV(float2 uv, constant DrawU& d, texture2d<float> maskMap, sampler smp) {
        if (d.shade.w < 0.5 || (d.uvMove.x == 0.0 && d.uvMove.y == 0.0 && d.uvMove.z == 0.0)) return uv;
        float share = d.uvMove.w > 0.5 ? maskMap.sample(smp, uv).b : 1.0;
        float2 p = uv + d.uvMove.xy * share - 0.5;
        float c = cos(d.uvMove.z * share), s = sin(d.uvMove.z * share);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y) + 0.5;
    }

    // What a cartoon material's images give at one point of the surface.
    struct ToonMaps { float3 shadeTint; float3 highlight; float3 rimTint; float shift; };
    ToonMaps noToonMaps() { ToonMaps t; t.shadeTint = float3(1.0); t.highlight = float3(0.0); t.rimTint = float3(1.0); t.shift = 0.0; return t; }

    struct V { packed_float3 p; packed_float3 n; };

    float3 toLinear(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }
    float3 toSRGB(float3 c) {
        c = clamp(c, 0.0, 1.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    // ---- background ---------------------------------------------------------

    struct BgOut { float4 pos [[position]]; float2 uv; };

    vertex BgOut bgVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        BgOut o; o.pos = float4(p, 0, 1); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o;
    }

    // The room at a point of the picture (uv from the top left, and the point itself for
    // the grain): a soft spotlight, lighter behind the model, darker towards the corners.
    float3 room(float2 uv, float2 point, constant FrameU& f) {
        float t = length((uv - float2(0.5, 0.45)) / 0.75);
        float3 c = t < 0.55 ? mix(f.bgCentre.rgb, f.bgBase.rgb, t / 0.55)
                            : mix(f.bgBase.rgb, f.bgEdge.rgb, clamp((t - 0.55) / 0.45, 0.0, 1.0));
        float2 q = floor(point);
        float n = fract(sin(dot(q, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        return saturate(c + n * 0.045 * smoothstep(0.45, 1.1, t));
    }

    fragment float4 bgFragment(BgOut in [[stage_in]], constant FrameU& f [[buffer(1)]]) {
        float3 c = room(in.uv, in.pos.xy, f);
        float a = f.bgBase.w;
        return float4(saturate(c) * a, a);
    }

    // ---- model ----------------------------------------------------------------

    // What a vertex hands on is kept by the GPU for every triangle until the frame is
    // done, so it is as little as possible: the position, and a normal only where the
    // shading needs the mesh's own. Where the surface is on screen says where it is in
    // space (see `viewPosition`), so no world position is passed.
    struct MeshOut { float4 pos [[position]]; float3 normal; };
    struct FlatOut { float4 pos [[position]]; };

    // Snap projected vertices to a 240-line grid, keeping clip depth and W intact.
    float4 snapRetro(float4 clip, constant FrameU& f, constant DrawU& d) {
        if (d.flags.x < 11.0 || clip.w <= 1e-5) return clip;
        float2 grid = float2(max(1.0, round(240.0 * f.params.z / max(f.params.w, 1.0))), 240.0);
        float2 pixel = (clip.xy / clip.w * 0.5 + 0.5) * grid;
        clip.xy = (round(pixel) / grid * 2.0 - 1.0) * clip.w;
        return clip;
    }

    float4 retroTexel(texture2d<float> image, sampler smp, float2 uv) {
        float2 size = float2(image.get_width(), image.get_height());
        float lod = clamp(ceil(log2(max(size.x, size.y) / 128.0)), 0.0, float(image.get_num_mip_levels() - 1));
        float2 cells = max(floor(size / exp2(lod)), 1.0);
        return image.sample(smp, (floor(uv * cells) + 0.5) / cells, level(lod));
    }

    vertex MeshOut meshVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                              constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        V v = verts[vid];
        MeshOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(v.p), 1.0)), f, d);
        o.normal = (d.normalMatrix * float4(float3(v.n), 0.0)).xyz;
        return o;
    }

    // For flat shading, which takes its normal from the surface itself.
    vertex FlatOut flatVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                              constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        FlatOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(verts[vid].p), 1.0)), f, d);
        return o;
    }

    // The same two with a colour per vertex (sRGB bytes in the file's own values), for the
    // views that show the model's colours.
    struct MeshColorOut { float4 pos [[position]]; float3 normal; float4 color; };
    struct FlatColorOut { float4 pos [[position]]; float4 color; };

    vertex MeshColorOut meshColorVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                        constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                        const device uchar4* colors [[buffer(4)]]) {
        V v = verts[vid];
        MeshColorOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(v.p), 1.0)), f, d);
        o.normal = (d.normalMatrix * float4(float3(v.n), 0.0)).xyz;
        o.color = float4(toLinear(float3(colors[vid].rgb) / 255.0), float(colors[vid].a) / 255.0);
        return o;
    }

    vertex FlatColorOut flatColorVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                        constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                        const device uchar4* colors [[buffer(4)]]) {
        FlatColorOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(verts[vid].p), 1.0)), f, d);
        o.color = float4(toLinear(float3(colors[vid].rgb) / 255.0), float(colors[vid].a) / 255.0);
        return o;
    }

    // And with a texture coordinate, for models whose colour comes from an image.
    // Vertex colours, where the part has them (flags.w), tint the image.
    struct MeshUVOut { float4 pos [[position]]; float3 normal; float2 uv; float2 affineUV [[center_no_perspective]]; float4 color; };
    struct FlatUVOut { float4 pos [[position]]; float2 uv; float2 affineUV [[center_no_perspective]]; float4 color; };

    vertex MeshUVOut meshUVVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                  constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                  const device uchar4* colors [[buffer(4)]], const device packed_float2* uvs [[buffer(5)]]) {
        V v = verts[vid];
        MeshUVOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(v.p), 1.0)), f, d);
        o.normal = (d.normalMatrix * float4(float3(v.n), 0.0)).xyz;
        o.uv = float2(uvs[vid]);
        o.affineUV = o.uv;
        o.color = d.flags.w > 0.5 ? float4(toLinear(float3(colors[vid].rgb) / 255.0), float(colors[vid].a) / 255.0) : float4(1.0);
        return o;
    }

    vertex FlatUVOut flatUVVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                  constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                  const device uchar4* colors [[buffer(4)]], const device packed_float2* uvs [[buffer(5)]]) {
        FlatUVOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(verts[vid].p), 1.0)), f, d);
        o.uv = float2(uvs[vid]);
        o.affineUV = o.uv;
        o.color = d.flags.w > 0.5 ? float4(toLinear(float3(colors[vid].rgb) / 255.0), float(colors[vid].a) / 255.0) : float4(1.0);
        return o;
    }

    // Point clouds: dots of a fixed size on screen, in their own colour, not lit.
    float coverage(float vertexAlpha, float textureAlpha, constant DrawU& d);
    struct PointOut { float4 pos [[position]]; float size [[point_size]]; float4 color; float2 uv; };

    vertex PointOut pointVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                const device uchar4* colors [[buffer(4)]], const device packed_float2* uvs [[buffer(5)]]) {
        PointOut o;
        o.pos = snapRetro(f.viewProj * (d.model * float4(float3(verts[vid].p), 1.0)), f, d);
        o.size = d.material.z;
        float4 tint = d.flags.w > 0.5 ? float4(toLinear(float3(colors[vid].rgb) / 255.0), float(colors[vid].a) / 255.0) : float4(1.0);
        o.color = float4(d.baseColor.rgb * tint.rgb, tint.a);
        o.uv = (int(d.flags.y + 0.5) & 64) != 0 ? float2(uvs[vid]) : float2(0.0);
        return o;
    }

    fragment float4 pointFragment(PointOut in [[stage_in]], constant DrawU& d [[buffer(2)]],
                                  texture2d<float> image [[texture(0)]], texture2d<float> maskMap [[texture(1)]],
                                  sampler smp [[sampler(0)]]) {
        float2 uv = movedUV(in.uv, d, maskMap, smp);
        // A point has one UV, not a UV footprint across a surface.
        float4 texel = d.flags.x == 12.0 ? retroTexel(image, smp, uv) : image.sample(smp, uv, level(0.0));
        float alpha = coverage(in.color.a, texel.a, d);
        if (alpha <= 0.0) discard_fragment();
        // Color textures store linear-premultiplied RGB, as for triangle materials.
        if ((int(d.flags.y + 0.5) & (8 | 16)) != 0 && texel.a > 0.0) texel.rgb /= texel.a;
        return float4(toSRGB(in.color.rgb * texel.rgb) * alpha, alpha);
    }

    // The point of the surface under a fragment, in view space. A fragment's position
    // carries 1 / w, and w of this projection is the distance in front of the camera.
    float3 viewPosition(float4 fragPos, constant FrameU& f) {
        float w = 1.0 / fragPos.w;
        float2 ndc = float2(fragPos.x / f.params.z * 2.0 - 1.0, 1.0 - fragPos.y / f.params.w * 2.0);
        // (The picture may be moved up, clear of the controls: the third column says by how much.)
        return float3((ndc.x + f.proj[2][0]) * w / f.proj[0][0], (ndc.y + f.proj[2][1]) * w / f.proj[1][1], -w);
    }

    // Clay in a studio, as seen by the camera (a "matcap", indexed by the view-space
    // normal): a soft key from the upper left that stops short of white, a cool light from
    // behind that picks out the edge on the far side, and a little of the room's own colour
    // thrown up from the floor.
    float3 clay(float3 viewNormal, float3 room) {
        float2 p = float2(viewNormal.x * 0.495 + 0.5, 0.5 - viewNormal.y * 0.495);
        float d = clamp(length(p - float2(0.38, 0.32)) / 0.80, 0.0, 1.0);
        const float3 c0 = float3(0xf2, 0xef, 0xea) / 255.0;
        const float3 c1 = float3(0xb9, 0xb6, 0xb0) / 255.0;
        const float3 c2 = float3(0x68, 0x66, 0x63) / 255.0;
        const float3 c3 = float3(0x1c, 0x1c, 0x1b) / 255.0;
        float3 c = d < 0.24 ? mix(c0, c1, d / 0.24) : d < 0.62 ? mix(c1, c2, (d - 0.24) / 0.38) : mix(c2, c3, (d - 0.62) / 0.38);
        float edge = pow(1.0 - saturate(viewNormal.z), 2.5);
        c += float3(0.70, 0.82, 1.0) * edge * saturate(viewNormal.x * 0.9 - viewNormal.y * 0.2 + 0.3) * 0.50;
        c += room * edge * saturate(-viewNormal.y + 0.1) * 0.9;
        return saturate(c);
    }

    // Bright light is eased towards white instead of being cut off at it, so a pale
    // surface keeps its shape. Below three quarters nothing is changed.
    float3 eased(float3 c) {
        float3 over = max(c - 0.75, 0.0);
        return min(c, 0.75) + 0.25 * (1.0 - exp(-over / 0.25));
    }

    // A colour a material means to be shown as it is (a cartoon's), under more light than
    // usual: it goes toward white without any of it being cut off there, so that a face
    // keeps its tone and a white shirt its folds. At the usual light and below, nothing changes.
    float3 lifted(float3 c, float light) {
        if (light <= 1.0) return c * light;
        float3 kept = saturate(c);
        return kept + (1.0 - kept) * (1.0 - exp(-(light - 1.0) * kept));
    }

    float3 environment(float3 dir, constant FrameU& f) {
        float t = smoothstep(0.15, 0.85, dir.y * 0.5 + 0.5);
        float3 c = mix(f.envLow.rgb, f.envHigh.rgb, t);
        return c + f.sunColor.rgb * f.sunDir.w * pow(saturate(dot(dir, f.sunDir.xyz)), 48.0);
    }

    // The light from all round on a surface facing `n`.
    float3 surroundingLight(float3 n, constant FrameU& f) {
        return (f.envEven.rgb + mix(f.envGround.rgb, f.envSky.rgb, 0.5 * n.y + 0.5)) * 0.6;
    }

    float3 envBRDF(float3 f0, float roughness, float nv) {
        // Karis' analytic fit of the split-sum environment BRDF.
        const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
        const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
        float4 r = roughness * c0 + c1;
        float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
        float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
        return f0 * ab.x + ab.y;
    }

    float3 directLight(float3 l, float intensity, float3 n, float3 v, float3 diffuse, float3 f0, float rough, bool specular) {
        float nl = saturate(dot(n, l));
        if (nl <= 0.0) return float3(0.0);
        float3 irradiance = float3(intensity * nl);
        float3 result = irradiance * diffuse / M_PI_F;
        if (specular) {
            float3 h = normalize(l + v);
            float nh = saturate(dot(n, h)), nv = saturate(dot(n, v)), vh = saturate(dot(v, h));
            float a = rough * rough, a2 = a * a;
            float den = nh * nh * (a2 - 1.0) + 1.0;
            float D = a2 / (M_PI_F * den * den);
            float k = a / 2.0;
            float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
            float3 F = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
            // irradiance (I * nl) times F * D * G / (4 * nl * nv).
            result += intensity * F * D * G / max(4.0 * nv, 1e-4);
        }
        return result;
    }

    // ---- styles -----------------------------------------------------------------

    // Anime: three matte lighting tones with cool shadows.
    float animeBand(float value, float threshold) {
        float edge = max(fwidth(value), 0.002);
        return smoothstep(threshold - edge, threshold + edge, value);
    }

    float3 anime(float3 n, float3 albedo, float intensity, constant FrameU& f) {
        float nl = dot(n, f.sunDir.xyz);
        float lit = animeBand(nl, 0.12);
        // Group baked lighting into painted values and pull bright colors toward
        // a matte paper white. Preserve hue across each value band.
        float peak = max(albedo.r, max(albedo.g, albedo.b));
        float value = min(sqrt(saturate(peak)), 0.84);
        float band = floor(value * 5.0 + 0.5) / 5.0;
        float matte = mix(value, band, 0.62);
        albedo *= matte * matte * 0.82 / max(peak, 1e-5);
        float3 shadow = albedo * mix(float3(0.26, 0.27, 0.41), float3(0.56, 0.56, 0.70), animeBand(nl, -0.38));
        float3 lightTint = mix(float3(1.0), saturate(f.sunColor.rgb), 0.25);
        float3 color = mix(shadow, albedo * lightTint, lit);
        return lifted(color, intensity);
    }

    float4 shade(float4 fragPos, float3 n, float3 v, float3 tint, float2 metalRough, constant FrameU& f, constant DrawU& d);
    float4 shadeGlowing(float4 fragPos, float3 n, float3 v, float3 tint, float2 metalRough, float3 glow, constant FrameU& f, constant DrawU& d);
    float4 shadeToon(float4 fragPos, float3 n, float3 v, float3 tint, float2 metalRough, float3 glow, ToonMaps maps, constant FrameU& f, constant DrawU& d);

    // What a surface hands to the blending: colour times opacity, and the opacity.
    // Opaque draws come with an opacity of one.
    float4 faded(float4 color, float alpha) { return float4(color.rgb * alpha, alpha); }

    float coverage(float vertexAlpha, float textureAlpha, constant DrawU& d) {
        int bits = int(d.flags.y + 0.5);
        if ((bits & 16) != 0) {
            if (vertexAlpha * textureAlpha < d.baseColor.a) discard_fragment();
            return 1.0;
        }
        return (bits & 8) != 0 ? d.baseColor.a * vertexAlpha * textureAlpha : 1.0;
    }

    float3 viewDirection(float4 fragPos, constant FrameU& f) {
        float3 world = (f.invView * float4(viewPosition(fragPos, f), 1.0)).xyz;
        return normalize(f.cameraPos.xyz - world);
    }

    // Smooth shading: the mesh's own normal.
    float3 ownNormal(float3 normal, bool front, float3 v) {
        float3 n = length(normal) > 0.0 ? normalize(normal) : v;
        return front ? n : -n;
    }

    // Flat shading: the normal of the triangle under the fragment, turned to the viewer.
    float3 surfaceNormal(float4 fragPos, float3 v, constant FrameU& f) {
        float3 p = viewPosition(fragPos, f);
        float3 g = (f.invView * float4(cross(dfdx(p), dfdy(p)), 0.0)).xyz;
        float3 n = length(g) > 0.0 ? normalize(g) : v;
        return dot(n, v) < 0.0 ? -n : n;
    }

    fragment float4 meshFragment(MeshOut in [[stage_in]], bool front [[front_facing]],
                                 constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        float3 v = viewDirection(in.pos, f);
        return faded(shade(in.pos, ownNormal(in.normal, front, v), v, float3(1.0), d.material.xy, f, d), coverage(1.0, 1.0, d));
    }

    fragment float4 flatFragment(FlatOut in [[stage_in]],
                                 constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        float3 v = viewDirection(in.pos, f);
        return faded(shade(in.pos, surfaceNormal(in.pos, v, f), v, float3(1.0), d.material.xy, f, d), coverage(1.0, 1.0, d));
    }

    fragment float4 meshColorFragment(MeshColorOut in [[stage_in]], bool front [[front_facing]],
                                      constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        float3 v = viewDirection(in.pos, f);
        return faded(shade(in.pos, ownNormal(in.normal, front, v), v, in.color.rgb, d.material.xy, f, d), coverage(in.color.a, 1.0, d));
    }

    fragment float4 flatColorFragment(FlatColorOut in [[stage_in]],
                                      constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        float3 v = viewDirection(in.pos, f);
        return faded(shade(in.pos, surfaceNormal(in.pos, v, f), v, in.color.rgb, d.material.xy, f, d), coverage(in.color.a, 1.0, d));
    }

    // A normal from a normal map, laid onto the surface by how position and texture
    // coordinate change across the screen (no tangents are stored). Invert the UV
    // Jacobian, then orthonormalize: UV scale must not change normal-map strength.
    float3 mapped(float3 n, float3 world, float2 uv, float3 texel, float strength, float ySign) {
        float3 t = texel * 2.0 - 1.0;
        t.xy *= strength;
        t.y *= ySign;
        float3 dp1 = dfdx(world), dp2 = dfdy(world);
        float2 duv1 = dfdx(uv), duv2 = dfdy(uv);
        float det = duv1.x * duv2.y - duv1.y * duv2.x;
        if (!isfinite(det) || abs(det) < 1e-20) return n;
        float3 tangent = (dp1 * duv2.y - dp2 * duv1.y) / det;
        float3 vAxis = (dp2 * duv1.x - dp1 * duv2.x) / det;
        tangent -= n * dot(n, tangent);
        if (!all(isfinite(tangent)) || dot(tangent, tangent) < 1e-20) return n;
        tangent = normalize(tangent);
        float3 bitangent = cross(n, tangent);
        bitangent *= dot(bitangent, vAxis) < 0.0 ? -1.0 : 1.0;
        float3 result = tangent * t.x + bitangent * t.y + n * t.z;
        return length(result) > 0.0 ? normalize(result) : n;
    }

    constexpr sampler clampSmp(address::clamp_to_edge, filter::linear, mip_filter::linear);

    float4 shadeMapped(float4 fragPos, float3 n, float3 v, float2 uv, float4 tint, bool front, constant FrameU& f, constant DrawU& d,
                       texture2d<float> image, texture2d<float> maps, texture2d<float> normalMap, texture2d<float> glowMap, texture2d<float> shadeMap,
                       texture2d<float> matcapMap, texture2d<float> rimMap, texture2d<float> shiftMap, texture2d<float> maskMap, sampler smp, sampler mapsSmp, sampler normalSmp, sampler glowSmp) {
        // Only where the model's own look shows.
        if (int(d.flags.x + 0.5) == 1) uv = movedUV(uv, d, maskMap, smp);
        int bits = int(d.flags.y + 0.5);
        float4 m = maps.sample(mapsSmp, uv);
        float2 metalRough = float2((bits & 1) != 0 ? d.material.x * m.b : d.material.x, (bits & 2) != 0 ? d.material.y * m.g : d.material.y);
        bool animeStyle = int(d.flags.x + 0.5) == 7 || int(d.flags.x + 0.5) == 4;
        if ((bits & 4) != 0 && !animeStyle) {
            float3 world = (f.invView * float4(viewPosition(fragPos, f), 1.0)).xyz;
            // The base normal already faces the viewer. Reverse tangent axes too on
            // a back face, so the entire perturbed normal is reversed consistently.
            n = mapped(n, world, uv, normalMap.sample(normalSmp, uv).xyz, d.normalMap.x * (front ? 1.0 : -1.0), d.normalMap.y);
        }
        float4 texel = d.flags.x == 12.0 ? retroTexel(image, smp, uv) : image.sample(smp, uv);
        if (int(d.flags.x + 0.5) == 7) {
            // Average fine painted detail. Keep contrasting ink, catchlights and cutout edges.
            float4 broad = image.sample(smp, uv, bias(2.5));
            // Favor dark ink boundaries. Bright texture peaks (painted glints)
            // blend into their surroundings instead of becoming extra highlights.
            float ink = dot(broad.rgb - texel.rgb, float3(0.2126, 0.7152, 0.0722));
            float keep = max(smoothstep(0.05, 0.22, ink), smoothstep(0.05, 0.3, abs(texel.a - broad.a)));
            texel.rgb = mix(broad.rgb, texel.rgb, keep);
        }
        float alpha = coverage(tint.a, texel.a, d);
        if ((bits & (8 | 16)) != 0) {
            texel.rgb = texel.a > 0.0 ? texel.rgb / texel.a : texel.rgb;
        }
        float3 glow = d.emissive.rgb;
        if (d.emissive.w > 0.5) glow *= glowMap.sample(glowSmp, uv).rgb;
        ToonMaps toon = noToonMaps();
        if (d.shade.w > 0.5) {
            int images = int(d.rimMore.w + 0.5);
            if (d.toon.z > 0.5) toon.shadeTint = shadeMap.sample(smp, uv).rgb;
            if ((images & 1) != 0) {
                // The painted ball is looked up by where the surface faces, as the viewer sees it.
                float3 vn = normalize((f.view * float4(n, 0.0)).xyz);
                toon.highlight = d.matcap.rgb * matcapMap.sample(clampSmp, float2(0.5 + 0.495 * vn.x, 0.5 - 0.495 * vn.y)).rgb;
            }
            if ((images & 2) != 0) toon.rimTint = rimMap.sample(smp, uv).rgb;
            if ((images & 4) != 0) toon.shift = shiftMap.sample(smp, uv).r * d.rimMore.z;
        }
        return faded(shadeToon(fragPos, n, v, texel.rgb * tint.rgb, metalRough, glow, toon, f, d), alpha);
    }

    fragment float4 meshUVFragment(MeshUVOut in [[stage_in]], bool front [[front_facing]],
                                   constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                   texture2d<float> image [[texture(0)]], texture2d<float> maps [[texture(1)]],
                                   texture2d<float> normalMap [[texture(2)]], texture2d<float> glowMap [[texture(3)]], texture2d<float> shadeMap [[texture(4)]],
                                   texture2d<float> matcapMap [[texture(5)]], texture2d<float> rimMap [[texture(6)]], texture2d<float> shiftMap [[texture(7)]], texture2d<float> maskMap [[texture(8)]], sampler smp [[sampler(0)]], sampler mapsSmp [[sampler(1)]], sampler normalSmp [[sampler(2)]], sampler glowSmp [[sampler(3)]]) {
        float3 v = viewDirection(in.pos, f);
        return shadeMapped(in.pos, ownNormal(in.normal, front, v), v, d.flags.x == 12.0 ? in.affineUV : in.uv, in.color, front, f, d, image, maps, normalMap, glowMap, shadeMap, matcapMap, rimMap, shiftMap, maskMap, smp, mapsSmp, normalSmp, glowSmp);
    }

    fragment float4 flatUVFragment(FlatUVOut in [[stage_in]], bool front [[front_facing]],
                                   constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                   texture2d<float> image [[texture(0)]], texture2d<float> maps [[texture(1)]],
                                   texture2d<float> normalMap [[texture(2)]], texture2d<float> glowMap [[texture(3)]], texture2d<float> shadeMap [[texture(4)]],
                                   texture2d<float> matcapMap [[texture(5)]], texture2d<float> rimMap [[texture(6)]], texture2d<float> shiftMap [[texture(7)]], texture2d<float> maskMap [[texture(8)]], sampler smp [[sampler(0)]], sampler mapsSmp [[sampler(1)]], sampler normalSmp [[sampler(2)]], sampler glowSmp [[sampler(3)]]) {
        float3 v = viewDirection(in.pos, f);
        return shadeMapped(in.pos, surfaceNormal(in.pos, v, f), v, d.flags.x == 12.0 ? in.affineUV : in.uv, in.color, front, f, d, image, maps, normalMap, glowMap, shadeMap, matcapMap, rimMap, shiftMap, maskMap, smp, mapsSmp, normalSmp, glowSmp);
    }

    // `tint` is the vertex colour or the texture's (linear), white where there is none.
    float4 shade(float4 fragPos, float3 n, float3 v, float3 tint, float2 metalRough, constant FrameU& f, constant DrawU& d) {
        // Without an image the surface gives off its one colour all over.
        return shadeToon(fragPos, n, v, tint, metalRough, d.emissive.w > 0.5 ? float3(0.0) : d.emissive.rgb, noToonMaps(), f, d);
    }

    // A cartoon material (VRM's MToon) in the Textured view: the surface is its own colour
    // where the key light reaches it and its shade colour where it does not, with an edge
    // the material moves (shift) and narrows (toony). Everything else, and every other view
    // and style, is drawn as any material is. On top come its rim light, along the edges
    // that turn away from the viewer, and its painted highlight.
    float4 shadeToon(float4 fragPos, float3 n, float3 v, float3 tint, float2 metalRough, float3 glow, ToonMaps maps, constant FrameU& f, constant DrawU& d) {
        if (d.shade.w < 0.5 || int(d.flags.x + 0.5) != 1) return shadeGlowing(fragPos, n, v, tint, metalRough, glow, f, d);
        float3 base = d.baseColor.rgb * tint;
        float shading = dot(n, f.sunDir.xyz) + d.toon.x + maps.shift;
        shading = saturate((shading - (-1.0 + d.toon.y)) / max(2.0 - 2.0 * d.toon.y, 1e-4));
        float3 lit = mix(d.shade.rgb * maps.shadeTint, base, shading);
        float3 rim = d.rim.rgb * pow(saturate(1.0 - dot(n, v) + d.rimMore.x), max(d.rim.w, 1e-4));
        rim = (rim + maps.highlight) * maps.rimTint * mix(1.0, f.params.x, d.rimMore.y);
        return float4(toSRGB(lifted(lit, f.params.x) + rim + glow), 1.0);
    }

    // `glow` is the light the surface gives off by itself (linear), on top of what the
    // lights make of it; it shows where the model's own colours show.
    float4 shadeGlowing(float4 fragPos, float3 n, float3 v, float3 tint, float2 metalRough, float3 glow, constant FrameU& f, constant DrawU& d) {
        float3 base = d.baseColor.rgb * tint;
        // flags.x is the mode: 0 clay, 1 textured, 2 normal, 3 solid unlit, 4 solid toon,
        // 6 textured unlit, 7 textured toon.
        int mode = int(d.flags.x + 0.5);
        float3 vn = normalize((f.view * float4(n, 0.0)).xyz);
        if (mode == 2) return float4(toSRGB(vn * 0.5 + 0.5), 1.0);
        // The clay is lit by the same light as everything else: its slider dims and brightens it.
        if (mode == 0) return float4(toSRGB(eased(toLinear(clay(vn, f.bgCentre.rgb)) * f.solidTint.rgb * f.params.x)), 1.0);
        float3 solidLinear = toLinear(float3(0xb4, 0xb4, 0xb8) / 255.0) * f.solidTint.rgb;
        if (mode == 3) return float4(toSRGB(solidLinear), 1.0);
        if (mode == 6) return float4(toSRGB(base * 1.5 + glow), 1.0);
        if (mode == 11 || mode == 12) {
            float light = 0.48 + 0.52 * saturate(dot(n, f.sunDir.xyz));
            float3 rgb = toSRGB(lifted((mode == 11 ? solidLinear : base) * light, f.params.x));
            return float4(round(saturate(rgb) * 31.0) / 31.0, 1.0);
        }
        if (mode == 9 || mode == 10) {
            float nl = dot(n, f.sunDir.xyz);
            float tone = 0.18 + 0.24 * animeBand(nl, -0.32) + 0.33 * animeBand(nl, 0.18) + 0.25 * animeBand(nl, 0.70);
            float3 paint = mode == 9 ? solidLinear : base;
            return float4(toSRGB(lifted(paint * tone, f.params.x)), 1.0);
        }
        if (mode == 4 || mode == 7) return float4(toSRGB(anime(n, mode == 4 ? solidLinear : base, f.params.x, f) + glow), 1.0);

        // A material the file means to be shown as it is, whatever the light.
        if ((int(d.flags.y + 0.5) & 32) != 0) return float4(toSRGB(base + glow), 1.0);

        // Textured: metallic-roughness with a key and a fill light, ambient and hemisphere light.
        float intensity = f.params.x;
        bool pbr = d.flags.z > 0.5;
        float3 albedo = base;
        float metallic = pbr ? metalRough.x : 0.0;
        float rough = clamp(metalRough.y, 0.05, 1.0);
        float3 diffuse = albedo * (1.0 - metallic);
        float3 f0 = mix(float3(0.04), albedo, metallic);
        float3 color = directLight(f.sunDir.xyz, intensity, n, v, diffuse, f0, rough, pbr) * f.sunColor.rgb;
        color += directLight(f.fillDir.xyz, intensity, n, v, diffuse, f0, rough, pbr) * f.fillColor.rgb;
        color += surroundingLight(n, f) * intensity * diffuse / M_PI_F;
        // The surroundings are mirrored where the view settings set metallic or roughness
        // (material.w) and on metal the file itself describes: lit by the lights alone,
        // a metal has no diffuse light to show and comes out black.
        if (pbr && (d.material.w > 0.5 || metallic > 0.0)) {
            float nv = saturate(dot(n, v));
            float3 r = normalize(mix(reflect(-v, n), n, rough * rough));
            color += environment(r, f) * envBRDF(f0, rough, nv) * 0.5 * intensity;
        }
        // A cool light from behind, on the edges that turn away from the viewer: it lifts
        // the model off the dark room.
        float turned = pow(1.0 - saturate(dot(n, v)), 3.0);
        color += float3(0.72, 0.84, 1.0) * turned * saturate(dot(n, normalize(float3(-0.6, 0.35, -1.0))) * 0.5 + 0.6) * 0.20 * intensity;
        return float4(toSRGB(eased(color) + glow), 1.0);
    }

    // ---- outline: the back faces of the mesh pushed out along welded normals by a fixed
    // width on screen (0.0036 of the clip space) ---------------------

    struct OutlineOut { float4 pos [[position]]; };

    vertex OutlineOut outlineVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                    constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                    const device packed_float3* outlineNormals [[buffer(3)]]) {
        float4 clip = f.viewProj * (d.model * float4(float3(verts[vid].p), 1.0));
        float3 vn = (f.view * (d.normalMatrix * float4(float3(outlineNormals[vid]), 0.0))).xyz;
        float2 dir = normalize(vn.xy + float2(1e-5));
        clip.xy += dir * float2(f.proj[0][0] / f.proj[1][1], 1.0) * clip.w * (d.flags.x >= 9.0 ? 0.009 : (int(d.flags.x + 0.5) == 5 ? 0.0036 : 0.0022));
        OutlineOut o; o.pos = clip; return o;
    }

    fragment float4 outlineFragment(OutlineOut in [[stage_in]]) {
        return float4(float3(5.0, 5.0, 6.0) / 255.0, 1.0);
    }

    // ---- a cartoon material's own outline: the part's hull pushed out along its normals by
    // the material's width, in metres or as a share of the view's height --------------------

    struct ToonLineOut { float4 pos [[position]]; float2 uv; };

    float4 toonHull(V v, float scale, constant FrameU& f, constant DrawU& d) {
        float3 n = (d.normalMatrix * float4(float3(v.n), 0.0)).xyz;
        n = length(n) > 0.0 ? normalize(n) : float3(0.0);
        float4 world = d.model * float4(float3(v.p), 1.0);
        if (d.toon.w >= 0.0) {
            world.xyz += n * d.toon.w * scale;
            return f.viewProj * world;
        }
        float4 clip = f.viewProj * world;
        float3 vn = (f.view * float4(n, 0.0)).xyz;
        float2 dir = normalize(vn.xy + float2(1e-5));
        clip.xy += dir * float2(f.proj[0][0] / f.proj[1][1], 1.0) * clip.w * (-d.toon.w) * scale;
        return clip;
    }

    vertex ToonLineOut toonOutlineVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                         constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        ToonLineOut o; o.pos = toonHull(verts[vid], 1.0, f, d); o.uv = float2(0.0); return o;
    }

    vertex ToonLineOut toonOutlineUVVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                           constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                           const device packed_float2* uvs [[buffer(5)]],
                                           texture2d<float> widthMap [[texture(0)]], sampler smp [[sampler(0)]]) {
        float2 uv = float2(uvs[vid]);
        // The material may thin its outline over the surface (the image's green).
        float scale = (int(d.rimMore.w + 0.5) & 8) != 0 ? widthMap.sample(smp, uv, level(0.0)).g : 1.0;
        ToonLineOut o; o.pos = toonHull(verts[vid], scale, f, d); o.uv = uv; return o;
    }

    fragment float4 toonOutlineFragment(ToonLineOut in [[stage_in]], constant DrawU& d [[buffer(2)]]) {
        return float4(toSRGB(d.line.rgb * mix(float3(1.0), d.baseColor.rgb, d.line.w)), 1.0);
    }

    fragment float4 toonOutlineUVFragment(ToonLineOut in [[stage_in]], constant DrawU& d [[buffer(2)]],
                                          texture2d<float> image [[texture(0)]], texture2d<float> maskMap [[texture(1)]], sampler smp [[sampler(0)]]) {
        float4 texel = image.sample(smp, movedUV(in.uv, d, maskMap, smp));
        int bits = int(d.flags.y + 0.5);
        // Where a cut-out is not there, neither is its outline.
        if ((bits & 16) != 0 && texel.a < d.baseColor.a) discard_fragment();
        // Only an image with alpha in use was stored multiplied by it.
        float3 surface = d.baseColor.rgb * ((bits & 24) != 0 && texel.a > 0.0 ? texel.rgb / texel.a : texel.rgb);
        return float4(toSRGB(d.line.rgb * mix(float3(1.0), surface, d.line.w)), 1.0);
    }

    // ---- polygon wire: real line geometry, pulled a little towards the camera so it
    // is not lost to the surface it outlines ---------------------------------------

    struct WireOut { float4 pos [[position]]; };

    vertex WireOut wireVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                              constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]]) {
        float4 viewPos = f.view * (d.model * float4(float3(verts[vid].p), 1.0));
        viewPos.xyz *= (1.0 - f.params.y);
        WireOut o; o.pos = snapRetro(f.proj * viewPos, f, d); return o;
    }

    fragment float4 wireFragment(WireOut in [[stage_in]]) {
        // Black at 60%, premultiplied.
        return float4(0.0, 0.0, 0.0, 0.6);
    }

    // ---- skinning: the vertices of a part moved to its skeleton's pose, before the
    // frame that draws them --------------------------------------------------------

    struct SkinU { uint vertexCount; uint jointCount; uint hasOutline; uint pad; };

    float3x3 skinNormalMatrix(float3x3 m) {
        float3 a = cross(m[1], m[2]), b = cross(m[2], m[0]), c = cross(m[0], m[1]);
        float det = dot(m[0], a);
        if (!isfinite(det) || det == 0.0) return float3x3(1.0);
        float3x3 n = float3x3(a, b, c) / det;
        return all(isfinite(n[0])) && all(isfinite(n[1])) && all(isfinite(n[2])) ? n : float3x3(1.0);
    }

    kernel void skinVertices(uint id [[thread_position_in_grid]],
                             const device V* rest [[buffer(0)]], const device ushort4* joints [[buffer(1)]],
                             const device float4* weights [[buffer(2)]], const device float4x4* matrices [[buffer(3)]],
                             device V* posed [[buffer(4)]], const device packed_float3* restOutline [[buffer(5)]],
                             device packed_float3* outline [[buffer(6)]], constant SkinU& u [[buffer(7)]]) {
        if (id >= u.vertexCount) return;
        uint4 j = min(uint4(joints[id]), uint4(u.jointCount - 1));
        float4 w = weights[id];
        float4x4 blended = matrices[j.x] * w.x;
        if (w.y > 0.0) blended += matrices[j.y] * w.y;
        if (w.z > 0.0) blended += matrices[j.z] * w.z;
        if (w.w > 0.0) blended += matrices[j.w] * w.w;
        float3x3 linear = float3x3(blended[0].xyz, blended[1].xyz, blended[2].xyz);
        V v = rest[id];
        V o;
        o.p = (blended * float4(float3(v.p), 1.0)).xyz;
        float3x3 normal = skinNormalMatrix(linear);
        o.n = normal * float3(v.n);
        posed[id] = o;
        if (u.hasOutline != 0) outline[id] = normal * float3(restOutline[id]);
    }

    // ---- the shadow under the model -------------------------------------------------
    //
    // First the model is drawn as seen from straight above into a small picture of its
    // own: how much each spot of the floor is covered, and the nearer the floor the part
    // that covers it, the more. Then a patch of floor is drawn under the model which takes
    // that picture, softened, as its darkness. Round it the patch is a pool of light, which
    // is what lets a shadow show in a dark room.

    // How far the picture from above reaches, and how far the pool of light, in half
    // widths of the model.
    constant float coverReach = 1.7;
    constant float poolReach = 4.0;

    struct CoverOut { float4 pos [[position]]; float height; float2 uv; float alpha; };

    vertex CoverOut coverVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]],
                                const device uchar4* colors [[buffer(4)]], const device packed_float2* uvs [[buffer(5)]]) {
        float3 w = (d.model * float4(float3(verts[vid].p), 1.0)).xyz;
        float2 at = (w.xz - f.shadowPlace.xz) / (max(f.shadowSize.xy, float2(1e-6)) * coverReach);
        CoverOut o;
        o.pos = float4(at.x, -at.y, 0.5, 1.0);
        o.height = (w.y - f.shadowPlace.y) / max(f.shadowSize.z, 1e-6);
        o.uv = (int(d.flags.y + 0.5) & 64) != 0 ? float2(uvs[vid]) : float2(0.0);
        o.alpha = d.flags.w > 0.5 ? float(colors[vid].a) / 255.0 : 1.0;
        return o;
    }

    // What stands on the floor shades it fully; what is high above it, a little.
    fragment float4 coverFragment(CoverOut in [[stage_in]], constant DrawU& d [[buffer(2)]],
                                   texture2d<float> image [[texture(0)]], texture2d<float> maskMap [[texture(1)]], sampler smp [[sampler(0)]]) {
        float2 uv = int(d.flags.x + 0.5) == 1 ? movedUV(in.uv, d, maskMap, smp) : in.uv;
        float textureAlpha = (int(d.flags.y + 0.5) & 64) != 0 ? image.sample(smp, uv).a : 1.0;
        float alpha = coverage(in.alpha, textureAlpha, d);
        return float4(alpha * (1.0 - 0.82 * smoothstep(0.0, 0.75, in.height)));
    }

    // The floor has a little sheen: the model is drawn once more upside down under it, and
    // then the floor is laid over that as a veil of the room's own colour, thinnest by the
    // model, so that what shows through is faint and fades with distance.
    constant float veilReach = 60.0;

    struct VeilOut { float4 pos [[position]]; float2 at; };

    vertex VeilOut veilVertex(uint vid [[vertex_id]], constant FrameU& f [[buffer(1)]]) {
        float2 c = float2((vid & 1) != 0 ? 1.0 : -1.0, (vid & 2) != 0 ? 1.0 : -1.0) * veilReach;
        float3 p = f.shadowPlace.xyz + float3(c.x * f.shadowSize.x, 0.0, c.y * f.shadowSize.y);
        VeilOut o; o.pos = f.viewProj * float4(p, 1.0); o.at = c; return o;
    }

    fragment float4 veilFragment(VeilOut in [[stage_in]], constant FrameU& f [[buffer(1)]]) {
        float2 uv = in.pos.xy / f.params.zw;
        float sheen = f.shadowPlace.w > 0.0 ? 0.24 * (1.0 - smoothstep(0.6, 3.2, length(in.at))) : 0.0;
        return float4(room(uv, in.pos.xy, f) * (1.0 - sheen), 1.0 - sheen);
    }

    struct ShadowOut { float4 pos [[position]]; float2 at; };

    vertex ShadowOut shadowVertex(uint vid [[vertex_id]], constant FrameU& f [[buffer(1)]]) {
        float2 c = float2((vid & 1) != 0 ? 1.0 : -1.0, (vid & 2) != 0 ? 1.0 : -1.0) * poolReach;
        float3 p = f.shadowPlace.xyz + float3(c.x * f.shadowSize.x, 0.0, c.y * f.shadowSize.y);
        ShadowOut o; o.pos = f.viewProj * float4(p, 1.0); o.at = c; return o;
    }

    constexpr sampler coverSmp(address::clamp_to_zero, filter::linear);

    fragment float4 shadowFragment(ShadowOut in [[stage_in]], constant FrameU& f [[buffer(1)]],
                                   texture2d<float> cover [[texture(0)]]) {
        float2 uv = in.at / coverReach * 0.5 + 0.5;
        // Softened: the middle, and two rings round it.
        float sum = cover.sample(coverSmp, uv).r * 2.0;
        for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.7853982;
            float2 dir = float2(cos(a), sin(a));
            sum += cover.sample(coverSmp, uv + dir * 0.022).r * 1.5;
            sum += cover.sample(coverSmp, uv + dir * 0.055).r;
        }
        float dark = f.shadowPlace.w * saturate(sum / 22.0);
        float pool = f.shadowSize.w * pow(1.0 - smoothstep(0.0, poolReach, length(in.at)), 2.0);
        // Light is added, and the shadow takes it away again where it falls.
        return float4(f.bgCentre.rgb * pool * (1.0 - dark), dark);
    }

    // ---- floor grid -----------------------------------------------------------------

    struct GridOut { float4 pos [[position]]; float4 color [[flat]]; float2 at; };

    vertex GridOut gridVertex(uint vid [[vertex_id]], constant FrameU& f [[buffer(1)]]) {
        uint line = vid / 2, end = vid % 2;
        uint i = line % 21;
        float t = (float(i) - 10.0) / 20.0;
        float s = end == 0 ? -0.5 : 0.5;
        float3 p = line < 21 ? float3(t, 0, s) : float3(s, 0, t);
        p = f.gridPlace.xyz + p * f.gridPlace.w;
        // The two lines through the middle are the axes they lie along.
        float4 c = (i != 10) ? f.gridLine : (line < 21 ? f.gridAxisZ : f.gridAxisX);
        float w = f.gridCentreLine.w * ((i == 10) ? 1.6 : 1.0);
        GridOut o; o.pos = f.viewProj * float4(p, 1.0); o.color = float4(c.rgb * w, w);
        o.at = line < 21 ? float2(t, s) : float2(s, t);
        return o;
    }

    // The floor fades into the room towards its edge instead of ending in a line.
    fragment float4 gridFragment(GridOut in [[stage_in]]) {
        float d = length(in.at) * 2.0;
        return in.color * (1.0 - smoothstep(0.45, 1.0, d));
    }
    """
}
