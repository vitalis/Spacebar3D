/// The Hologram style's shaders, compiled together with `Shaders.source` (whose structs
/// and helpers they use).
///
/// The style is drawn into a layer of its own, in linear light with room above white:
/// the see-through shell, then the lights of its arrival added on top (two swirls that
/// start at the model's middle and build it towards its top and its bottom). Bright
/// parts of the layer are blurred into a glow, and layer and glow are laid over the
/// background in the view's own pass.
enum HologramShaders {
    static let source = """

    // ---- hologram ---------------------------------------------------------------

    struct HoloU {
        float4 boxMin;     // xyz the model's box, w its longest side
        float4 boxSize;    // xyz, w seconds
        float4 grid;       // xyz grid cells across the box, w number of scan lines
        float4 state;      // x how far the model is built from its middle (0 .. 0.55 of its height each way), y settled, z scan distance from the middle, w unused
        float4 extra;      // x pixels per point, y strength of the swirls, zw unused
    };

    float holoHash2(float2 p) { return fract(sin(dot(p, float2(41.3, 289.1))) * 45758.5453); }

    // One stable, randomly placed line per cell. Wrapped cell IDs make the
    // irregular pattern tile seamlessly as the stream crosses the model's edges.
    float holoStreamDistance(float height, float count, float seed) {
        float position = fract(height) * count;
        float cell = floor(position);
        float nearest = 1.0;
        for (int offset = -1; offset <= 1; ++offset) {
            float neighbor = cell + float(offset);
            float id = fmod(neighbor + count, count);
            float jitter = 0.15 + 0.7 * holoHash2(float2(id, seed));
            nearest = min(nearest, abs(position - (neighbor + jitter)) / count);
        }
        return nearest;
    }

    struct HoloOut { float4 pos [[position]]; float3 view; float3 normal; float3 box; float2 uv; };

    HoloOut holoShell(float3 position, float3 normal, float2 uv, constant FrameU& f, constant DrawU& d, constant HoloU& h) {
        float4 world = d.model * float4(position, 1.0);
        HoloOut o;
        // Position inside the model's box, 0..1 on each axis.
        o.box = (world.xyz - h.boxMin.xyz) / h.boxSize.xyz;

        float4 mv = f.view * world;
        o.view = -mv.xyz;
        o.normal = d.flags.x > 0.5 ? float3(0.0) : (f.view * (d.normalMatrix * float4(normal, 0.0))).xyz;
        o.uv = uv;
        o.pos = f.proj * mv;
        return o;
    }

    vertex HoloOut holoVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                              constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]], constant HoloU& h [[buffer(3)]]) {
        V v = verts[vid];
        return holoShell(float3(v.p), float3(v.n), float2(0.0), f, d, h);
    }

    vertex HoloOut holoUVVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]], constant HoloU& h [[buffer(3)]],
                                const device packed_float2* uvs [[buffer(5)]]) {
        V v = verts[vid];
        return holoShell(float3(v.p), float3(v.n), float2(uvs[vid]), f, d, h);
    }

    // One anti-aliased grid line per unit of c, soft-edged like a projected line.
    float holoLine(float c) {
        float d = abs(fract(c - 0.5) - 0.5);
        float w = max(fwidth(c), 1e-5);
        return 1.0 - smoothstep(w * 0.15, w * 0.95, d);
    }

    // Colour in linear light, not multiplied by its alpha.
    fragment float4 holoFragment(HoloOut in [[stage_in]],
                                 constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]], constant HoloU& h [[buffer(3)]],
                                 texture2d<float> image [[texture(0)]], sampler smp [[sampler(0)]]) {
        float y = in.box.y;
        float time = h.boxSize.w, built = h.state.x, settled = h.state.y, beamAt = h.state.z;

        // Arrival: the model is built from its middle, upwards and downwards at once.
        // Nothing beyond the two fronts exists yet; they are ragged, in blocks, and glow.
        float ragged = (holoHash2(floor(in.box.xz * 24.0)) - 0.5) * 0.05 * (1.0 - settled);
        float since = built + ragged - abs(y - 0.5);
        if (since < 0.0) discard_fragment();
        float frontGlow = (1.0 - smoothstep(0.0, 0.07, since)) * (1.0 - settled);

        float3 toEye = normalize(in.view);
        // The mesh's normal, or the triangle's own where the mesh has none; the shell is
        // seen from both sides, so it is turned to the eye.
        float3 normal = length(in.normal) > 0.0 ? normalize(in.normal) : normalize(cross(dfdx(in.view), dfdy(in.view)) + float3(0.0, 0.0, 1e-20));
        if (dot(normal, toEye) < 0.0) normal = -normal;
        float3 normalWorld = (f.invView * float4(normal, 0.0)).xyz;
        float facing = clamp(dot(normal, toEye), 0.0, 1.0);
        float rim = pow(1.0 - facing, 2.3);
        float hardRim = pow(1.0 - facing, 6.0);

        // Grid projected along the three axes, strongest where the surface turns away
        // from the eye and barely there where it faces it.
        float3 cell = in.box * h.grid.xyz;
        float3 weight = normalWorld * normalWorld;
        weight /= max(weight.x + weight.y + weight.z, 1e-4);
        float grid = max(holoLine(cell.y), holoLine(cell.z)) * weight.x
                   + max(holoLine(cell.x), holoLine(cell.z)) * weight.y
                   + max(holoLine(cell.x), holoLine(cell.y)) * weight.z;
        grid *= mix(0.07, 1.0, pow(smoothstep(0.0, 1.0, 1.0 - facing), 1.7));

        // Mirror the scan about the middle. A single distance field joins the two
        // broad bands without doubling their brightness when they meet.
        float fromMiddle = abs(y - 0.5);
        float distance = abs(fromMiddle - beamAt);
        float beam = (1.0 - smoothstep(0.004, 0.014, distance)
                    + exp(-distance * 55.0) * 0.10) * settled;
        // Independently spaced streams loop in opposite directions, with unequal
        // counts and stable random spacing so the lines never flicker or reshuffle.
        float downCount = max(1.0, round(h.grid.w * (2.0 / 3.0)));
        float upCount = max(1.0, round((h.grid.w + 3.0) * (2.0 / 3.0)));
        float down = holoStreamDistance(y + time * 0.05, downCount, 17.0);
        float up = holoStreamDistance(y - time * 0.05, upCount, 83.0);
        float lines = min(0.65, (exp(-down * 480.0) + exp(-up * 480.0)) * 0.36);
        float breathe = 0.8 + 0.2 * sin(time * 1.35 + in.box.x * 5.0 + in.box.z * 3.0);

        // A light that stays with the camera.
        float diffuse = max(dot(normal, normalize(float3(-0.35, 0.72, 0.58))), 0.0);
        float3 glow = float3(0.05, 0.50, 0.40);
        float3 hot = float3(0.45, 1.0, 0.82);

        float lit = smoothstep(0.0, 0.9, diffuse);
        float3 own = d.baseColor.rgb * image.sample(smp, in.uv).rgb;
        float ownLum = dot(own, float3(0.2126, 0.7152, 0.0722));
        // A bright mint shell whatever the model's own colour (a dark model is only a
        // little deeper in tone). It is see-through, so inner parts and the far side add up.
        float body = mix(0.3, 0.42, smoothstep(0.03, 0.6, ownLum));
        float3 color = glow * body * (0.55 + 0.45 * lit);
        color += hot * (grid * 0.12 + lines * 0.4 + body * rim * 0.9);
        color += glow * (rim * 1.0 + hardRim * 0.5 + lines * 0.55 + grid * 0.38) * breathe;
        color += hot * (beam * 1.1 + frontGlow * 0.9);
        // Strongly coloured parts (lights, glass) show through where the surface faces the eye.
        own *= min(1.0, 0.3 / max(ownLum, 1e-3));
        float ownChroma = max(own.r, max(own.g, own.b)) - min(own.r, min(own.g, own.b));
        color = mix(color, own * 1.15, facing * 0.4 * smoothstep(0.08, 0.3, ownChroma));

        float alpha = 0.34 + rim * 0.4 + grid * 0.1 + lines * 0.2 + beam * 0.5 + frontGlow * 0.6;
        // The far side is fainter than the near one. A shell seen through looks the same
        // from the front and from behind, so that a turning model seemed to swing back and
        // forth; with the near side the stronger, it is seen which way it turns.
        float3 middle = (f.view * float4(f.shadowPlace.x, f.shadowPlace.y + f.shadowSize.z * 0.5, f.shadowPlace.z, 1.0)).xyz;
        float reach = max(max(f.shadowSize.x, f.shadowSize.y), f.shadowSize.z * 0.5);
        float far = smoothstep(-0.6, 0.9, (in.view.z + middle.z) / max(reach, 1e-6));
        float near = mix(1.0, 0.32, far);
        return float4(color * near, clamp(alpha * near, 0.03, 1.0));
    }

    // ---- what is added on top: the two swirls. Strength goes in alpha ------------------

    struct HoloGrain { float4 placeHeight; float4 seed; };
    struct HoloDotOut { float4 pos [[position]]; float size [[point_size]]; float alpha; };

    // The motes of a swirl: each belongs to a point of the surface. As a front comes
    // near that point's height the mote circles the model, wide at first, and winds down
    // onto its point, where it goes out as the front builds the surface there.
    vertex HoloDotOut holoGrainVertex(uint vid [[vertex_id]], const device HoloGrain* grains [[buffer(0)]],
                                      constant FrameU& f [[buffer(1)]], constant HoloU& h [[buffer(3)]]) {
        HoloGrain g = grains[vid];
        float time = h.boxSize.w, seed = g.seed.x, seed2 = fract(seed * 7.31 + 0.17);
        float fromMiddle = g.placeHeight.w - 0.5;
        // 1 a quarter of the height ahead of the front .. 0 as the front arrives.
        float out = (abs(fromMiddle) - h.state.x) / 0.25;
        float turn = fromMiddle >= 0.0 ? 1.0 : -1.0;       // the two swirls turn opposite ways
        float o1 = clamp(out, 0.0, 1.0);
        float3 centre = h.boxMin.xyz + h.boxSize.xyz * 0.5;
        float3 p = g.placeHeight.xyz - centre;
        float angle = turn * (o1 * o1 * (5.0 + 7.0 * seed) + o1 * time * (1.5 + 2.0 * seed2));
        float c = cos(angle), s = sin(angle);
        p.xz = float2(p.x * c - p.z * s, p.x * s + p.z * c) * (1.0 + o1 * (0.2 + 0.6 * seed2));
        p.y -= turn * o1 * (0.25 + 0.5 * seed2) * 0.25 * h.boxSize.y;   // it comes up (or down) with the front
        float twinkle = pow(0.5 + 0.5 * sin(time * 9.0 + seed * 50.0), 3.0);
        HoloDotOut o;
        o.alpha = h.extra.y * smoothstep(0.0, 0.1, out) * (1.0 - smoothstep(0.75, 1.0, out)) * (0.3 + 0.7 * twinkle);
        o.pos = f.viewProj * float4(centre + p, 1.0);
        o.size = (1.4 + 2.6 * twinkle) * h.extra.x;
        return o;
    }

    // A point cloud: its dots, as they appear.
    vertex HoloDotOut holoPointVertex(uint vid [[vertex_id]], const device V* verts [[buffer(0)]],
                                      constant FrameU& f [[buffer(1)]], constant DrawU& d [[buffer(2)]], constant HoloU& h [[buffer(3)]]) {
        float4 world = d.model * float4(float3(verts[vid].p), 1.0);
        float3 box = (world.xyz - h.boxMin.xyz) / h.boxSize.xyz;
        float y = box.y;
        HoloDotOut o;
        o.pos = f.viewProj * world;
        o.size = d.material.z;
        // Brighter along the two scan lines, which leave the middle together (state.z is
        // how far out they are) and are hidden until the shell has settled, as on a surface.
        float fromMiddle = abs(y - 0.5);
        o.alpha = fromMiddle > h.state.x ? 0.0 : 0.45 + 0.5 * exp(-abs(fromMiddle - h.state.z) * 45.0) * h.state.y;
        return o;
    }

    fragment float4 holoDotFragment(HoloDotOut in [[stage_in]], float2 at [[point_coord]]) {
        float dot_ = 1.0 - smoothstep(0.2, 0.5, length(at - 0.5));
        return float4(0.55, 1.0, 0.86, dot_ * in.alpha);
    }

    // The dots of a point cloud lie thick, so they cover each other instead of adding up.
    fragment float4 holoPointFragment(HoloDotOut in [[stage_in]]) {
        return float4(mix(float3(0.05, 0.50, 0.40), float3(0.45, 1.0, 0.82), in.alpha - 0.45), in.alpha);
    }

    struct HoloSwirlOut { float4 pos [[position]]; float2 uv; float glow; };

    // The two swirls themselves: a ribbon of light winding around the model, its head
    // at the front it builds, its tail trailing around what is built already. The first
    // half of the vertices is the swirl going up, the second the one going down.
    constant uint holoSwirlSegments = 96;
    // Heights at which the model's width is known, bottom to top.
    constant uint holoSwirlBands = 16;

    vertex HoloSwirlOut holoSwirlVertex(uint vid [[vertex_id]], constant FrameU& f [[buffer(1)]], constant HoloU& h [[buffer(3)]],
                                        const device float4* outline [[buffer(4)]]) {
        uint corner = vid % 6;
        uint segment = (vid / 6) % holoSwirlSegments;
        float turn = vid / 6 < holoSwirlSegments ? 1.0 : -1.0;
        float along = (corner == 1 || corner == 2 || corner == 4) ? 1.0 : 0.0;
        float side = (corner == 2 || corner == 4 || corner == 5) ? 1.0 : -1.0;
        float time = h.boxSize.w;
        float s = (float(segment) + along) / float(holoSwirlSegments);     // 0 head .. 1 end of the tail
        float angle = turn * (time * 7.0 - s * 2.6 * 6.2831853);
        float front = 0.5 + turn * h.state.x;
        // The tail reaches back to where the swirl started, the middle, and no further.
        float y = clamp(front - turn * s * min(0.42, h.state.x), 0.0, 1.0);
        // Around the model as wide as it is at this height (centre xz, half widths xz), a
        // little clear of it and opening out along the tail.
        float at = y * float(holoSwirlBands - 1);
        uint band = min(uint(at), holoSwirlBands - 2);
        float4 around = mix(outline[band], outline[band + 1], at - float(band));
        float wide = 1.24 + 0.4 * s;
        float3 p = float3(around.x + cos(angle) * around.z * wide, h.boxMin.y + y * h.boxSize.y, around.y + sin(angle) * around.w * wide);
        p.y += side * h.boxSize.y * 0.014 * (1.0 - 0.7 * s);
        HoloSwirlOut o;
        o.pos = f.viewProj * float4(p, 1.0);
        o.uv = float2(s, side);
        o.glow = h.extra.y;
        return o;
    }

    fragment float4 holoSwirlFragment(HoloSwirlOut in [[stage_in]]) {
        float across = 1.0 - in.uv.y * in.uv.y;
        float along = pow(1.0 - in.uv.x, 2.2) + 0.6 * exp(-in.uv.x * 30.0);
        // White at the head, the hologram's own tint along the tail.
        return float4(mix(float3(0.2, 0.9, 0.8), float3(0.85, 1.0, 0.97), exp(-in.uv.x * 10.0)), across * across * along * in.glow * 0.8);
    }

    // ---- glow and the way back to the screen -------------------------------------

    // What is bright in the layer.
    fragment float4 holoBrightFragment(BgOut in [[stage_in]], texture2d<float> layer [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 texel = layer.sample(smp, in.uv);
        float luma = dot(texel.rgb, float3(0.299, 0.587, 0.114));
        return float4(texel.rgb * smoothstep(0.55, 0.56, luma), 1.0);
    }

    struct HoloBlurU { float4 step; };

    fragment float4 holoBlurFragment(BgOut in [[stage_in]], constant HoloBlurU& u [[buffer(0)]],
                                     texture2d<float> source [[texture(0)]], sampler smp [[sampler(0)]]) {
        // A wide, flat bell: as wide as it reaches, so the glow spreads far and thin.
        const float weights[5] = { 0.1347, 0.1305, 0.1188, 0.1017, 0.0817 };
        float3 sum = source.sample(smp, in.uv).rgb * weights[0];
        for (int i = 1; i < 5; i++) {
            sum += source.sample(smp, in.uv + u.step.xy * float(i)).rgb * weights[i];
            sum += source.sample(smp, in.uv - u.step.xy * float(i)).rgb * weights[i];
        }
        return float4(sum, 1.0);
    }

    // Layer and glow, multiplied by their coverage. Surfaces look as if drawn straight to
    // the screen; glow that falls beside the model becomes a veil of its own colour over
    // the background. Worked out as the screen shows it, then handed on as light.
    struct HoloGlowU { float4 near; float4 far; };

    fragment float4 holoOutputFragment(BgOut in [[stage_in]], constant HoloGlowU& u [[buffer(0)]],
                                       texture2d<float> layer [[texture(0)]], texture2d<float> b2 [[texture(1)]],
                                       texture2d<float> b4 [[texture(2)]], texture2d<float> b8 [[texture(3)]],
                                       texture2d<float> b16 [[texture(4)]], texture2d<float> b32 [[texture(5)]], sampler smp [[sampler(0)]]) {
        float4 texel = layer.sample(smp, in.uv);
        texel.rgb += b2.sample(smp, in.uv).rgb * u.near.x + b4.sample(smp, in.uv).rgb * u.near.y + b8.sample(smp, in.uv).rgb * u.near.z
                   + b16.sample(smp, in.uv).rgb * u.near.w + b32.sample(smp, in.uv).rgb * u.far.x;
        float a = clamp(texel.a, 0.0, 1.0);
        float3 surface = toSRGB(texel.rgb / max(a, 1e-3)) * a;
        float3 light = toSRGB(texel.rgb);
        float3 color = mix(light, surface, a);
        float cover = max(a, max(color.r, max(color.g, color.b)));
        return float4(toLinear(color / max(cover, 1e-6)) * cover, cover);
    }
    """
}
