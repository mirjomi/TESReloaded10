
float4 TESR_ShadowData : register(c0);
float4 TESR_ShadowFormatData : register(c1);
float4 TESR_ShadowBiasData : register(c2); // x: normal bias (texels), y: slope bias (texels), z: 1 / cascade resolution

sampler2D DiffuseMap : register(s0) = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = POINT; };

static const float FormatBits = TESR_ShadowFormatData.y;

float2 GetEVSMExponents(in float positiveExponent, in float negativeExponent) {
    const float maxExponent = FormatBits == 0.0 ? 5.54f : 42.0f;

    float2 lightSpaceExponents = float2(positiveExponent, negativeExponent);

    // Clamp to maximum range of fp32/fp16 to prevent overflow/underflow
    return min(lightSpaceExponents, maxExponent);
}

// Applies exponential warp to shadow map depth, input depth should be in [0, 1]
float2 WarpDepth(float depth, float2 exponents) {
    // Rescale depth into [-1, 1]
    depth = 2.0f * depth - 1.0f;
    float pos = exp(exponents.x * depth);
    float neg = -exp(-exponents.y * depth);
    return float2(pos, neg);
}

struct VS_OUTPUT {
    float4 texcoord_0 : TEXCOORD0;
	float4 texcoord_1 : TEXCOORD1;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(VS_OUTPUT IN) {
    PS_OUTPUT OUT;

	if (TESR_ShadowData.y == 1.0f) { // Leaves (Speedtrees) or alpha is required
		float4 diffuse = tex2D(DiffuseMap, IN.texcoord_1.xy);
        if (diffuse.a < 0.5f)
            discard;
    }
	
	float depth = IN.texcoord_0.z / IN.texcoord_0.w;

	// Receiver plane slope scaled depth bias.
	//
	// A texel stores one depth for a patch of surface that the surface ramps across, and the
	// steeper that ramp is relative to the light, the further the true depth at the edges of the
	// patch is from the value recorded at its centre. Pushing the stored depth away from the
	// light by the size of that ramp is what stops the surface from shadowing itself.
	//
	// ddx/ddy of depth are taken in shadow map space, so this is automatically correct for every
	// cascade without knowing the cascade radius: the same expression yields a small bias where
	// texels are small and a large one where they are large.
	//
	// The projection is a cube of side 2 * sphereRadius and depth is normalised over that same
	// extent, so one texel of lateral distance is exactly TESR_ShadowBiasData.z in depth units.
	// That is what the clamp is expressed in - a silhouette puts two different surfaces in one
	// derivative quad and the raw gradient there is meaningless, so the bias has to be bounded.
	float2 depthGradient = float2(ddx(depth), ddy(depth));
	float slopeBias = min(TESR_ShadowBiasData.y * length(depthGradient), 8.0f * TESR_ShadowBiasData.z);

	// Larger depth is further from the light (near plane 0, far plane at the far side of the
	// cascade), and the resolve treats a receiver as lit when its depth is at most the stored
	// one, so adding the bias is what moves the caster out of its own way.
	float biasedDepth = saturate(depth + slopeBias);

	// TESR_ShadowFormatData.x : shadow mode
	// 0: VSM
	// 1: EVSM2
	// 2: EVSM4
    if (TESR_ShadowFormatData.x == 0.0f && !TESR_ShadowData.z) {
		// VSM
		// Cheat to reduce shadow acne in variance maps. The spread is a property of the surface,
		// so it is taken from the unbiased gradient.
        float dx = depthGradient.x;
        float dy = depthGradient.y;
        float moment2 = biasedDepth * biasedDepth + 0.25 * (dx * dx + dy * dy);
        OUT.color_0 = float4(biasedDepth, moment2, 0.0f, 1.0f);
    }
    else if (TESR_ShadowFormatData.x == 1.0f && !TESR_ShadowData.z) {
		// EVSM2
		// NOTE: this layout looks wrong and is left alone only because it is not the default.
		// It writes (pos, neg), but GetLightAmountValueEVSM2 hands .xy straight to
		// ChebyshevUpperBound, which reads .y as the second moment of .x - so the negative warp
		// is being used as the second moment of the positive one. A correct EVSM2 stores
		// (pos, pos^2) and has no room for the negative warp at all. Fixing it means changing
		// the channel layout and the matching clear colour, so it is out of scope here.
        float2 exponents = GetEVSMExponents(TESR_ShadowFormatData.w, 5.0f);
        float2 evsm2 = WarpDepth(biasedDepth, exponents);
        OUT.color_0 = float4(evsm2, 0.0f, 1.0f);
    }
    else if (TESR_ShadowFormatData.x == 2.0f && !TESR_ShadowData.z) {
		// EVSM4
        float2 exponents = GetEVSMExponents(TESR_ShadowFormatData.w, 5.0f);
        float2 evsm2 = WarpDepth(biasedDepth, exponents);

		// The second moment is the plain square, so the variance ChebyshevUpperBound computes is
		// identically zero and the test falls back on its constant minVariance floor. The VSM
		// branch above adds the Donnelly-Lauritzen intra-texel spread instead; that was tried
		// here and does not transfer, because taking the spread on the WARPED values makes it
		// explode at silhouettes - the two halves of a derivative quad sit at opposite ends of
		// an exponential - and the inflated variance reads as light leaking through the edge.
		// Doing it properly means taking the spread on the linear depth and warping afterwards.
        float2 moment2 = evsm2 * evsm2;

        OUT.color_0 = float4(evsm2, moment2);
    }
    else {
		// Only depth.
		OUT.color_0 = float4(depth, 0.0f, 0.0f, 1.0f);
	}

	return OUT;	
};