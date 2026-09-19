// Ambient occlusion and indirect bounce for the ambient term.
//
// Based on Screen Space Occlusion & Indirect Lighting by Boomstick467, released CC0
// (https://creativecommons.org/publicdomain/zero/1.0/). The occlusion and bounce sampling here
// is his. What changed is where the result goes.
//
// His shader, like the ambient occlusion before it, ended by multiplying the finished frame. That
// darkens light arriving straight from the sun as much as the ambient it should attenuate, which
// is why both carried a luminance mask to spare bright surfaces - a stand-in for knowing which
// part of a pixel is sunlight. The exterior shadow composite does know, so this renders into
// buffers of its own ahead of the composite, and the composite applies it to the ambient term
// only. Where there is no such composite - interiors, or exterior shadows switched off - the
// Apply technique multiplies the frame the way the original did.

float4 TESR_ReciprocalResolution;
float4 TESR_IndirectLightingData;    // x: radius, y: occlusion strength, z: contrast, w: range
float4 TESR_IndirectLightingBounce;  // x: hemisphere bias, y: bounce threshold, z: bounce strength
float4 TESR_IndirectLightingControl; // x: the exterior composite applies the result, y: weight bounce by the sun shadow
float4 TESR_ShadowFade;              // x: sunrise and sunset fade of the sun shadow
float4 TESR_SunColor;
float4 TESR_SunAmbient;

// Declared in register order: NVR binds the Nth declared sampler to slot N. The Compute passes
// render into TESR_IndirectLightingBuffer, so it is deliberately not declared here: every declared
// sampler is bound for every pass, and that would bind the render target as a texture. The scratch
// copy holds the same final result once the last pass has run.
sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SourceBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NormalsBuffer : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };
sampler2D TESR_PointShadowBuffer : register(s4) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_IndirectLightingScratch : register(s5) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };

// Fixed at the values of the original's Ultra preset.
#define USE_TEXTURED_NORMALS 1
#define TEXTURED_NORMALS_STRENGTH 3.0
#define SAMPLE_COUNT 16
#define BLUR_RADIUS 2.0
#define BLUR_THRESHOLD 8.0
#define THICKNESS 4.0
#define SAMPLE_POWER 12.0
#define SPREAD 0.65
#define BLEND_THRESHOLD 0.95
#define SATURATION 2.0

#define RADIUS TESR_IndirectLightingData.x
#define STRENGTH TESR_IndirectLightingData.y
#define CONTRAST TESR_IndirectLightingData.z
#define RANGE TESR_IndirectLightingData.w
#define HEMISPHERE_BIAS TESR_IndirectLightingBounce.x
#define BOUNCE_THRESHOLD TESR_IndirectLightingBounce.y
#define BOUNCE_STRENGTH TESR_IndirectLightingBounce.z

struct VSOUT
{
    float4 vertPos : POSITION;
    float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
    float4 vertPos : POSITION0;
    float2 UVCoord : TEXCOORD0;
};

VSOUT FrameVS(VSIN IN)
{
    VSOUT OUT = (VSOUT)0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return OUT;
}

#include "Includes/Depth.hlsl"
#include "Includes/BlurDepth.hlsl"
#include "Includes/Helpers.hlsl"
#include "Includes/Normals.hlsl"


float hash(float2 p)
{
    return frac(52.9829189 * frac(dot(p, float2(0.06711056, 0.00583715))));
}

float3 random(float2 uv)
{
    float r = hash(uv);
    return frac(float3(r, r * 1.2154, r * 1.3453));
}

// The depth reconstructed normal, roughened with a gradient of the frame so the occlusion picks up
// surface detail the geometry does not have.
float3 GetTexturedNormal(float2 uv)
{
    float3 normal = GetNormal(uv);

#if USE_TEXTURED_NORMALS == 1
    float heightC = tex2D(TESR_RenderedBuffer, uv).r;
    float heightX = tex2D(TESR_RenderedBuffer, uv + float2(TESR_ReciprocalResolution.x, 0.0f)).r;
    float heightY = tex2D(TESR_RenderedBuffer, uv + float2(0.0f, TESR_ReciprocalResolution.y)).r;

    float3 bump = normalize(float3((heightC - heightX) * TEXTURED_NORMALS_STRENGTH, (heightC - heightY) * TEXTURED_NORMALS_STRENGTH, 1.0f));
    normal = normalize(normal + bump);
#endif

    return normal;
}


