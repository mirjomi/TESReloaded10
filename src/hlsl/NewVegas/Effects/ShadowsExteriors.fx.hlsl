// Image space shadows shader for Oblivion Reloaded
# define viewshadows 0

float4 TESR_ReciprocalResolution;
float4 TESR_WaterSettings; //x: water height in the cell, y: water depth darkness, z: is camera underwater
float4 TESR_ShadowData; // x: quality, y: darkness, z: nearmap resolution, w: farmap resolution
float4 TESR_ShadowFade; // x: fading at sunrise/sunset, y:disabled shadows, z: pointlights shadows
float4 TESR_SkyColor;      // zenith
float4 TESR_SkyLowColor;   // lower sky
float4 TESR_HorizonColor;
float4 TESR_SunAmbient;
float4 TESR_SunColor;
float4 TESR_SunDirection;
float4 TESR_ShadowComposite; // x: composite mode, y: normal distrust, z: skylighting, w: sun tint
float4 TESR_ShadowScreenSpaceData;

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = ANISOTROPIC; MIPFILTER = LINEAR; };
sampler2D TESR_PointShadowBuffer : register(s2)  = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NormalsBuffer : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };


static const float DARKNESS = max(0.0,1-TESR_ShadowData.y);

struct VSOUT
{
	float4 vertPos : POSITION;
	float4 normal : TEXCOORD1;
	float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
	float4 vertPos : POSITION0;
	float2 UVCoord : TEXCOORD0;
};

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Normals.hlsl"
#include "Includes/Shadows.hlsl"


