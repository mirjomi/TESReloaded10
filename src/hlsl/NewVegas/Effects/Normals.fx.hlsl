float4 TESR_ReciprocalResolution;

sampler2D TESR_DepthBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };
sampler2D TESR_NormalsBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };

static const float dropTreshold = 0.82;
static const float blurRadius = 0.6;
static const int KernelSize = 24;
static const float2 OffsetMaskH = float2(1.0f, 0.0f);
static const float2 OffsetMaskV = float2(0.0f, 1.0f);

static const float BlurNormalsWeights[KernelSize] = 
{
	0.019956226f,
	0.021463016f,
	0.032969806f,
	0.044476596f,
	0.055983386f,
	0.067490176f,
	0.078996966f,
	0.080503756f,
	0.092010546f,
	0.105024126f,
	0.116530916f,
	0.128037706f,
	0.128037706f,
	0.116530916f,
	0.105024126f,
	0.092010546f,
	0.080503756f,
	0.078996966f,
	0.067490176f,
	0.055983386f,
	0.044476596f,
	0.032969806f,
	0.021463016f,
	0.019956226f
};

static const float2 BlurNormalsOffsets[KernelSize] = 
{
	float2(-12.0f * TESR_ReciprocalResolution.x, -12.0f * TESR_ReciprocalResolution.y),
	float2(-11.0f * TESR_ReciprocalResolution.x, -11.0f * TESR_ReciprocalResolution.y),
	float2(-10.0f * TESR_ReciprocalResolution.x, -10.0f * TESR_ReciprocalResolution.y),
	float2( -9.0f * TESR_ReciprocalResolution.x,  -9.0f * TESR_ReciprocalResolution.y),
	float2( -8.0f * TESR_ReciprocalResolution.x,  -8.0f * TESR_ReciprocalResolution.y),
	float2( -7.0f * TESR_ReciprocalResolution.x,  -7.0f * TESR_ReciprocalResolution.y),
	float2( -6.0f * TESR_ReciprocalResolution.x,  -6.0f * TESR_ReciprocalResolution.y),
	float2( -5.0f * TESR_ReciprocalResolution.x,  -5.0f * TESR_ReciprocalResolution.y),
	float2( -4.0f * TESR_ReciprocalResolution.x,  -4.0f * TESR_ReciprocalResolution.y),
	float2( -3.0f * TESR_ReciprocalResolution.x,  -3.0f * TESR_ReciprocalResolution.y),
	float2( -2.0f * TESR_ReciprocalResolution.x,  -2.0f * TESR_ReciprocalResolution.y),
	float2( -1.0f * TESR_ReciprocalResolution.x,  -1.0f * TESR_ReciprocalResolution.y),
	float2(  1.0f * TESR_ReciprocalResolution.x,   1.0f * TESR_ReciprocalResolution.y),
	float2(  2.0f * TESR_ReciprocalResolution.x,   2.0f * TESR_ReciprocalResolution.y),
	float2(  3.0f * TESR_ReciprocalResolution.x,   3.0f * TESR_ReciprocalResolution.y),
	float2(  4.0f * TESR_ReciprocalResolution.x,   4.0f * TESR_ReciprocalResolution.y),
	float2(  5.0f * TESR_ReciprocalResolution.x,   5.0f * TESR_ReciprocalResolution.y),
	float2(  6.0f * TESR_ReciprocalResolution.x,   6.0f * TESR_ReciprocalResolution.y),
	float2(  7.0f * TESR_ReciprocalResolution.x,   7.0f * TESR_ReciprocalResolution.y),
	float2(  8.0f * TESR_ReciprocalResolution.x,   8.0f * TESR_ReciprocalResolution.y),
	float2(  9.0f * TESR_ReciprocalResolution.x,   9.0f * TESR_ReciprocalResolution.y),
	float2( 10.0f * TESR_ReciprocalResolution.x,  10.0f * TESR_ReciprocalResolution.y),
	float2( 11.0f * TESR_ReciprocalResolution.x,  11.0f * TESR_ReciprocalResolution.y),
	float2( 12.0f * TESR_ReciprocalResolution.x,  12.0f * TESR_ReciprocalResolution.y)
};


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
#include "Includes/Helpers.hlsl"