// Occlusion and bounce, as one RGB multiplier for the ambient light.
float4 Occlusion(VSOUT IN) : COLOR0
{
    float3 origin = reconstructPosition(IN.UVCoord);
    if (origin.z > RANGE) return 1.0f; // neutral

    float3 normal = GetTexturedNormal(IN.UVCoord);
    float3 up = abs(normal.y) < 0.999f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    float3x3 tbn = float3x3(tangent, bitangent, normal);

    // Bounce is gathered from the frame as it stands, and that is before the exterior composite has
    // put the sun shadows into it, so every surface still looks sunlit. Scaling each sample by the
    // sun shadow at that point, down to what a shadowed surface keeps of its light, stops shade
    // bouncing light it does not have. The floor is the ambient's share of the flat lighting.
    float shadowFloor = luma(TESR_SunAmbient.rgb) / max(luma(TESR_SunAmbient.rgb + TESR_SunColor.rgb), 0.0001f);

    float occlusion = 0.0f;
    float3 indirect = 0.0f;

    [unroll]
    for (int i = 0; i < SAMPLE_COUNT; ++i)
    {
        float3 r1 = random(IN.UVCoord * TESR_ReciprocalResolution.xy + i);
        float3 r2 = random(IN.UVCoord * TESR_ReciprocalResolution.yx + i);
        float3 sampleDir = normalize(float3(r1.xy * 2.0f - 1.0f, r2.x));

        float ndot = dot(sampleDir, normal);
        sampleDir *= saturate(ndot - HEMISPHERE_BIAS);
        sampleDir.z = abs(sampleDir.z);
        sampleDir = mul(sampleDir, tbn);

        float scale = pow(float(i) / SAMPLE_COUNT, SAMPLE_POWER);
        scale = lerp(SPREAD, 1.0f, scale);

        float3 samplePos = origin + sampleDir * RADIUS * scale;
        float3 sampleScreen = projectPosition(samplePos);
        float sampleDepth = readDepth(sampleScreen.xy);

        // Blocked when the depth buffer holds a surface in front of the sample point. That surface
        // is both what occludes and what the bounce comes from. Nearer ones count for more, falling
        // to nothing at the radius.
        float closeness = max(RADIUS - abs(sampleDepth - samplePos.z), 0.0f) / RADIUS;
        float occluded = (sampleDepth + THICKNESS < samplePos.z) ? 1.0f : 0.0f;
        occlusion += occluded * closeness;

        [branch]
        if (occluded > 0.0f)
        {
            float3 sampleColor = tex2Dlod(TESR_RenderedBuffer, float4(sampleScreen.xy, 0.0f, 0.0f)).rgb;
            float sun = lerp(TESR_ShadowFade.x, 1.0f, tex2Dlod(TESR_PointShadowBuffer, float4(sampleScreen.xy, 0.0f, 0.0f)).r);
            sampleColor *= lerp(1.0f, lerp(shadowFloor, 1.0f, sun), TESR_IndirectLightingControl.y);

            // The original weighted this by the closeness in world units rather than as a fraction
            // of the radius, so the bounce grew in proportion to the radius. As a fraction, the
            // radius can be tuned for occlusion without changing the bounce; BounceStrength absorbs
            // the factor the old weighting carried.
            float sampleLuma = saturate(luma(sampleColor) - BOUNCE_THRESHOLD);
            indirect += sampleColor * closeness * sampleLuma;
        }
    }

    occlusion = 1.0f - (occlusion / SAMPLE_COUNT) * STRENGTH;
    indirect /= SAMPLE_COUNT;
    indirect = lerp(luma(indirect), indirect, SATURATION);
    float3 multiplier = occlusion + indirect * BOUNCE_STRENGTH;

    // Contrast about neutral, which the original applied when blending. It is affine, so applying
    // it before the blur gives the same result, and the buffer then holds the final multiplier.
    multiplier = lerp(multiplier, 1.0f, -CONTRAST);
    return float4(max(multiplier, 0.0f), 1.0f);
}


// Depth aware blur of the multiplier. A centre weight and all twelve offsets of the shared kernel:
// the original started its loop at the second offset, which drops -6 and keeps +6 and so shifts
// the result half a pixel along each axis.
float4 Blur(VSOUT IN, uniform float2 OffsetMask) : COLOR0
{
    static const float centreWeight = 0.114725602f;

    float depth = readDepth(IN.UVCoord);
    float4 accum = tex2D(TESR_IndirectLightingScratch, IN.UVCoord) * centreWeight;
    float weight = centreWeight;

    for (int i = 0; i < cKernelSize; i++)
    {
        float2 sampleUV = IN.UVCoord + BlurOffsets[i] * OffsetMask * BLUR_RADIUS;
        float useSample = (abs(readDepth(sampleUV) - depth) < BLUR_THRESHOLD) ? BlurWeights[i] : 0.0f;
        accum += tex2Dlod(TESR_IndirectLightingScratch, float4(sampleUV, 0.0f, 0.0f)) * useSample;
        weight += useSample;
    }

    return float4(accum.rgb / weight, 1.0f);
}


// Interiors, and exteriors without the shadow composite: multiply the frame, as the original did.
float4 MultiplyFrame(VSOUT IN) : COLOR0
{
    float3 color = pows(tex2D(TESR_SourceBuffer, IN.UVCoord).rgb, 2.2f); // linearise
    float3 multiplier = tex2D(TESR_IndirectLightingScratch, IN.UVCoord).rgb;

    float lumaMask = saturate((luma(color) - BLEND_THRESHOLD) * 3.0f);
    color *= lerp(multiplier, 1.0f, lumaMask);

    return float4(pows(color, 1.0f / 2.2f), 1.0f);
}


// Renders into the effect's own buffers, ahead of the shadow composite.
technique Compute
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 Occlusion();
    }

    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f));
    }

    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f));
    }
}

// Renders into the frame, where the composite did not take the result.
technique Apply
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 MultiplyFrame();
    }
}
