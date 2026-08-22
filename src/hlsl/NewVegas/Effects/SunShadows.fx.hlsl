// Image space shadows shader for Oblivion Reloaded

float4x4 TESR_WorldViewProjectionTransform;
float4x4 TESR_ShadowCameraToLightTransformNear;
float4x4 TESR_ShadowCameraToLightTransformMiddle;
float4x4 TESR_ShadowCameraToLightTransformFar;
float4x4 TESR_ShadowCameraToLightTransformLod;
float4 TESR_ReciprocalResolution;
float4 TESR_SmoothedSunDir;
float4 TESR_ViewSpaceLightDir;
float4 TESR_ShadowData; // x: quality, y: darkness, z: texel size
float4 TESR_ShadowFormatData; // x: mode, y: format bits per pixels
float4 TESR_ShadowScreenSpaceData; // x: Enabled, y: blurRadius, z: renderDistance, w: intensity
float4 TESR_SunAmbient;
float4 TESR_ShadowFade; // x: sunset attenuation, y: shadows maps active, z: point lights shadows active
float4 TESR_ShadowBiasData; // x: normal bias (texels), y: slope bias (texels), z: 1 / cascade resolution
float4 TESR_ShadowFilterData; // x: filter radius (texels), y: light bleed reduction scale
float4 TESR_ShadowTemporalData; // x: enabled, y: history weight
float4 TESR_ShadowCameraDelta; // xyz: current camera position minus the history's
float4x4 TESR_ShadowPreviousViewProj;
float4x4 TESR_ShadowPreviousViewTransform;
float4 TESR_ShadowNearCenter; // x,y,z: center (world space), w: radius
float4 TESR_ShadowMiddleCenter; // x,y,z: center (world space), w: radius
float4 TESR_ShadowFarCenter; // x,y,z: center (world space), w: radius
float4 TESR_ShadowLodCenter; // x,y,z: center (world space), w: radius

sampler2D TESR_DepthBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_ShadowAtlas : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NormalsBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_PointShadowBuffer : register(s3)  = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NoiseSampler : register(s4)< string ResourceName = "Effects\bluenoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
// Must stay last, and the register numbers must keep matching declaration order: the engine binds
// the Nth declared sampler to slot N and finds its sampler state by searching the source for
// "register ( sN )" with that same N. Inserting a sampler above an existing one silently rebinds
// everything below it.
sampler2D TESR_ShadowHistoryBuffer : register(s5) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D TESR_ShadowDepthHistoryBuffer : register(s6) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_ShadowNormalsHistoryBuffer : register(s7) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

#define SSS_STEPNUM 5

static const float DARKNESS = 1-TESR_ShadowData.y;
static const float SSS_DIST = 2000;
static const float SSS_THICKNESS = 20;
static const float SSS_MAXDEPTH = TESR_ShadowScreenSpaceData.z * TESR_ShadowScreenSpaceData.x;

static const float Mode = TESR_ShadowFormatData.x;
static const float FormatBits = TESR_ShadowFormatData.y;
static const float EVSMExponent = TESR_ShadowFormatData.w;

// World size of one shadow map texel in a cascade of the given bounding radius. Every cascade
// renders into the same resolution, so this is the only thing that differs between them - and it
// spans more than an order of magnitude from Near to Lod.
float CascadeTexelSize(float cascadeRadius) {
	return 2.0f * cascadeRadius * TESR_ShadowBiasData.z;
}

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
#include "Includes/Shadows.hlsl"
#include "Includes/Normals.hlsl"
#include "Includes/BlurDepth.hlsl"