float4 ComputeNormals(VSOUT IN) :COLOR0
{
	float2 uv = IN.UVCoord;

	// improved normal reconstruction algorithm from 
	// https://gist.github.com/bgolus/a07ed65602c009d5e2f753826e8078a0

	// store coordinates at 1 and 2 pixels from center in all directions
	float4 rightUv = uv.xyxy + float4(1.0, 0.0, 2.0, 0.0) * TESR_ReciprocalResolution.xyxy; 
	float4 leftUv = uv.xyxy + float4(-1.0, 0.0, -2.0, 0.0) * TESR_ReciprocalResolution.xyxy; 
	float4 bottomUv = uv.xyxy + float4(0.0, 1.0, 0.0, 2.0) * TESR_ReciprocalResolution.xyxy; 
	float4 topUv =uv.xyxy + float4(0.0, -1.0, 0.0, -2.0) * TESR_ReciprocalResolution.xyxy; 

	float depth = readDepth(uv);

	// get depth values at 1 & 2 pixels offsets from current along the horizontal axis
	float4 H = float4(
		readDepth(rightUv.xy),
		readDepth(leftUv.xy),
		readDepth(rightUv.zw),
		readDepth(leftUv.zw)
	);

	// get depth values at 1 & 2 pixels offsets from current along the vertical axis
	float4 V = float4(
		readDepth(topUv.xy),
		readDepth(bottomUv.xy),
		readDepth(topUv.zw),
		readDepth(bottomUv.zw)
	);

	float2 he = abs((2 * H.xy - H.zw) - depth);
	float2 ve = abs((2 * V.xy - V.zw) - depth);

	// pick horizontal and vertical diff with the smallest depth difference from slopes
	float3 centerPoint = reconstructPosition(uv);
	float3 rightPoint = reconstructPosition(rightUv.xy);
	float3 leftPoint = reconstructPosition(leftUv.xy);
	float3 topPoint = reconstructPosition(topUv.xy);
	float3 bottomPoint = reconstructPosition(bottomUv.xy);
	float3 left = centerPoint - leftPoint;
	float3 right = rightPoint - centerPoint;
	float3 down = centerPoint - bottomPoint;
	float3 up = topPoint - centerPoint;

	float3 hDeriv = he.x > he.y ? left : right;
	float3 vDeriv = ve.x > ve.y ? down : up;

	// get view space normal from the cross product of the best derivatives
	// half3 viewNormal = normalize(cross(hDeriv, vDeriv));
	float3 viewNormal = normalize(cross(vDeriv, hDeriv));

	// How far this pixel's depth can be trusted to describe a surface, published in the alpha
	// channel, which nothing was using and which held a constant 1.
	//
	// he and ve are second differences: how far the depth two pixels out misses the line through
	// this pixel and its neighbour. On any plane that is near zero however steeply it recedes,
	// and it is large wherever depth is not locally planar. That covers silhouettes, and it
	// covers the case this was added for - alpha tested foliage, where depth alternates between
	// blade and ground at pixel frequency and there is no single surface for a normal to
	// describe. No amount of filtering recovers one there, so the honest thing is to say so
	// rather than average two unrelated surfaces and present the result as fact.
	//
	// Normalised by depth so one number means the same near and far. 1 is trustworthy, matching
	// what this channel used to hold, so a reader that ignores it behaves exactly as before.
	float planarError = max(min(he.x, he.y), min(ve.x, ve.y));
	float confidence = 1.0 - saturate(planarError / max(depth, 1.0));

	return float4 (compress(viewNormal), confidence);
}
 

float4 BlurNormals(VSOUT IN, uniform float2 OffsetMask) : COLOR0
{
	float WeightSum = 0.12f * saturate(1 - dropTreshold);
	float4 centre = tex2D(TESR_NormalsBuffer, IN.UVCoord);
	float3 normal = expand(centre.rgb);
	float3 finalNormal = normal * WeightSum;

	// Confidence is blurred with the plain kernel, not the normal's edge aware one. The gating
	// below weights a neighbour by how well its normal agrees with this one, which on a pixel
	// frequency pattern rejects precisely the neighbours that disagree and so preserves it.
	// Distrust should spread instead: a pixel surrounded by unreadable depth is not itself
	// readable, and a grass clump wants one low confidence across it rather than a per pixel one.
	float confidence = centre.a * 0.12f;
	float confWeight = 0.12f;
	float depth = readDepth(IN.UVCoord);
	float depthBasedRadius = abs(log(depth/farZ)) * blurRadius;
	float depthDrop = (depth/farZ) * 7000; // difference of depth beyond which the sample will not count towards the blur

	for (int i = 0; i < KernelSize; i++) {
		float2 uvOff = (BlurNormalsOffsets[i] * OffsetMask) * depthBasedRadius;
		float4 neighbour = tex2D(TESR_NormalsBuffer, IN.UVCoord + uvOff);
		float3 newNormal = expand(neighbour.rgb);
		confidence += BlurNormalsWeights[i] * neighbour.a;
		confWeight += BlurNormalsWeights[i];
		float depth2 = readDepth(IN.UVCoord + uvOff);
		float useForBlur = abs(float(depth - depth2)) <= depthDrop;

		float weight = BlurNormalsWeights[i] * saturate(dot(newNormal, normal) - dropTreshold * 0.75f) * useForBlur;

		finalNormal += weight * newNormal;
		WeightSum += weight;
	}
	
	finalNormal /= WeightSum;
    return float4(compress(finalNormal), confidence / confWeight);
}


technique
{
	pass
	{ 
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 ComputeNormals();
	}
	pass
	{ 
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 BlurNormals(OffsetMaskH);
	}
	pass
	{ 
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 BlurNormals(OffsetMaskV);
	}
}