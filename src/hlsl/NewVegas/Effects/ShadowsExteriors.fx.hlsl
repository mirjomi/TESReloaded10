// Image space shadows shader for Oblivion Reloaded
# define viewshadows 0

float4 TESR_ReciprocalResolution;
float4 TESR_WaterSettings; //x: water height in the cell, y: water depth darkness, z: is camera underwater
float4 TESR_ShadowData; // x: quality, y: darkness, z: nearmap resolution, w: farmap resolution
float4 TESR_ShadowFade; // x: fading at sunrise/sunset, y:disabled shadows, z: pointlights shadows
float4 TESR_SkyColor;
float4 TESR_SunAmbient;
float4 TESR_SunColor;
float4 TESR_SunDirection;
float4 TESR_ShadowComposite; // x: use the legacy composite
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
	float3 sunLight = TESR_SunColor.rgb * saturate(dot(world_normal, TESR_SunDirection.xyz));
	float3 shadowFactor = TESR_SunAmbient.rgb / max(TESR_SunAmbient.rgb + sunLight, 0.0001f);

	// DARKNESS is 1 minus the Darkness setting, so at Darkness 1 the shadow is the result above and
	// anything lower lifts it back towards no shadow at all. There is deliberately no way to go
	// darker than this: the sun is already entirely gone, and there is nothing left to remove.
	shadowFactor = lerp(shadowFactor, 1.0f, DARKNESS);

	float3 shading = lerp(shadowFactor, 1.0f, Shadow.r);

	// The composite this replaced, kept switchable so the two can be compared in place. It darkens
	// the pixel by the shadow amount whichever way the surface faces, then blends the result
	// towards the sky colour to stop that reading as a grey wash.
	[branch]
	if (TESR_ShadowComposite.x) {
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
 