VSOUT FrameVS(VSIN IN)
{
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

float4 ScreenCoordToTexCoord(float4 coord){
	// apply perspective (perspective division) and convert from -1/1 to range to 0/1 (shadowMap range);
	coord.xyz /= coord.w;
	coord.x = coord.x * 0.5f + 0.5f;
	coord.y = coord.y * -0.5f + 0.5f;

	return coord;
}

// Light space coordinate for one cascade, including that cascade's normal offset.
// Pure arithmetic - no atlas read - so it is cheap enough to do for all four.
float4 CascadeCoord(float4x4 lightTransform, float4 positionWS, float3 offsetPerTexel, float cascadeRadius) {
    float4 coord = float4(positionWS.xyz + offsetPerTexel * CascadeTexelSize(cascadeRadius), 1.0f);
    return ScreenCoordToTexCoord(mul(coord, lightTransform));
}

// Average the moments across a footprint, then run the test once on the average.
//
// This is the whole point of storing moments rather than depths: they are linearly filterable, so
// the mean of the moments over an area describes that area, while the mean of four finished
// yes/no answers does not. Sampling a single texel makes the test a point sample of a near binary
// function, and a point sample of a near binary function is exactly what flips when the sun turns
// the sampling by a fraction of a texel.
//
// The radius is in texels, so the footprint tracks texel size across the cascades - and since
// cascade texels roughly track screen pixels, the softening it costs stays about constant on
// screen instead of growing with distance.
float4 FilterMoments(float2 uv, float2 quadrant) {
    float atlasTexel = 0.5f * TESR_ShadowBiasData.z; // the atlas packs four cascades 2x2
    float r = TESR_ShadowFilterData.x * atlasTexel;

	// Taps must stay inside this cascade's quadrant or they read a neighbouring cascade.
    float2 lo = quadrant + atlasTexel;
    float2 hi = quadrant + 0.5f - atlasTexel;

	// Explicit LOD: the taps sit inside a dynamic branch, where there are no gradients to derive
	// a mip level from. The atlas has no mip chain anyway, so level 0 is the only correct one.
    float4 moments  = tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + float2(-r, -r), lo, hi), 0.0f, 0.0f));
    moments += tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + float2( r, -r), lo, hi), 0.0f, 0.0f));
    moments += tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + float2(-r,  r), lo, hi), 0.0f, 0.0f));
    moments += tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + float2( r,  r), lo, hi), 0.0f, 0.0f));
    return moments * 0.25f;
}

float SampleCascade(float4 lightSpaceCoord, float2 quadrant, float bias, float bleedReduction) {
	// Offset to the correct position in the atlas.
    float2 uv = lightSpaceCoord.xy * 0.5f + quadrant;

    float4 moments = FilterMoments(uv, quadrant);

	// The bleed reduction rescales (amount, 1] onto [0, 1], so it is also a contrast stretch on
	// whatever noise the test produces - by 5x on the furthest cascade, where the values are
	// 0.8. Scalable so that trade is visible rather than baked in.
    float bleed = saturate(bleedReduction * TESR_ShadowFilterData.y);

	[branch]
    if (Mode == 0.0f)
        return GetLightAmountValueVSM(moments.xy, lightSpaceCoord.z, bias, bleed);
    else if (Mode == 1.0f)
        return GetLightAmountValueEVSM2(moments.xy, lightSpaceCoord.z, bias, bleed, FormatBits, EVSMExponent);

    return GetLightAmountValueEVSM4(moments, lightSpaceCoord.z, bias, bleed, FormatBits, EVSMExponent);
}

