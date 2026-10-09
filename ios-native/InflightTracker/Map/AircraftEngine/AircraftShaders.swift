import simd

/// The engine's GPU programs, and the structures shared with them.
///
/// Compiled from source when the map first asks the engine to draw, rather
/// than built into the app's default library: the engine is one self-contained
/// piece, and the compile is a few milliseconds once a session.
///
/// Every structure here has a twin in `source` and the two must agree to the
/// byte. Each is laid out in 16-byte columns so Swift and Metal agree on it
/// without packing rules.
enum AircraftShaders {

    /// One vertex: position, normal, texture coordinate, as eight floats.
    static let vertexStride = 32

    /// One aeroplane on one frame.
    struct Instance {
        /// Model metres to clip space, on the flat map.
        var mercator: simd_float4x4
        /// The same on the globe; equal to `mercator` when there is no globe.
        var globe: simd_float4x4
        /// Model directions to east, north and up, for the lighting.
        var rotation0: SIMD4<Float>
        var rotation1: SIMD4<Float>
        var rotation2: SIMD4<Float>
        /// A colour mixed into the model, and how much of it.
        var tint: SIMD4<Float>
        /// Towards the sun where this aeroplane is, in east, north and up
        /// (xyz), and how much daylight there is there (w): 1 in full day,
        /// 0 at night.
        var light: SIMD4<Float>
    }

    struct FrameUniforms {
        /// How far from the flat map towards the globe: 0 flat, 1 globe.
        var transition: Float
        var ambient: Float
        var diffuse: Float
        var emission: Float
        /// Unused direction (xyz); how much light reaches a model at night,
        /// from the moon, the sky glow and the airfield (w).
        var light: SIMD4<Float>
    }

    /// One corner of the flown path: already in clip space, and its colour.
    struct PathVertex {
        var position: SIMD4<Float>
        var colour: SIMD4<Float>
    }

    /// One corner of a glow — a light, or a shadow: in clip space, its
    /// colour, and where the corner is across the glow (±1, ±1).
    struct GlowVertex {
        var position: SIMD4<Float>
        var colour: SIMD4<Float>
        var corner: SIMD4<Float>
    }

    struct MaterialUniforms {
        var baseColor: SIMD4<Float>
        /// Glow, and whether the picture is used (w).
        var emissive: SIMD4<Float>
        /// Cut-out threshold, or −1 (x); whether the material blends (y).
        var alpha: SIMD4<Float>
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct PackedVertex {
        packed_float3 position;
        packed_float3 normal;
        packed_float2 uv;
    };

    struct Instance {
        float4x4 mercator;
        float4x4 globe;
        float4 rotation0;
        float4 rotation1;
        float4 rotation2;
        float4 tint;
        float4 light;
    };

    struct FrameUniforms {
        float transition;
        float ambient;
        float diffuse;
        float emission;
        float4 light;
    };

    struct MaterialUniforms {
        float4 baseColor;
        float4 emissive;
        float4 alpha;
    };

    struct Varyings {
        float4 position [[position]];
        float3 normal;
        float2 uv;
        float4 tint;
        float4 light;
    };

    vertex Varyings aircraftVertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device PackedVertex *vertices [[buffer(0)]],
                                   const device Instance *instances [[buffer(1)]],
                                   constant FrameUniforms &frame [[buffer(2)]])
    {
        PackedVertex v = vertices[vid];
        Instance aircraft = instances[iid];
        float4 local = float4(float3(v.position), 1.0);

        Varyings out;
        out.position = mix(aircraft.mercator * local, aircraft.globe * local, frame.transition);
        float3x3 rotation = float3x3(aircraft.rotation0.xyz, aircraft.rotation1.xyz, aircraft.rotation2.xyz);
        out.normal = rotation * float3(v.normal);
        out.uv = float2(v.uv);
        out.tint = aircraft.tint;
        out.light = aircraft.light;
        return out;
    }

    fragment float4 aircraftFragment(Varyings in [[stage_in]],
                                     constant MaterialUniforms &material [[buffer(0)]],
                                     constant FrameUniforms &frame [[buffer(1)]],
                                     texture2d<float> picture [[texture(0)]],
                                     sampler linearSampler [[sampler(0)]])
    {
        float4 base = material.baseColor;
        if (material.emissive.w > 0.5) {
            base *= picture.sample(linearSampler, in.uv);
        }
        if (material.alpha.x >= 0.0 && base.a < material.alpha.x) {
            discard_fragment();
        }
        float alpha = material.alpha.y > 0.5 ? base.a : 1.0;

        // Lit by the sun where the aeroplane is, from both sides: thin
        // surfaces in these models face either way. At night only the dim
        // light of the night is left.
        float3 normal = normalize(in.normal);
        float daylight = in.light.w;
        float lambert = abs(dot(normal, normalize(in.light.xyz)));
        float ambient = mix(frame.light.w, frame.ambient, daylight);
        float3 colour = base.rgb * (ambient + frame.diffuse * daylight * lambert)
            + material.emissive.rgb * frame.emission;
        colour = mix(colour, in.tint.rgb, in.tint.a);
        return float4(colour * alpha, alpha);
    }

    struct PathVertex {
        float4 position;
        float4 colour;
    };

    struct PathVaryings {
        float4 position [[position]];
        float4 colour;
    };

    vertex PathVaryings pathVertex(uint vid [[vertex_id]],
                                   const device PathVertex *vertices [[buffer(0)]])
    {
        PathVaryings out;
        out.position = vertices[vid].position;
        out.colour = vertices[vid].colour;
        return out;
    }

    fragment float4 pathFragment(PathVaryings in [[stage_in]])
    {
        return float4(in.colour.rgb * in.colour.a, in.colour.a);
    }

    struct GlowVertex {
        float4 position;
        float4 colour;
        float4 corner;
    };

    struct GlowVaryings {
        float4 position [[position]];
        float4 colour;
        float2 corner;
    };

    vertex GlowVaryings glowVertex(uint vid [[vertex_id]],
                                   const device GlowVertex *vertices [[buffer(0)]])
    {
        GlowVaryings out;
        out.position = vertices[vid].position;
        out.colour = vertices[vid].colour;
        out.corner = vertices[vid].corner.xy;
        return out;
    }

    // Brightest in the middle, nothing at the edge of the quad.
    fragment float4 glowFragment(GlowVaryings in [[stage_in]])
    {
        float r2 = dot(in.corner, in.corner);
        float strength = exp(-3.2 * r2) * saturate(1.0 - r2);
        float alpha = in.colour.a * strength;
        return float4(in.colour.rgb * alpha, alpha);
    }
    """
}
