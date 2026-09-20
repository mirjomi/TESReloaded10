// Pointlight helper functions.

#if defined(__INTELLISENSE__)
    #include "Helpers.hlsl"
#endif

// Vanilla attenuation, lightVector not normalized.
float vanillaAtt(float3 lightVector, float radius) {
    const float3 att = lightVector / radius;
    return 1 - shades(att, att);
}

// The same formula from a precomputed squared distance rather than a light vector. shades is
// saturate(dot(..)), so vanillaAtt(v, r) is 1 - saturate(dot(v, v) / r^2) and this is exactly
// that, not an approximation. It exists so the caller can supply dot(light, light) measured
// where the distance is real - in object space - rather than from a vector that has been
// through a TBN transform, which only preserves length when the basis is orthonormal.
float vanillaAttSq(float distSq, float radius) {
    return 1 - saturate(distSq / (radius * radius));
}

// https://lisyarus.github.io/blog/posts/point-light-attenuation.html
float lisyarusAtt(float3 lightVector, float radius, float falloff=5.0) {
    const float3 normalized = lightVector / radius;
    const float s2 = shades(normalized, normalized);

    return sqr(1 - s2) / (1 + falloff * s2);
}

// Modified Frostbite attenuation (UE4), lightVector not normalized.
float frostbiteAtt(float3 lightVector, float radius) {
    const float squaredDistance = dot(lightVector, lightVector);
    const float invSqrRadius = 1.f / (radius * radius);
    const float factor = squaredDistance * invSqrRadius;
    const float smoothFactor = saturate(1.f - factor * factor);
    const float smoothDistanceAtt = smoothFactor * smoothFactor;
    
    return smoothDistanceAtt / (squaredDistance + 1);
}