float GetLightAmount(float4 positionWS, float3 normal)
{
	// Normal offset. The receiver is nudged along its normal so that it samples a texel whose
	// stored depth belongs to a point in front of the surface, instead of the texel containing
	// the surface itself - which stores a single depth for a patch the surface ramps across, and
	// so cannot say whether this particular point is above or below it.
	//
	// The distance that takes is one texel, measured in world units, and it therefore has to be
	// computed PER CASCADE: all four render at the same resolution but cover wildly different
	// areas, so a texel is around a quarter of a unit on Near and several units on Lod. A single
	// world space offset shared by all four - which is what this used to be - can only be right
	// for one of them. It was sized for Near, leaving the outer cascades biased at a fraction of
	// what they need, which is why the shimmer grew with distance and shrank with resolution.
	//
	// sin(theta) is the geometrically correct shape: the lateral distance from the surface point
	// to the edge of its own texel footprint grows with the angle between the normal and the
	// light, and saturates when the light is edge on.
    float NdotL = dot(normal, TESR_SmoothedSunDir.xyz);
    float sinTheta = sqrt(saturate(1.0f - NdotL * NdotL));
    float3 offsetPerTexel = normal * (TESR_ShadowBiasData.x * sinTheta);

    const float bias = Mode == 0.0f ? 0.00001f : 0.01f;

    const float blend = 0.9f;

    float4 distances = {
        length(positionWS.xyz - TESR_ShadowNearCenter.xyz),
		length(positionWS.xyz - TESR_ShadowMiddleCenter.xyz),
		length(positionWS.xyz - TESR_ShadowFarCenter.xyz),
		length(positionWS.xyz - TESR_ShadowLodCenter.xyz),
    };

    float4 coordNear = CascadeCoord(TESR_ShadowCameraToLightTransformNear, positionWS, offsetPerTexel, TESR_ShadowNearCenter.w);
    float4 coordMiddle = CascadeCoord(TESR_ShadowCameraToLightTransformMiddle, positionWS, offsetPerTexel, TESR_ShadowMiddleCenter.w);
    float4 coordFar = CascadeCoord(TESR_ShadowCameraToLightTransformFar, positionWS, offsetPerTexel, TESR_ShadowFarCenter.w);
    float4 coordLod = CascadeCoord(TESR_ShadowCameraToLightTransformLod, positionWS, offsetPerTexel, TESR_ShadowLodCenter.w);

	// Pick the cascade this pixel falls in, and the one it blends into at the far edge of it, and
	// read only those. Every pixel used to sample all four and discard three - four atlas reads to
	// use one. Spending that budget on the filter above instead costs nothing outside a blend band.
    float4 coordA, coordB;
    float2 quadrantA, quadrantB;
    float bleedA, bleedB;
    float mix;
    bool blendToCascade;

    if (distances.x < TESR_ShadowNearCenter.w) {
        coordA = coordNear;   quadrantA = float2(0.0f, 0.0f); bleedA = 0.1f;
        coordB = coordMiddle; quadrantB = float2(0.5f, 0.0f); bleedB = 0.2f;
        mix = smoothstep(TESR_ShadowNearCenter.w * blend, TESR_ShadowNearCenter.w, distances.x);
        blendToCascade = true;
    }
    else if (distances.y < TESR_ShadowMiddleCenter.w) {
        coordA = coordMiddle; quadrantA = float2(0.5f, 0.0f); bleedA = 0.2f;
        coordB = coordFar;    quadrantB = float2(0.0f, 0.5f); bleedB = 0.6f;
        mix = smoothstep(TESR_ShadowMiddleCenter.w * blend, TESR_ShadowMiddleCenter.w, distances.y);
        blendToCascade = true;
    }
    else if (distances.z < TESR_ShadowFarCenter.w) {
        coordA = coordFar; quadrantA = float2(0.0f, 0.5f); bleedA = 0.6f;
        coordB = coordLod; quadrantB = float2(0.5f, 0.5f); bleedB = 0.8f;
        mix = smoothstep(TESR_ShadowFarCenter.w * blend, TESR_ShadowFarCenter.w, distances.z);
        blendToCascade = true;
    }
    else if (distances.w < TESR_ShadowLodCenter.w) {
        coordA = coordLod; quadrantA = float2(0.5f, 0.5f); bleedA = 0.8f;
        coordB = coordLod; quadrantB = float2(0.5f, 0.5f); bleedB = 0.8f;
        mix = smoothstep(TESR_ShadowLodCenter.w * blend, TESR_ShadowLodCenter.w, distances.w);
        blendToCascade = false; // past the last cascade there is nothing to blend into but light
    }
    else {
        return 1.0f;
    }

    float shadowA = SampleCascade(coordA, quadrantA, bias, bleedA);

	[branch]
    if (mix <= 0.0f) return shadowA;

    float shadowB = 1.0f;
	[branch]
    if (blendToCascade) shadowB = SampleCascade(coordB, quadrantB, bias, bleedB);

    return lerp(shadowA, shadowB, mix);
}

// returns a semi random float3 between 0 and 1 based on the given seed. (blue noise)
// tailored to return a different value for each uv coord of the screen.
float3 random(float2 seed)
{
	return tex2D(TESR_NoiseSampler, (seed/256 + 0.5) / TESR_ReciprocalResolution.xy).xyz;
}