VSOUT FrameVS(VSIN IN)
{
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

/*
 * Load Shadows Buffer and filter water surfaces 
 * returns a shadow value from darkness setting value (full shadow) to 1 (full light)
*/
float4 Shadow(VSOUT IN) : COLOR0
{
	float4 color = tex2D(TESR_RenderedBuffer, IN.UVCoord);
	float2 uv = IN.UVCoord;

	float depth = readDepth(uv);
	float3 camera_vector = toWorld(uv) * depth;
	float uniformDepth = length(camera_vector);
	float4 world_pos = float4(TESR_CameraPosition.xyz + camera_vector, 1.0f);
	float3 world_normal = GetWorldNormal(IN.UVCoord);

	// early out for underwater surface (if camera is underwater and surface to shade is close to water level with normal pointing downward)
	if (TESR_WaterSettings.z == 1 && world_pos.z < (TESR_WaterSettings.x + 2) && world_pos.z > (TESR_WaterSettings.x - 2) && dot(world_normal, float3(0, 0, -1)) > 0.999) return color;

	float2 Shadow = tex2D(TESR_PointShadowBuffer, IN.UVCoord).rg;
	Shadow.r = lerp(TESR_ShadowFade.x, 1.0f, Shadow.r); // fade shadows to light when sun is low
	Shadow.r = saturate(Shadow.r + Shadow.g * TESR_ShadowFade.z); // point lights light a sun shadow back up

	// What the surface would be lit by with the sun taken away, over what it is lit by now.
	//
	//     lit      = albedo * (sun * saturate(N.L) + ambient)
	//     shadowed = albedo * ambient
	//     shadowed / lit = ambient / (ambient + sun * saturate(N.L))
	//
	// Albedo cancels, so a shadowed pixel can be made from a lit one by multiplication alone - no
	// G buffer, and nothing the object shaders need to know about. TESR_SunColor and
	// TESR_SunAmbient are WorldSky's sunDirectional and sunAmbient, which is the pair the engine's
	// own lighting sums, so the two terms are directly comparable.
	//
	// Two things fall out of this that the flat darkening it replaces had to fake. A surface facing
	// away from the sun is left alone, because it was never in sunlight and removing the sun from
	// it changes nothing - previously every shadowed pixel was darkened regardless of which way it
	// faced. And shadowed surfaces end up the colour of the ambient by construction, which is what
	// the sky tint blended in above was approximating.
	//
	// The terms are used as they arrive rather than linearised first. This pass runs on the frame
	// after the game's own tone mapping, and the constants share that encoding, so a pow on only
	// one side of the comparison pulls the two apart - which is what it looked like when tried.
	// The normals buffer is not read from geometry - Normals.fx reconstructs it from depth with a
	// cross product of screen derivatives. Alpha tested foliage under DXVK's coverage dither writes
	// a depth checkerboard, so over grass that reconstruction alternates per pixel, and feeding it
	// to the ratio turned an alpha pattern into a brightness one.
	//
	// Sampling half a texel off centre makes the bilinear filter average an exact two by two block,
	// and a two by two block of a checkerboard holds two of each phase, so the pattern cancels
	// outright rather than being attenuated. A four tap cross would not have: the four neighbours
	// of a checkerboard cell are all the opposite phase, which is the trap this codebase has walked
	// into twice before. It costs one offset and no extra taps, and the ratio is a low frequency
	// quantity that does not need its normal placed to the pixel.
	float2 normalUv = uv + 0.5f * TESR_ReciprocalResolution.xy;
	float3 ratioNormal = GetWorldNormal(normalUv);

	// Normals.fx publishes how planar the depth around a pixel was, and over grass the
	// answer is not at all: depth there alternates between blade and ground, the
	// reconstruction has no single surface to describe, and the half texel average above
	// only softens the damage. Where the normal cannot be read, fall back on not using
	// one. The shadow keeps its strength and its ambient colour and gives up only the
	// orientation term, which is the part that was never knowable there.
	float confidence = tex2D(TESR_NormalsBuffer, normalUv).a;
	float trust = saturate(1.0f - (1.0f - confidence) * TESR_ShadowComposite.y);

	// Mode 2 forces the normal term to 1, which is the only input the ratio takes that the path it
	// replaced did not. If an artefact survives that, the normal is not what is producing it.
	float NdotL = lerp(1.0f, saturate(dot(ratioNormal, TESR_SunDirection.xyz)), trust);
	if (TESR_ShadowComposite.x == 2.0f) NdotL = 1.0f;
	float3 sunLight = TESR_SunColor.rgb * NdotL;
	float3 ambientFlat = TESR_SunAmbient.rgb;

	// Directional sky ambient. The weather ambient is one colour for every surface whichever way
	// it faces; the sky is not. A surface looking up sees the zenith, one looking sideways sees
	// the lower sky and the horizon, one looking down sees bounce off the ground. All three
	// colours are already published as constants, so this needs nothing computed on the CPU.
	//
	// It REDISTRIBUTES the ambient rather than adding to it. The gradient is rescaled to carry
	// the same luminance as the flat ambient it replaces, so turning this up cannot make the
	// scene brighter - it can only move light from one orientation to another. That is what
	// keeps it neutral at its default, and it is the reason it needs no brightness control of
	// its own to compensate for one it introduced.
	//
	// Ground bounce has no constant of its own, and the flat ambient is the closest thing to one:
	// it is the light the weather says is arriving from everywhere, which for a downward facing
	// surface is very nearly what the ground sends back.
	// A surface never sees one point of the sky, it sees a whole hemisphere, so the colour that
	// reaches it is a cosine weighted average over what is up there rather than the colour
	// directly along its normal. Reaching the zenith colour for an upward facing surface was the
	// first version of this and it turned the desert to ice: the zenith is the most saturated
	// blue in the sky and nothing is lit by it alone.
	//
	// Weighting by cos(theta)sin(theta) puts the most weight around 45 degrees, so the average of
	// a zenith-to-horizon gradient sits near the middle of it. That average is the most sky any
	// surface can receive:
	//
	//     facing up          the whole sky dome, averaged
	//     facing sideways    half sky, half ground
	//     facing down        ground
	//
	// which is one lerp, and never reaches the zenith at all.
	float3 skyLow = lerp(TESR_HorizonColor.rgb, TESR_SkyLowColor.rgb, 0.5f);
	float3 skyAverage = lerp(skyLow, TESR_SkyColor.rgb, 0.5f);

	// The sky is not the same colour in every direction. It scatters forward, so it runs closer
	// to the sun's own colour near the sun and cooler away from it, and a surface facing the
	// sun's half of the dome collects more of that. A purely vertical gradient cannot express it:
	// two walls facing opposite ways get an identical ambient from one. This is the part of that
	// asymmetry that is actually visible, for three instructions, rather than projecting the whole
	// dome onto spherical harmonics to arrive somewhere very close at ordinary strengths.
	//
	// Hue only. The sky near the sun is genuinely brighter as well, but letting that through would
	// mean a surface could end up with more ambient than it started with, and this effect not
	// being able to brighten the scene is the property the whole design rests on. Renormalising
	// to the untinted luminance keeps it a redistribution of colour rather than of light.
	[branch]
	if (TESR_ShadowComposite.w > 0.0f) {
		float sunFacing = saturate(dot(ratioNormal, TESR_SunDirection.xyz));
		float3 tinted = lerp(skyAverage, TESR_SunColor.rgb, sunFacing * TESR_ShadowComposite.w);
		skyAverage = tinted * (luma(skyAverage) / max(luma(tinted), 0.0001f));
	}

	// Where the normal is unreadable this falls back to the orientation it cannot determine, not
	// to no skylighting at all. Falling back to the flat weather ambient was the first attempt
	// and it is wrong in a way that shows: grass kept a warm ambient while the ground beside it
	// went cool, so two touching surfaces disagreed about what colour the light was. Dropping the
	// N.L term where the normal is unknown is a small error; dropping the colour temperature with
	// it is a large and very visible one. Halfway up is the honest answer for a surface whose
	// orientation is unknown - half sky, half ground - and it keeps the colour consistent while
	// giving up only the variation that was never computable there.
	float orientation = lerp(0.5f, saturate(ratioNormal.z * 0.5f + 0.5f), trust);
	float3 skyDir = lerp(ambientFlat, skyAverage, orientation);

	// Rescale to the flat ambient's luminance, so only the direction of the light changes.
	float3 skyMean = lerp(ambientFlat, skyAverage, 0.5f);
	skyDir *= luma(ambientFlat) / max(luma(skyMean), 0.0001f);

	float3 ambientDir = lerp(ambientFlat, skyDir, saturate(TESR_ShadowComposite.z));

	// One expression for both. The sun is attenuated by visibility, the ambient is replaced by
	// its directional form, and the whole thing is divided by what the pixel was lit by. With no
	// skylighting and no shadow it is exactly 1, so neutral is neutral by construction rather
	// than by tuning.
	float vis = lerp(Shadow.r, 1.0f, DARKNESS);
	float3 shading = (sunLight * vis + ambientDir) / max(sunLight + ambientFlat, 0.0001f);

	// DARKNESS is 1 minus the Darkness setting. At Darkness 1 the sun is fully removed where the
	// shadow says it should be, and anything lower lets some of it back through. There is
	// deliberately no way to go darker: the sun is already entirely gone.

	// Mode 3 shows what is about to be multiplied in, so an artefact can be attributed to this
	// pass or ruled out of it without guessing from the composited result.
	[branch]
	if (TESR_ShadowComposite.x == 3.0f) return float4(shading, 1.0f);
	[branch]
	if (TESR_ShadowComposite.x == 4.0f) return float4(ratioNormal * 0.5f + 0.5f, 1.0f);
	[branch]
	if (TESR_ShadowComposite.x == 5.0f) return float4(world_normal * 0.5f + 0.5f, 1.0f);
	[branch]
	if (TESR_ShadowComposite.x == 6.0f) return float4(trust.xxx, 1.0f);
	[branch]
	if (TESR_ShadowComposite.x == 7.0f) return float4(ambientDir, 1.0f);

	// The composite this replaced, kept switchable so the two can be compared in place. It darkens
	// the pixel by the shadow amount whichever way the surface faces, then blends the result
	// towards the sky colour to stop that reading as a grey wash.
	[branch]
	if (TESR_ShadowComposite.x == 1.0f) {
		float legacy = lerp(0.0f, lerp(1.0f, luma(TESR_SunAmbient), DARKNESS * TESR_ShadowFade.z), Shadow.r);
		legacy = saturate(lerp(DARKNESS, 1.0f, legacy));

		float3 lin = pows(color.rgb, 2.2);
		float3 sky = pows(TESR_SkyColor.rgb, 2.2);
		float3 tinted = luma(lin) * legacy * sky;
		tinted = lerp(tinted, lin * legacy, saturate(legacy + 0.5f));
		color.rgb = pows(max(0.0f, tinted), 1.0f / 2.2f);

#if viewshadows == 1
		return float4(legacy.xxx, 1.0f);
#endif
		return float4(color.rgb, 1.0f);
	}

#if viewshadows == 1
	return float4(shading, 1.0f);
#endif
	return float4(color.rgb * shading, 1.0f);
}


technique {
	pass {
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 Shadow();
	}
}
 