float4 ScreenSpaceShadow(VSOUT IN) : COLOR0
{	
	// calculates wether a point is in shadow based on screen depth
	float2 uv = IN.UVCoord;
	// clip((uv < 0.5) - 1);
	// uv *= 2;

    float4 color = tex2D(TESR_PointShadowBuffer, IN.UVCoord);
	if (!TESR_ShadowScreenSpaceData.x) return float4(1.0, color.g, 0, 1); // skip is screenspace shadows are disabled

	float3 pos = reconstructPosition(uv);// + expand(random3); 

	float bias = 0.01;
	if (pos.z > SSS_MAXDEPTH) return float4(1.0, color.g, 0, 1); // early out for pixels further away than the max render distance
	
    float3 random3 = random(uv);
    float rand = lerp(min(0.8f, pos.z / SSS_MAXDEPTH), 1.0f, random3.r); // some noise to vary the ray length

	// scale the step with distance, and randomize length
	float depth = getHomogenousDepth(uv) / farZ;
	float3 step = pows(depth, 0.6) * (SSS_DIST / SSS_STEPNUM) * TESR_ViewSpaceLightDir.xyz * rand;
	float thickness = pows(depth, 0.6) * SSS_THICKNESS;

	float occlusion = 0.0;
	float total = 0;

	// Doing two steps at once to optimize the depth march
	[unroll]
	for (float i = 1; i < SSS_STEPNUM; i+=2){
		float step1 = i;
		float step2 = i + 1;

		float3 pos1 = pos + step1 * step; // we move to the light with bigger steps each time
		float3 pos2 = pos1 + step2 * step; // we move to the light with bigger steps each time
		
		// if (screen_pos.x > 0 && screen_pos.x < 1.0 && screen_pos.y > 0 && screen_pos.y <1){
		float2 depth = {pos1.z, pos2.z};
		float2 depthCompare = {
			readDepth(projectPosition(pos1).xy),
			readDepth(projectPosition(pos2).xy),
		};

		float2 depthDelta = depth - depthCompare;

		occlusion += (depthDelta.x > bias && depthDelta.x < SSS_THICKNESS)/step1; // in Shadow
		occlusion += (depthDelta.y > bias && depthDelta.y < SSS_THICKNESS)/step2; // in Shadow
		pos = pos2; 
		total += 1/step1 + 1/step2; // weight samples inversely with distance
	}

    occlusion = pows(occlusion / total, 0.3); // get an average shading based on total weights
	

    // save result of SSS in red channel, and fade contribution with distance
    color.r = lerp(1.0f - occlusion, 1.0, smoothstep(SSS_MAXDEPTH * 0.8, SSS_MAXDEPTH, pos.z));
    return color;
}

// returns a shadow value from darkness setting value (full shadow) to 1 (full light)
float4 Shadow(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;

    float viewDepth;
    float4 worldPos = reconstructWorldPosition(uv, viewDepth);

	// Sample Screen Space shadows
	float4 Shadow = tex2D(TESR_PointShadowBuffer, IN.UVCoord);
    Shadow = pow(Shadow, TESR_ShadowScreenSpaceData.w);
	if (!TESR_ShadowFade.y) return Shadow; // disable shadow maps if ShadowFade.y == 0 (setting for shadow map disabled)

	// Sample shadows from shadowmaps
    float3 normal = GetWorldNormal(uv);
	float sunShadows = GetLightAmount(worldPos, normal); 

	Shadow.r = min(Shadow.r, sunShadows); // get the darkest between Screenspace & Sun shadows

	return Shadow;
}


// Reuse the previous frame's shadow term where it still describes the same surface.
//
// The sun turns about 3e-5 radians per frame, which moves a shadow by a few hundredths of a texel
// - far below anything visible. What that motion does do is drag the shadow map across its own
// sampling lattice, and every silhouette texel it crosses flips between the caster's depth and
// the background's. So virtually all of the frame to frame change in the shadow term is
// re-quantisation noise sitting on top of a signal that is, over any single frame, static.
//
// Averaging over frames removes the first and leaves the second: real shadow motion is slower
// than the filter's response, so it passes through, while noise that is uncorrelated between
// frames is divided down. Spatial filtering cannot make that distinction, which is why widening
// it only ever traded shimmer for mush.
float4 TemporalShadow(VSOUT IN) : COLOR0
{
    float4 current = tex2D(TESR_PointShadowBuffer, IN.UVCoord);

	[branch]
    if (TESR_ShadowTemporalData.x < 0.5f) return current;

    float viewDepth;
    float4 worldPos = reconstructWorldPosition(IN.UVCoord, viewDepth);

	// World space here is relative to the current camera, so shift the point back into the frame
	// the history belongs to before projecting it with that frame's matrix.
    float4 previousClip = mul(float4(worldPos.xyz + TESR_ShadowCameraDelta.xyz, 1.0f), TESR_ShadowPreviousViewProj);

	[branch]
    if (previousClip.w <= 0.0f) return current; // behind the previous camera

    float2 previousUV = previousClip.xy / previousClip.w;
    previousUV = float2(previousUV.x * 0.5f + 0.5f, previousUV.y * -0.5f + 0.5f);

	[branch]
    if (previousUV.x < 0.0f || previousUV.x > 1.0f || previousUV.y < 0.0f || previousUV.y > 1.0f)
        return current; // off screen last frame, nothing to reuse

	// The reprojection finds where this point WAS on screen, not whether it was visible there.
	// Where something else was in front of it the history belongs to that occluder, and reusing
	// it smears the occluder's shadow along every disocclusion edge as the camera moves.
    float previousDepth = tex2D(TESR_ShadowDepthHistoryBuffer, previousUV).x * farZ;
    float tolerance = max(0.02f * previousClip.w, 5.0f);

	[branch]
    if (abs(previousClip.w - previousDepth) > tolerance) return current;

	// Depth says the reprojected pixel is the right DISTANCE away, not that it is the same
	// surface. An object moving across the view while holding its distance passes that test with
	// history belonging to something else, which is what smears shadows over the weapon and over
	// the player. Surface orientation is the missing half: reproject a static surface correctly
	// and it presents the same world normal, because that is what being the same surface means.
	//
	// Both normals are view space, so each has to be lifted into world space with the view matrix
	// of the frame it came from, or simply turning the camera would look like the surface changing.
    float3 currentNormalWS = mul(TESR_ViewTransform, float4(tex2D(TESR_NormalsBuffer, IN.UVCoord).xyz * 2.0f - 1.0f, 1.0f)).xyz;
    float3 historyNormalWS = mul(TESR_ShadowPreviousViewTransform, float4(tex2D(TESR_ShadowNormalsHistoryBuffer, previousUV).xyz * 2.0f - 1.0f, 1.0f)).xyz;

	// Not a tunable, and not an arbitrary constant either. Both directions were measured, and it
	// sits where it does for margin rather than for being optimal here.
	//
	// Too loose and moving surfaces are accepted: 0.9, which is 26 degrees, still let a great deal
	// of trailing through, and 0.999 was a large improvement over it. So there is no room below.
	// The reason 26 degrees is not enough is that TESR_NormalsBuffer is not raw normals - the
	// Normals effect runs an edge aware blur over it in place. That smoothing is what keeps this
	// test from firing on valid history when reprojection lands a fraction of a texel off, but it
	// also smooths away the variation that would fire it on something that really did move, so a
	// large gently curved area sliding across the view keeps a similar normal.
	//
	// Too tight and valid history is rejected instead. At exactly 1.0 it rejects everything - two
	// independently computed unit vectors do not dot to exactly 1.0 after fp16 storage, a blur,
	// two matrix transforms and a normalize - so the filter silently stops running and the shimmer
	// it exists for comes back. Confirmed: 1.0 shimmers. Approaching 1.0 gets there gradually,
	// rejecting more and more of anything that is not perfectly flat, so the trailing keeps
	// improving right up to the point the filter has effectively been switched off.
	//
	// Hence margin. Legitimate frame to frame normal drift scales with texel size, so a value
	// parked next to that cliff would behave differently at 1080p than at the 1440p this was tuned
	// on, and the failure there is a filter that does nothing while looking installed. 0.999 is
	// about two and a half degrees, roughly three times the angle of 0.9999 and far from 1.0.
    static const float kSameSurfaceDot = 0.999f;

	[branch]
    if (dot(normalize(currentNormalWS), normalize(historyNormalWS)) < kSameSurfaceDot)
        return current; // a different surface was here, whatever its depth said

    float history = tex2D(TESR_ShadowHistoryBuffer, previousUV).x;

	// Reprojection only accounts for the CAMERA moving, so anything that moves by itself is found
	// at the wrong place, and the depth test above cannot catch it: the viewmodel bobs at a nearly
	// fixed distance, and in third person the camera follows the player, so both hold their depth
	// while sliding across the screen. The history accepted then belongs to a different part of the
	// object, which smears shadows across the weapon and across the player while moving.
	//
	// What does NOT work here is neighbourhood clamping, the usual TAA answer to ghosting. TAA
	// trusts the current frame and treats history as suspect; this filter is the other way round -
	// the current frame is the re-quantised noisy one and the history is the average being kept. So
	// clamping history into the current frame's local range re-injects precisely the noise this
	// filter removes. Measured: it cleared the ghosting and brought the shimmer back with it.

    current.r = lerp(current.r, history, TESR_ShadowTemporalData.y);
    return current;
}


technique {

	pass {
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 ScreenSpaceShadow();
	}

	pass {
		VertexShader = compile vs_3_0 FrameVS();
	 	PixelShader = compile ps_3_0 DepthBlur(TESR_PointShadowBuffer, OffsetMaskH, TESR_ShadowScreenSpaceData.y, 3500, SSS_MAXDEPTH);
	}

	pass {
		VertexShader = compile vs_3_0 FrameVS();
	 	PixelShader = compile ps_3_0 DepthBlur(TESR_PointShadowBuffer, OffsetMaskV, TESR_ShadowScreenSpaceData.y, 3500, SSS_MAXDEPTH);
	}

    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 Shadow();
    }

    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 TemporalShadow();
    }

}
