#include "MaterialPass.h"
#include <d3dx9shader.h>

namespace MaterialPass {
	// Everything this pass is configured by lives on the Flashlight effect, because it is
	// the same light: the cone, the near fade and the hotspot limit have to match the
	// screen space pass exactly or the two disagree along the edge of the beam.
	static FlashlightEffect::FlashlightSettingsStruct& FL() {
		return TheShaderManager->Effects.Flashlight->Settings;
	}

	static constexpr UInt32 kRTTI_NiNode = 0x11F4428;
	static constexpr UInt32 kRTTI_NiGeometry = 0x11F4ACC;
	static constexpr UInt32 kRTTI_NiSwitchNode = 0x11F5EB4;
	static constexpr UInt32 kRenderTriShapeAlt = 0xE745A0;
	static constexpr UInt32 kRenderTriStripsAlt = 0xE74840;
	static constexpr int kDebugXRay = 8;	// see-through view of everything queued
	static constexpr UInt32 kSavedStreamCount = 8;
	static constexpr UInt32 kSavedTextureCount = 2;
	static constexpr UInt32 kSavedSamplerStateCount = 5;
	static constexpr UInt32 kSavedVertexConstants = 8;	// c0-c3 view projection, c4-c7 world
	static constexpr UInt32 kSavedPixelConstants = 7;	// c0-c4 and c6

	// Every render state this pass overwrites. SavedDeviceState records two values for each
	// of them, because NiDX9RenderState's cache and the device are not guaranteed to hold
	// the same one, and putting back only one of the two is what made this pass destructive.
	// See the comments in Save and Restore for the measurement and the ordering.
	static const D3DRENDERSTATETYPE kSavedRenderStates[] = {
		D3DRS_ZENABLE, D3DRS_ZWRITEENABLE, D3DRS_ALPHABLENDENABLE, D3DRS_SRCBLEND,
		D3DRS_DESTBLEND, D3DRS_ALPHATESTENABLE, D3DRS_STENCILENABLE, D3DRS_CULLMODE,
		D3DRS_COLORWRITEENABLE, D3DRS_FOGENABLE, D3DRS_ZFUNC, D3DRS_DEPTHBIAS,
		D3DRS_SCISSORTESTENABLE, D3DRS_CLIPPLANEENABLE, D3DRS_BLENDOP, D3DRS_SEPARATEALPHABLENDENABLE,
		D3DRS_MULTISAMPLEMASK, D3DRS_SLOPESCALEDEPTHBIAS, D3DRS_MULTISAMPLEANTIALIAS, D3DRS_SRGBWRITEENABLE,
	};
	static constexpr UInt32 kSavedRenderStateCount = 20;
	static constexpr UInt32 kCullModeIndex = 7;	// SetCullMode needs the engine's stencil mapping

	static const char* kVertexShaderSource =
		"row_major float4x4 gViewProj : register(c0);\n"
		"row_major float4x4 gWorld : register(c4);\n"
		"struct VS_IN { float4 pos : POSITION0; float3 normal : NORMAL0; float4 uv : TEXCOORD0; };\n"
		"struct VS_OUT { float4 pos : POSITION; float2 uv : TEXCOORD0; float3 worldRel : TEXCOORD1; float3 normalRel : TEXCOORD2; };\n"
		"VS_OUT main(VS_IN IN) {\n"
		"    VS_OUT OUT;\n"
		"    float4 localPos = float4(IN.pos.xyz, 1.0);\n"
		"    float4 worldPos = mul(localPos, gWorld);\n"
		"    OUT.pos = mul(float4(worldPos.xyz * 0.9997, 1.0), gViewProj);\n"
		"    OUT.uv = IN.uv.xy;\n"
		"    OUT.worldRel = worldPos.xyz;\n"
		"    OUT.normalRel = normalize(mul(float4(IN.normal.xyz, 0.0), gWorld).xyz);\n"
		"    return OUT;\n"
		"}\n";

	static const char* kPixelShaderSource =
		"float4 gLightColorIntensity : register(c0);\n"
		"float4 gLightDirAngle : register(c1);\n"
		"float4 gTuning : register(c2);\n"
		"float4 gLightPosRadius : register(c3);\n"
		"float4 gSpecular : register(c4);\n"
		"float4 gHotspot : register(c6);\n"
		"sampler2D DiffuseMap : register(s0);\n"
		"struct PS_IN { float2 uv : TEXCOORD0; float3 worldRel : TEXCOORD1; float3 normalRel : TEXCOORD2; };\n"
		"float invlerp(float a, float b, float v) { return saturate((v - a) / max(0.0001, b - a)); }\n"
		"float luma(float3 color) { return dot(color, float3(0.2126, 0.7152, 0.0722)); }\n"
		"float4 main(PS_IN IN) : COLOR0 {\n"
		"    float debugStrength = 4.0 * max(gLightColorIntensity.w, 0.25);\n"
		"    if (gTuning.y > 0.5 && gTuning.y < 1.5) return float4(debugStrength, 0.0, 0.0, 1.0);\n"
		"    float4 base = tex2D(DiffuseMap, IN.uv);\n"
		"    float3 toLight = gLightPosRadius.xyz - IN.worldRel;\n"
		"    float distToLight = length(toLight);\n"
		"    float3 lightVector = toLight / max(distToLight, 0.001);\n"
		"    float radius = max(gLightPosRadius.w, 1.0);\n"
		"    float s = saturate((distToLight / radius) * (distToLight / radius));\n"
		"    float atten = saturate(((1.0 - s) * (1.0 - s)) / (1.0 + 5.0 * s));\n"
		"    float angle = max(1.0, gLightDirAngle.w);\n"
		"    float angleCosMax = cos(radians(angle));\n"
		"    float angleCosMin = cos(radians(angle * 0.5));\n"
		"    float cone = pow(invlerp(angleCosMax, angleCosMin, dot(normalize(gLightDirAngle.xyz), -lightVector)), 2.0);\n"
		"    float nearFade = (gTuning.x > 0.0) ? smoothstep(0.0, gTuning.x, distToLight) : 1.0;\n"
		"    float contribution = atten * cone * nearFade;\n"
		"    float3 normal = normalize(IN.normalRel);\n"
		"    float diffuse = saturate(dot(normal, lightVector));\n"
		"    float3 viewVector = normalize(-IN.worldRel);\n"
		"    float3 halfVector = normalize(lightVector + viewVector);\n"
		"    float nDotH = saturate(dot(normal, halfVector));\n"
		"    float gloss = smoothstep(0.45, 0.95, saturate(gSpecular.z));\n"
		"    float specPower = gSpecular.y * 2.0;\n"
		"    float specExponent = max(specPower / 32.0, 1.0);\n"
		"    float specLobe = pow(saturate((nDotH - 0.72) / 0.28), specExponent);\n"
		"    float specular = gSpecular.x * gloss * specLobe;\n"
		"    specular *= (diffuse <= 0.2) ? saturate(diffuse + 0.5) : 1.0;\n"
		"    float3 diffuseLight = base.rgb * diffuse * gLightColorIntensity.rgb * gLightColorIntensity.w * contribution;\n"
		"    float specularMask = saturate(specular);\n"
		"    float3 specularLight = saturate(specularMask * contribution * gLightColorIntensity.rgb);\n"
		"    if (gTuning.y > 6.5) return float4(saturate(specLobe * 8.0), gloss, saturate(specLobe * gloss * 16.0), 1.0);\n"
		"    if (gTuning.y > 5.5) return float4(0.0, 0.0, 0.0, 1.0);\n"
		"    if (gTuning.y > 4.5) return float4(pow(nDotH, 16.0) * debugStrength * contribution, pow(nDotH, 16.0) * debugStrength * contribution, pow(nDotH, 16.0) * debugStrength * contribution, 1.0);\n"
		"    if (gTuning.y > 3.5) return float4(0.0, 0.0, 0.0, 1.0);\n"
		"    if (gTuning.y > 2.5) return float4(specularLight * 4.0, 1.0);\n"
		"    if (gTuning.y > 1.5) return float4(0.0, 0.0, debugStrength * contribution, 1.0);\n"
		"    float3 outLight = diffuseLight + specularLight;\n"
		"    if (gHotspot.x > 0.0) {\n"
		"        float limit = 1.0 / gHotspot.x;\n"
		"        float outLum = luma(outLight);\n"
		"        outLight *= limit / max(limit, outLum);\n"
		"    }\n"
		"    return float4(outLight, 1.0);\n"
		"}\n";

	static const char* kNormalMapVertexShaderSource =
		"row_major float4x4 gViewProj : register(c0);\n"
		"row_major float4x4 gWorld : register(c4);\n"
		"struct VS_IN { float4 pos : POSITION0; float3 tangent : TANGENT0; float3 binormal : BINORMAL0; float3 normal : NORMAL0; float4 uv : TEXCOORD0; };\n"
		"struct VS_OUT { float4 pos : POSITION; float2 uv : TEXCOORD0; float3 worldRel : TEXCOORD1; float3 tangentRel : TEXCOORD2; float3 binormalRel : TEXCOORD3; float3 normalRel : TEXCOORD4; };\n"
		"VS_OUT main(VS_IN IN) {\n"
		"    VS_OUT OUT;\n"
		"    float4 localPos = float4(IN.pos.xyz, 1.0);\n"
		"    float4 worldPos = mul(localPos, gWorld);\n"
		"    OUT.pos = mul(float4(worldPos.xyz * 0.9997, 1.0), gViewProj);\n"
		"    OUT.uv = IN.uv.xy;\n"
		"    OUT.worldRel = worldPos.xyz;\n"
		"    OUT.tangentRel = normalize(mul(float4(IN.tangent.xyz, 0.0), gWorld).xyz);\n"
		"    OUT.binormalRel = normalize(mul(float4(IN.binormal.xyz, 0.0), gWorld).xyz);\n"
		"    OUT.normalRel = normalize(mul(float4(IN.normal.xyz, 0.0), gWorld).xyz);\n"
		"    return OUT;\n"
		"}\n";

	static const char* kNormalMapPixelShaderSource =
		"float4 gLightColorIntensity : register(c0);\n"
		"float4 gLightDirAngle : register(c1);\n"
		"float4 gTuning : register(c2);\n"
		"float4 gLightPosRadius : register(c3);\n"
		"float4 gSpecular : register(c4);\n"
		"float4 gHotspot : register(c6);\n"
		"sampler2D DiffuseMap : register(s0);\n"
		"sampler2D NormalMap : register(s1);\n"
		"struct PS_IN { float2 uv : TEXCOORD0; float3 worldRel : TEXCOORD1; float3 tangentRel : TEXCOORD2; float3 binormalRel : TEXCOORD3; float3 normalRel : TEXCOORD4; };\n"
		"float invlerp(float a, float b, float v) { return saturate((v - a) / max(0.0001, b - a)); }\n"
		"float luma(float3 color) { return dot(color, float3(0.2126, 0.7152, 0.0722)); }\n"
		"float4 main(PS_IN IN) : COLOR0 {\n"
		"    float debugStrength = 4.0 * max(gLightColorIntensity.w, 0.25);\n"
		"    if (gTuning.y > 0.5 && gTuning.y < 1.5) return float4(debugStrength, 0.0, 0.0, 1.0);\n"
		"    float4 base = tex2D(DiffuseMap, IN.uv);\n"
		"    float3 toLight = gLightPosRadius.xyz - IN.worldRel;\n"
		"    float distToLight = length(toLight);\n"
		"    float3 lightVector = toLight / max(distToLight, 0.001);\n"
		"    float radius = max(gLightPosRadius.w, 1.0);\n"
		"    float s = saturate((distToLight / radius) * (distToLight / radius));\n"
		"    float atten = saturate(((1.0 - s) * (1.0 - s)) / (1.0 + 5.0 * s));\n"
		"    float angle = max(1.0, gLightDirAngle.w);\n"
		"    float angleCosMax = cos(radians(angle));\n"
		"    float angleCosMin = cos(radians(angle * 0.5));\n"
		"    float cone = pow(invlerp(angleCosMax, angleCosMin, dot(normalize(gLightDirAngle.xyz), -lightVector)), 2.0);\n"
		"    float nearFade = (gTuning.x > 0.0) ? smoothstep(0.0, gTuning.x, distToLight) : 1.0;\n"
		"    float contribution = atten * cone * nearFade;\n"
		"    float3 tangent = normalize(IN.tangentRel);\n"
		"    float3 binormal = normalize(IN.binormalRel);\n"
		"    float3 normal = normalize(IN.normalRel);\n"
		"    float4 normalSample = tex2D(NormalMap, IN.uv);\n"
		"    float3 mapNormal = normalSample.xyz * 2.0 - 1.0;\n"
		"    mapNormal.xy *= max(gSpecular.w, 0.0);\n"
		"    mapNormal = normalize(mapNormal);\n"
		"    float3 worldNormal = normalize(mapNormal.x * tangent + mapNormal.y * binormal + mapNormal.z * normal);\n"
		"    float vertexDiffuse = saturate(dot(normal, lightVector));\n"
		"    float diffuse = saturate(dot(worldNormal, lightVector));\n"
		"    float3 viewVector = normalize(-IN.worldRel);\n"
		"    float3 halfVector = normalize(lightVector + viewVector);\n"
		"    float glossInput = saturate(normalSample.a);\n"
		"    float gloss = smoothstep(0.45, 0.95, glossInput);\n"
		"    float nDotH = saturate(dot(worldNormal, halfVector));\n"
		"    float specPower = gSpecular.y * 2.0;\n"
		"    float specExponent = max(specPower / 32.0, 1.0);\n"
		"    float specLobe = pow(saturate((nDotH - 0.72) / 0.28), specExponent);\n"
		"    float specular = gSpecular.x * gloss * specLobe;\n"
		"    specular *= (diffuse <= 0.2) ? saturate(diffuse + 0.5) : 1.0;\n"
		"    float3 diffuseLight = base.rgb * diffuse * gLightColorIntensity.rgb * gLightColorIntensity.w * contribution;\n"
		"    float specularMask = saturate(specular);\n"
		"    float3 specularLight = saturate(specularMask * contribution * gLightColorIntensity.rgb);\n"
		"    if (gTuning.y > 6.5) return float4(saturate(specLobe * 8.0), gloss, saturate(specLobe * gloss * 16.0), 1.0);\n"
		"    if (gTuning.y > 5.5) {\n"
		"        float normalDelta = diffuse - vertexDiffuse;\n"
		"        float posDelta = saturate(normalDelta * 8.0) * debugStrength * contribution;\n"
		"        float negDelta = saturate(-normalDelta * 8.0) * debugStrength * contribution;\n"
		"        return float4(posDelta, negDelta, negDelta, 1.0);\n"
		"    }\n"
		"    if (gTuning.y > 4.5) return float4(pow(nDotH, 16.0) * debugStrength * contribution, pow(nDotH, 16.0) * debugStrength * contribution, pow(nDotH, 16.0) * debugStrength * contribution, 1.0);\n"
		"    if (gTuning.y > 3.5) return float4(glossInput * debugStrength * contribution, glossInput * debugStrength * contribution, glossInput * debugStrength * contribution, 1.0);\n"
		"    if (gTuning.y > 2.5) return float4(specularLight * 4.0, 1.0);\n"
		"    if (gTuning.y > 1.5) return float4(0.0, debugStrength * contribution, 0.0, 1.0);\n"
		"    float3 outLight = diffuseLight + specularLight;\n"
		"    if (gHotspot.x > 0.0) {\n"
		"        float limit = 1.0 / gHotspot.x;\n"
		"        float outLum = luma(outLight);\n"
		"        outLight *= limit / max(limit, outLum);\n"
		"    }\n"
		"    return float4(outLight, 1.0);\n"
		"}\n";

	struct RenderItem {
		NiGeometry* geometry;
		IDirect3DBaseTexture9* diffuse;
		IDirect3DBaseTexture9* normalMap;
		float specularStrength;
		float specularPower;
		float fallbackGloss;
		bool useNormalMap;
	};

	struct StreamState {
		IDirect3DVertexBuffer9* buffer;
		UINT offset;
		UINT stride;
	};

	struct SavedDeviceState {
		IDirect3DVertexShader9* vertexShader;
		IDirect3DPixelShader9* pixelShader;
		IDirect3DVertexDeclaration9* vertexDeclaration;
		IDirect3DBaseTexture9* textures[kSavedTextureCount];
		IDirect3DIndexBuffer9* indexBuffer;
		StreamState streams[kSavedStreamCount];
		DWORD fvf;
		DWORD renderStates[kSavedRenderStateCount];		// as NiDX9RenderState believes them
		DWORD deviceRenderStates[kSavedRenderStateCount];	// as the device actually has them
		DWORD samplerStates[kSavedTextureCount][kSavedSamplerStateCount];
		float vertexConstants[kSavedVertexConstants][4];
		float pixelConstants[kSavedPixelConstants][4];
		bool constantsSaved;

		void Save(IDirect3DDevice9* apDevice) {
			NiDX9RenderState* renderState = TheRenderManager ? TheRenderManager->renderState : nullptr;
			vertexShader = nullptr;
			pixelShader = nullptr;
			vertexDeclaration = nullptr;
			indexBuffer = nullptr;
			fvf = 0;
			ZeroMemory(textures, sizeof(textures));
			ZeroMemory(streams, sizeof(streams));
			ZeroMemory(renderStates, sizeof(renderStates));
			ZeroMemory(deviceRenderStates, sizeof(deviceRenderStates));
			ZeroMemory(samplerStates, sizeof(samplerStates));
			ZeroMemory(vertexConstants, sizeof(vertexConstants));
			ZeroMemory(pixelConstants, sizeof(pixelConstants));
			constantsSaved = false;

			apDevice->GetVertexShader(&vertexShader);
			apDevice->GetPixelShader(&pixelShader);
			apDevice->GetVertexDeclaration(&vertexDeclaration);
			for (UInt32 i = 0; i < kSavedTextureCount; ++i)
				apDevice->GetTexture(i, &textures[i]);
			apDevice->GetIndices(&indexBuffer);
			apDevice->GetFVF(&fvf);
			for (UInt32 i = 0; i < kSavedStreamCount; ++i)
				apDevice->GetStreamSource(i, &streams[i].buffer, &streams[i].offset, &streams[i].stride);

			// Both halves of every state, because they are NOT guaranteed to agree. Measured:
			// STENCILENABLE reads 0 on the device and 1 in NiDX9RenderState's cache, and that
			// disagreement is load bearing. The engine skips a write it believes is redundant,
			// so for as long as its cache says stencil is on it will never actually switch it
			// on. A pass that saves one half and restores the other quietly repairs that, and
			// decals which were never really being stencil tested suddenly are, and vanish.
			// Put back what was there, disagreement included.
			for (UInt32 i = 0; i < kSavedRenderStateCount; ++i) {
				renderStates[i] = renderState ? renderState->GetRenderState(kSavedRenderStates[i]) : 0;
				apDevice->GetRenderState(kSavedRenderStates[i], &deviceRenderStates[i]);
			}

			// The shader constant registers this pass writes. Gamebryo splits its constants into
			// per object ones, which it uploads for every draw, and global ones, which it uploads
			// only when it believes they have gone stale. Overwriting a global and walking away
			// leaves the engine convinced its value is still resident, so the next geometry to
			// use that register silently gets this pass's matrix instead.
			constantsSaved =
				SUCCEEDED(apDevice->GetVertexShaderConstantF(0, &vertexConstants[0][0], kSavedVertexConstants)) &&
				SUCCEEDED(apDevice->GetPixelShaderConstantF(0, &pixelConstants[0][0], kSavedPixelConstants));

			for (UInt32 i = 0; i < kSavedTextureCount; ++i) {
				apDevice->GetSamplerState(i, D3DSAMP_ADDRESSU, &samplerStates[i][0]);
				apDevice->GetSamplerState(i, D3DSAMP_ADDRESSV, &samplerStates[i][1]);
				apDevice->GetSamplerState(i, D3DSAMP_MAGFILTER, &samplerStates[i][2]);
				apDevice->GetSamplerState(i, D3DSAMP_MINFILTER, &samplerStates[i][3]);
				apDevice->GetSamplerState(i, D3DSAMP_MIPFILTER, &samplerStates[i][4]);
			}
		}

		void Restore(IDirect3DDevice9* apDevice) {
			NiDX9RenderState* renderState = TheRenderManager ? TheRenderManager->renderState : nullptr;

			if (renderState) {
				renderState->SetVertexShader(vertexShader, false);
				renderState->SetPixelShader(pixelShader, false);
				if (vertexDeclaration)
					renderState->SetVertexDeclaration(vertexDeclaration, false);
				else
					renderState->SetFVF(fvf, false);
			} else {
				apDevice->SetVertexShader(vertexShader);
				apDevice->SetPixelShader(pixelShader);
				if (vertexDeclaration)
					apDevice->SetVertexDeclaration(vertexDeclaration);
				else
					apDevice->SetFVF(fvf);
			}

			for (UInt32 i = 0; i < kSavedTextureCount; ++i) {
				if (renderState) {
					renderState->SetTexture(i, textures[i]);
					renderState->SetSamplerState(i, D3DSAMP_ADDRESSU, samplerStates[i][0], false);
					renderState->SetSamplerState(i, D3DSAMP_ADDRESSV, samplerStates[i][1], false);
					renderState->SetSamplerState(i, D3DSAMP_MAGFILTER, samplerStates[i][2], false);
					renderState->SetSamplerState(i, D3DSAMP_MINFILTER, samplerStates[i][3], false);
					renderState->SetSamplerState(i, D3DSAMP_MIPFILTER, samplerStates[i][4], false);
				} else {
					apDevice->SetTexture(i, textures[i]);
					apDevice->SetSamplerState(i, D3DSAMP_ADDRESSU, samplerStates[i][0]);
					apDevice->SetSamplerState(i, D3DSAMP_ADDRESSV, samplerStates[i][1]);
					apDevice->SetSamplerState(i, D3DSAMP_MAGFILTER, samplerStates[i][2]);
					apDevice->SetSamplerState(i, D3DSAMP_MINFILTER, samplerStates[i][3]);
					apDevice->SetSamplerState(i, D3DSAMP_MIPFILTER, samplerStates[i][4]);
				}
			}

			// Two writes per state, in this order. The first puts NiDX9RenderState's cache back,
			// which writes the device as a side effect. The second puts the device back on top,
			// so a state the engine and the device disagreed about goes on disagreeing exactly
			// as it did. Cull mode is excluded from the second write because it is the one state
			// this pass sets through the engine, so the engine's value is the right one for both.
			for (UInt32 i = 0; i < kSavedRenderStateCount; ++i) {
				if (renderState)
					renderState->SetRenderState(kSavedRenderStates[i], renderStates[i], RenderStateArgs);
				if (i != kCullModeIndex)
					apDevice->SetRenderState(kSavedRenderStates[i], deviceRenderStates[i]);
			}

			if (constantsSaved) {
				apDevice->SetVertexShaderConstantF(0, &vertexConstants[0][0], kSavedVertexConstants);
				apDevice->SetPixelShaderConstantF(0, &pixelConstants[0][0], kSavedPixelConstants);
			}

			apDevice->SetIndices(indexBuffer);
			for (UInt32 i = 0; i < kSavedStreamCount; ++i)
				apDevice->SetStreamSource(i, streams[i].buffer, streams[i].offset, streams[i].stride);

			if (vertexShader) vertexShader->Release();
			if (pixelShader) pixelShader->Release();
			if (vertexDeclaration) vertexDeclaration->Release();
			for (UInt32 i = 0; i < kSavedTextureCount; ++i) {
				if (textures[i])
					textures[i]->Release();
			}
			if (indexBuffer) indexBuffer->Release();
			for (UInt32 i = 0; i < kSavedStreamCount; ++i) {
				if (streams[i].buffer)
					streams[i].buffer->Release();
			}
		}
	};

	static bool g_renderActive = false;
	static std::vector<RenderItem> g_renderQueue;
	static IDirect3DVertexShader9* g_vertexShader = nullptr;
	static IDirect3DPixelShader9* g_pixelShader = nullptr;
	static IDirect3DVertexShader9* g_normalMapVertexShader = nullptr;
	static IDirect3DPixelShader9* g_normalMapPixelShader = nullptr;
	static bool g_shaderFailed = false;

	static bool IsNiNode(NiAVObject* apObject) {
		return apObject && CdeclCall<bool>(0x43B300, kRTTI_NiNode, apObject);
	}

	static bool IsGeometry(NiAVObject* apObject) {
		return apObject && CdeclCall<bool>(0x43B300, kRTTI_NiGeometry, apObject);
	}

	static bool IsSwitchNode(NiAVObject* apObject) {
		return apObject && CdeclCall<bool>(0x43B300, kRTTI_NiSwitchNode, apObject);
	}

	// Shade types this pass will re-light. Doubles as the guard for the BSShaderProperty cast in
	// CaptureGeometry: every type listed here derives from it, so passing this test makes the
	// cast safe as well.
	//
	// The wider set of BSShaderProperty types also takes in kProp_NoLighting, kProp_DistantLOD
	// and kProp_TallGrass, and those are excluded deliberately - a mesh marked unlit should stay
	// unlit, a distant LOD stand-in is meant to be hidden behind the real thing rather than lit
	// alongside it, and grass proxies are lit by their own shader.
	static bool IsLightingShadeType(NiShadeProperty::ShaderPropType aeType) {
		return aeType == NiShadeProperty::kProp_Lighting ||
			aeType == NiShadeProperty::kProp_PPLighting ||
			aeType == NiShadeProperty::kProp_Lighting30 ||
			aeType == NiShadeProperty::kProp_Hair ||
			aeType == NiShadeProperty::kProp_SpeedTreeBranch ||
			aeType == NiShadeProperty::kProp_SpeedTreeLeaf;
	}

	static NiShadeProperty* GetShadeProperty(NiGeometry* apGeometry) {
		return apGeometry ? apGeometry->propertyState.m_spShadeProperty : nullptr;
	}

	static IDirect3DBaseTexture9* GetTexture(BSShaderPPLightingProperty* apProperty, UInt32 auiIndex) {
		if (!apProperty || auiIndex >= 6 || !apProperty->ppTextures[auiIndex])
			return nullptr;
		NiSourceTexture* texture = *apProperty->ppTextures[auiIndex];
		if (!texture || !texture->rendererData)
			return nullptr;
		return texture->rendererData->dTexture;
	}

	static bool DeclarationHasUsage(IDirect3DVertexDeclaration9* apDeclaration, BYTE aucUsage) {
		if (!apDeclaration)
			return false;

		D3DVERTEXELEMENT9 elements[MAXD3DDECLLENGTH];
		UINT count = MAXD3DDECLLENGTH;
		if (FAILED(apDeclaration->GetDeclaration(elements, &count)))
			return false;

		for (UINT i = 0; i < count; ++i) {
			if (elements[i].Stream == 0xFF)
				break;
			if (elements[i].Usage == aucUsage && elements[i].UsageIndex == 0)
				return true;
		}
		return false;
	}

	static bool HasTangentBasis(NiGeometry* apGeometry) {
		NiGeometryData* modelData = apGeometry ? apGeometry->geomData : nullptr;
		NiGeometryBufferData* bufferData = modelData ? modelData->m_pkBuffData : nullptr;
		if (!bufferData || !bufferData->VertexDeclaration)
			return false;
		return DeclarationHasUsage(bufferData->VertexDeclaration, D3DDECLUSAGE_TANGENT) &&
			DeclarationHasUsage(bufferData->VertexDeclaration, D3DDECLUSAGE_BINORMAL) &&
			DeclarationHasUsage(bufferData->VertexDeclaration, D3DDECLUSAGE_NORMAL);
	}

	static float ClampFloat(float afValue, float afMin, float afMax) {
		if (afValue < afMin)
			return afMin;
		if (afValue > afMax)
			return afMax;
		return afValue;
	}

	static float GetSpecularScale(NiGeometry* apGeometry) {
		NiMaterialProperty* material = apGeometry ? apGeometry->propertyState.m_spMaterialProperty : nullptr;
		if (!material)
			return 1.0f;

		float scale = material->spec.r;
		if (material->spec.g > scale)
			scale = material->spec.g;
		if (material->spec.b > scale)
			scale = material->spec.b;
		if (scale <= 0.001f)
			return 1.0f;
		return ClampFloat(scale, 0.0f, 4.0f);
	}

	static float GetSpecularPower(NiGeometry* apGeometry) {
		NiMaterialProperty* material = apGeometry ? apGeometry->propertyState.m_spMaterialProperty : nullptr;
		if (!material || material->fShine <= 0.0f)
			return 32.0f;
		return ClampFloat(material->fShine, 4.0f, 128.0f);
	}

	static bool IsWithinLight(NiAVObject* apObject) {
		if (!TheShaderManager || !apObject)
			return false;

		NiBound* bound = apObject->m_kWorldBound;
		const NiPoint3 center = bound ? bound->Center : apObject->m_worldTransform.pos;
		const float boundRadius = bound ? bound->Radius : 0.0f;
		const D3DXVECTOR4& light = TheShaderManager->SpotLightPosition[0];
		const float radius = light.w + boundRadius;
		const float dx = center.x - light.x;
		const float dy = center.y - light.y;
		const float dz = center.z - light.z;
		return (dx * dx + dy * dy + dz * dz) <= radius * radius;
	}

	static bool UsesAlphaBlendOrTest(NiGeometry* apGeometry) {
		NiAlphaProperty* alpha = apGeometry ? apGeometry->propertyState.m_spAlphaProperty : nullptr;
		if (!alpha)
			return false;
		return (alpha->flags & (NiAlphaProperty::ALPHA_BLEND_MASK | NiAlphaProperty::TEST_ENABLE_MASK)) != 0;
	}

	static bool ShouldQueueGeometry(
		NiGeometry* apGeometry,
		BSShaderPPLightingProperty* apProperty,
		IDirect3DBaseTexture9** apDiffuse) {
		if (!g_renderActive || !apGeometry || !apProperty || !apDiffuse)
			return false;
		if ((int)g_renderQueue.size() >= FL().MaterialLight.MaxGeometry)
			return false;
		if (apGeometry->skinInstance || UsesAlphaBlendOrTest(apGeometry))
			return false;
		if (apGeometry->m_flags & NiAVObject::APP_CULLED)
			return false;

		const char* name = apGeometry->m_pcName ? apGeometry->m_pcName : "";
		if (strstr(name, "Terrain LOD") == name)
			return false;

		NiGeometryData* modelData = apGeometry->geomData;
		if (!modelData || !modelData->m_pkBuffData || !modelData->m_pkBuffData->VertCount)
			return false;
		if (!IsWithinLight(apGeometry))
			return false;

		*apDiffuse = GetTexture(apProperty, 0);
		return *apDiffuse != nullptr;
	}

	static void QueueGeometry(
		NiGeometry* apGeometry,
		BSShaderPPLightingProperty* apProperty,
		IDirect3DBaseTexture9* apNormalMap,
		bool abSpecular,
		float afSpecularStrength,
		float afSpecularPower,
		bool abUseNormalMap) {
		IDirect3DBaseTexture9* diffuse = nullptr;
		if (!ShouldQueueGeometry(apGeometry, apProperty, &diffuse))
			return;
		const float specularStrength = abSpecular ? afSpecularStrength : 0.0f;
		g_renderQueue.push_back({ apGeometry, diffuse, abUseNormalMap ? apNormalMap : nullptr, specularStrength, afSpecularPower, 0.5f, abUseNormalMap && apNormalMap });
	}

	void CaptureGeometry(NiGeometry* apGeometry) {
		if (!g_renderActive || !apGeometry)
			return;
		if (!*(void**)apGeometry || !IsGeometry(static_cast<NiAVObject*>(apGeometry)))
			return;

		NiShadeProperty* shade = GetShadeProperty(apGeometry);
		if (!shade)
			return;

		const auto shadeType = shade->m_eShaderType;
		const bool skinned = apGeometry->skinInstance != nullptr;

		if (!IsLightingShadeType(shadeType))
			return;

		auto* property = static_cast<BSShaderProperty*>(shade);
		const UInt32 flags0 = property->ulFlags[0];
		const UInt32 flags1 = property->ulFlags[1];
		const bool specular = (flags0 & BSShaderProperty::Specular) != 0;
		const bool parallax = (flags0 & (BSShaderProperty::Parallax_Shader | BSShaderProperty::Parallax_Occlusion)) != 0;
		const bool normalEligible = (flags1 & BSShaderProperty::Skip_Normal_Maps) == 0;
		const bool modelSpaceNormals = (flags0 & BSShaderProperty::Model_Space_Normals) != 0;
		const float specularStrength = specular ? GetSpecularScale(apGeometry) : 0.0f;
		const float specularPower = GetSpecularPower(apGeometry);
		bool tangentData = false;
		bool tangentBasis = false;
		bool normalTexture = false;
		bool useNormalMap = false;
		IDirect3DBaseTexture9* normalMap = nullptr;
		BSShaderPPLightingProperty* ppLighting = nullptr;
		UInt32 lightCount = 0;


		if (shadeType == NiShadeProperty::kProp_PPLighting) {
			ppLighting = static_cast<BSShaderPPLightingProperty*>(property);
			tangentData = ppLighting->spTangentSpaceData != nullptr;
			tangentBasis = HasTangentBasis(apGeometry);
			normalMap = GetTexture(ppLighting, 1);
			normalTexture = normalMap != nullptr;
			useNormalMap = normalEligible && !modelSpaceNormals && tangentBasis && normalTexture;
		}

		QueueGeometry(apGeometry, ppLighting, normalMap, specular, specularStrength, specularPower, useNormalMap);
	}

	static void CaptureObject(NiAVObject* apObject) {
		if (!apObject || !*(void**)apObject)
			return;
		if (apObject->m_flags & NiAVObject::APP_CULLED)
			return;
		// No subtree prune by world bound here. The scene graph root does not maintain one
		// that encloses its children - it reads as centre (0,0,0) radius 1 - so testing it
		// rejects the whole scene on the first node and nothing is ever captured. Geometry
		// is bound tested individually in ShouldQueueGeometry, so this only ever saved the
		// walk, never correctness.

		if (IsGeometry(apObject)) {
			CaptureGeometry(static_cast<NiGeometry*>(apObject));
			return;
		}

		if (!IsNiNode(apObject))
			return;

		auto* node = static_cast<NiNode*>(apObject);
		if (!node->m_children.data || node->m_children.numObjs == 0)
			return;

		if (IsSwitchNode(apObject)) {
			auto* switchNode = static_cast<NiSwitchNode*>(apObject);
			if (switchNode->m_iIndex < 0)
				return;
			UInt32 index = (UInt32)switchNode->m_iIndex;
			if (index < node->m_children.numObjs)
				CaptureObject(node->m_children.data[index]);
			return;
		}

		for (UInt32 i = 0; i < node->m_children.numObjs; ++i)
			CaptureObject(node->m_children.data[i]);
	}

	void CaptureScene(SceneGraph* apSceneGraph) {
		if (!g_renderActive || !apSceneGraph)
			return;

		CaptureObject(apSceneGraph);
	}


	void BeginFrame(bool abActive) {
		g_renderQueue.clear();
		g_renderActive = abActive && FL().MaterialLight.Enabled &&
			FL().MaterialLight.Intensity > 0.0f &&
			FL().MaterialLight.MaxGeometry > 0;
	}

	static bool CompileShader(const char* apSource, const char* apEntry, const char* apProfile, ID3DXBuffer** apCode) {
		ID3DXBuffer* errors = nullptr;
		HRESULT hr = D3DXCompileShader(apSource, (UINT)strlen(apSource), nullptr, nullptr, apEntry, apProfile, 0, apCode, &errors, nullptr);
		if (errors)
			errors->Release();
		return SUCCEEDED(hr);
	}

	static bool EnsureShaders(IDirect3DDevice9* apDevice) {
		if (g_vertexShader && g_pixelShader && g_normalMapVertexShader && g_normalMapPixelShader)
			return true;
		if (g_shaderFailed || !apDevice)
			return false;

		ID3DXBuffer* vsCode = nullptr;
		ID3DXBuffer* psCode = nullptr;
		ID3DXBuffer* normalVsCode = nullptr;
		ID3DXBuffer* normalPsCode = nullptr;
		if (!CompileShader(kVertexShaderSource, "main", "vs_3_0", &vsCode) ||
			!CompileShader(kPixelShaderSource, "main", "ps_3_0", &psCode) ||
			!CompileShader(kNormalMapVertexShaderSource, "main", "vs_3_0", &normalVsCode) ||
			!CompileShader(kNormalMapPixelShaderSource, "main", "ps_3_0", &normalPsCode)) {
			g_shaderFailed = true;
			Logger::Log("[MaterialPass] shader COMPILE failed");
			if (vsCode) vsCode->Release();
			if (psCode) psCode->Release();
			if (normalVsCode) normalVsCode->Release();
			if (normalPsCode) normalPsCode->Release();
			return false;
		}

		HRESULT vs = apDevice->CreateVertexShader((const DWORD*)vsCode->GetBufferPointer(), &g_vertexShader);
		HRESULT ps = apDevice->CreatePixelShader((const DWORD*)psCode->GetBufferPointer(), &g_pixelShader);
		HRESULT normalVs = apDevice->CreateVertexShader((const DWORD*)normalVsCode->GetBufferPointer(), &g_normalMapVertexShader);
		HRESULT normalPs = apDevice->CreatePixelShader((const DWORD*)normalPsCode->GetBufferPointer(), &g_normalMapPixelShader);
		vsCode->Release();
		psCode->Release();
		normalVsCode->Release();
		normalPsCode->Release();

		if (FAILED(vs) || FAILED(ps) || FAILED(normalVs) || FAILED(normalPs)) {
			if (g_vertexShader) {
				g_vertexShader->Release();
				g_vertexShader = nullptr;
			}
			if (g_pixelShader) {
				g_pixelShader->Release();
				g_pixelShader = nullptr;
			}
			if (g_normalMapVertexShader) {
				g_normalMapVertexShader->Release();
				g_normalMapVertexShader = nullptr;
			}
			if (g_normalMapPixelShader) {
				g_normalMapPixelShader->Release();
				g_normalMapPixelShader = nullptr;
			}
			g_shaderFailed = true;
			return false;
		}

		return true;
	}

	static void ApplyRenderState() {
		// Through NiDX9RenderState rather than the device, because the engine's own draw path
		// re-applies its cache: values written only to the device get overwritten part way
		// through this pass. Measured, by trying it - the depth compare reverted to the
		// engine's and the pass drew through walls, and the stage 1 normal map was dropped so
		// the highlights went flat. SavedDeviceState is what makes that safe again.
		NiDX9RenderState* renderState = TheRenderManager->renderState;

		// This pass re-draws geometry the engine has already drawn, so every fragment lands on
		// a depth value that ought to compare equal, and only an inclusive comparison lets an
		// equal depth redraw through. It used to set no ZFUNC at all and inherit whatever the
		// engine last left, which is not stable frame to frame - the sky and particles leave
		// compares of their own behind. So it is set explicitly.
		//
		// LESSEQUAL is chosen from measurement, and it contradicts what the surrounding code
		// would predict. On the setup this was developed on RenderManager::IsReversedDepth() is
		// true, the Z clear is 0, the projection carries the reversed formula, and the engine's
		// own world render leaves ZFUNC on GREATEREQUAL - so deriving the direction the way
		// ShadowManager::RenderShadowMaps does yields GREATEREQUAL. Setting GREATEREQUAL here
		// draws the geometry that is occluded, straight through walls; LESSEQUAL respects
		// occlusion correctly. Why the two disagree is not understood, so the measured value
		// stands rather than the derived one. Untested on a non-inverted buffer: if this pass
		// draws nothing there, this line is the first thing to try flipping.
		//
		// DebugMode 8 deliberately drops the depth test entirely, so every object the pass
		// queued is drawn through whatever is in front of it. That answers "did this object
		// get captured at all", which is otherwise indistinguishable from "it was captured
		// and then failed the depth test".
		const bool xray = (FL().MaterialLight.DebugMode == kDebugXRay);
		float noDepthBias = 0.0f;
		renderState->SetRenderState(D3DRS_ZFUNC, D3DCMP_LESSEQUAL, RenderStateArgs);
		renderState->SetRenderState(D3DRS_DEPTHBIAS, *(DWORD*)&noDepthBias, RenderStateArgs);

		renderState->SetVertexShader(g_vertexShader, false);
		renderState->SetPixelShader(g_pixelShader, false);
		renderState->SetRenderState(D3DRS_ZENABLE, xray ? D3DZB_FALSE : D3DZB_TRUE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_ZWRITEENABLE, D3DZB_FALSE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_ONE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_ONE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_ALPHATESTENABLE, FALSE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_STENCILENABLE, FALSE, RenderStateArgs);
		// The engine renders the world with alpha writes masked off, so the render target's alpha
		// channel means whatever it meant before this pass ran. Forcing all four channels on made
		// this pass write alpha 1.0 additively at every pixel it touched, ~126 draws deep, into a
		// float target that does not clamp. Add light to the colour and leave alpha alone.
		renderState->SetRenderState(D3DRS_COLORWRITEENABLE,
			D3DCOLORWRITEENABLE_RED | D3DCOLORWRITEENABLE_GREEN | D3DCOLORWRITEENABLE_BLUE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_FOGENABLE, FALSE, RenderStateArgs);
		// A pass that draws its own geometry has to own every state that can reject a fragment,
		// not just the ones it happens to care about. These two are the last that were left
		// inherited: whatever the engine had set when the world render finished decided whether
		// this pass's pixels survived.
		renderState->SetRenderState(D3DRS_SCISSORTESTENABLE, FALSE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_CLIPPLANEENABLE, 0, RenderStateArgs);
		// Same reasoning for the rest of the blend equation. Setting SRCBLEND and DESTBLEND only
		// describes an additive blend if the operator is ADD and no separate alpha path is armed;
		// both were inherited. MULTISAMPLEMASK likewise decides which samples of the 8x target
		// this pass is allowed to touch.
		renderState->SetRenderState(D3DRS_BLENDOP, D3DBLENDOP_ADD, RenderStateArgs);
		renderState->SetRenderState(D3DRS_SEPARATEALPHABLENDENABLE, FALSE, RenderStateArgs);
		renderState->SetRenderState(D3DRS_MULTISAMPLEMASK, 0xFFFFFFFF, RenderStateArgs);
		renderState->SetRenderState(D3DRS_SLOPESCALEDEPTHBIAS, 0, RenderStateArgs);
		renderState->SetSamplerState(0, D3DSAMP_ADDRESSU, D3DTADDRESS_WRAP, false);
		renderState->SetSamplerState(0, D3DSAMP_ADDRESSV, D3DTADDRESS_WRAP, false);
		renderState->SetSamplerState(0, D3DSAMP_MAGFILTER, D3DTEXF_LINEAR, false);
		renderState->SetSamplerState(0, D3DSAMP_MINFILTER, D3DTEXF_LINEAR, false);
		renderState->SetSamplerState(0, D3DSAMP_MIPFILTER, D3DTEXF_LINEAR, false);
		renderState->SetSamplerState(1, D3DSAMP_ADDRESSU, D3DTADDRESS_WRAP, false);
		renderState->SetSamplerState(1, D3DSAMP_ADDRESSV, D3DTADDRESS_WRAP, false);
		renderState->SetSamplerState(1, D3DSAMP_MAGFILTER, D3DTEXF_LINEAR, false);
		renderState->SetSamplerState(1, D3DSAMP_MINFILTER, D3DTEXF_LINEAR, false);
		renderState->SetSamplerState(1, D3DSAMP_MIPFILTER, D3DTEXF_LINEAR, false);
	}

	static void SetCullMode(NiGeometry* apGeometry) {
		NiStencilProperty* stencil = apGeometry ? apGeometry->propertyState.m_spStencilProperty : nullptr;
		if (stencil)
			TheRenderManager->renderState->SetCullMode(stencil->GetDrawMode());
		else
			TheRenderManager->renderState->SetRenderState(D3DRS_CULLMODE, D3DCULL_CCW, RenderStateArgs);
	}

	static bool DrawGeometryBuffer(NiGeometry* apGeometry) {
		if (!apGeometry || !apGeometry->geomData)
			return false;
		NiGeometryBufferData* data = apGeometry->geomData->m_pkBuffData;
		if (!data || !data->VertCount)
			return false;
		if (data->StreamCount > kSavedStreamCount || !data->VertexStride)
			return false;

		IDirect3DDevice9* device = TheRenderManager->device;
		for (UInt32 i = 0; i < data->StreamCount; ++i) {
			if (!data->VBChip || !data->VBChip[i] || !data->VBChip[i]->VB)
				return false;
			device->SetStreamSource(i, data->VBChip[i]->VB, 0, data->VertexStride[i]);
		}

		if (data->IB)
			device->SetIndices(data->IB);
		if (data->FVF)
			TheRenderManager->renderState->SetFVF(data->FVF, false);
		else if (data->VertexDeclaration)
			TheRenderManager->renderState->SetVertexDeclaration(data->VertexDeclaration, false);
		else
			return false;

		const UInt16 dirtyFlags = apGeometry->geomData->m_usDirtyFlags;
		if (apGeometry->geomData->IsStripsData())
			ThisCall(kRenderTriStripsAlt, NiDX9Renderer::GetSingleton(), apGeometry);
		else
			ThisCall(kRenderTriShapeAlt, NiDX9Renderer::GetSingleton(), apGeometry);
		apGeometry->geomData->m_usDirtyFlags = dirtyFlags;
		return true;
	}

	void RenderWorld() {
		if (!g_renderActive || g_renderQueue.empty() || !TheRenderManager || !TheShaderManager)
			return;

		IDirect3DDevice9* device = TheRenderManager->device;
		if (!EnsureShaders(device))
			return;

		SavedDeviceState saved{};
		saved.Save(device);
		ApplyRenderState();

		D3DXVECTOR4 lightPos = TheShaderManager->SpotLightPosition[0];
		lightPos.x -= TheRenderManager->CameraPosition.x;
		lightPos.y -= TheRenderManager->CameraPosition.y;
		lightPos.z -= TheRenderManager->CameraPosition.z;

		D3DXVECTOR4 lightDir = TheShaderManager->SpotLightDirection[0];
		D3DXVec3Normalize((D3DXVECTOR3*)&lightDir, (D3DXVECTOR3*)&lightDir);
		lightDir.w = TheShaderManager->SpotLightDirection[0].w;

		// Fold the light's own dimmer and the night boost into the colour, exactly as the
		// screen space pass does, so this pass tracks the flashlight instead of having to be
		// re-balanced against it every time the dimmer moves or the sun goes down. The
		// dimmer belongs in rgb rather than w because w only reaches the diffuse term -
		// the specular term reads rgb alone. MaterialLight Intensity stays in w, where it
		// is the diffuse strength of this pass alone, matching Specular for the highlight.
		const D3DXVECTOR4& sun = TheShaderManager->ShaderConst.sunColor;
		float sunLuma = 1.0f / max(0.05f, sun.x * 0.2126f + sun.y * 0.7152f + sun.z * 0.0722f);
		float scale = TheShaderManager->SpotLightColor[0].w * sunLuma;

		D3DXVECTOR4 lightColor = TheShaderManager->SpotLightColor[0];
		lightColor.x *= scale;
		lightColor.y *= scale;
		lightColor.z *= scale;
		lightColor.w = FL().MaterialLight.Intensity;
		// x-ray reuses mode 1's flat colour, so the shaders need no branch of their own
		const int debugMode = FL().MaterialLight.DebugMode;
		D3DXVECTOR4 tuning(FL().NearFade, (float)(debugMode == kDebugXRay ? 1 : debugMode), 0.0f, 0.0f);

		// Same for every item, so it goes up once. The vertex shaders scale each position
		// slightly towards the camera before projecting it. This pass re-draws geometry the
		// engine already drew, so every fragment lands on a depth that ought to compare equal,
		// but ours comes from a projection we rebuilt and the low bits disagree, which loses
		// the tie about half the time. A D3D depth bias is the wrong instrument: it is constant
		// in non-linear depth, so any value large enough to help nearby reaches through walls
		// at distance. Positions here are camera relative, so scaling them is a proportional
		// pull along the view ray - small at every range, and indifferent to which way round
		// the depth buffer runs. Only the projected position moves; worldRel keeps the true
		// position so the lighting is unaffected.
		//
		// 0.9997 - a pull of 0.0003 of view depth - is measured, not derived, and the arithmetic
		// argument does not survive contact with the game. On paper 0.00001 clears the float error
		// in the rebuilt projection a hundred times over. It does not clear it at all. Measured on
		// a ladder, sweeping the light across a wall with MaterialLight DebugMode 2:
		//
		//     0.00001  flickers          0.0001  clean
		//     0.00003  flickers          0.001   clean
		//
		// So the threshold sits between 0.00003 and 0.0001 - about ten times larger than the
		// arithmetic predicts, which means the error being cleared is bigger than the two step
		// matrix multiply accounts for. 0.0003 is the step above the threshold: a factor of three
		// of margin, without giving back much reach. The pull is proportional, so geometry 1500
		// units out - the beam's MaxDistance - moves 0.45 units toward the camera, against 1.5
		// units at the 0.001 this replaces.
		//
		// Do not lower this on the arithmetic alone. That is exactly how 0.00001 came to ship, and
		// the flicker it leaves behind is faint enough to survive a quick look for it.
		//
		// This offset was for a long time suspected of causing a second artifact - a wall poster
		// in one interior disappearing under this pass - because changing its magnitude changed
		// how widely that artifact appeared. It did not cause it. The cause was SavedDeviceState
		// reading render states from the device and restoring them into NiDX9RenderState, which
		// repaired a STENCILENABLE mismatch the engine was silently relying on and started
		// genuinely stencil testing decals. See the comments there. It is worth recording that
		// the entanglement was an illusion, because it is what kept the pull at a value ten
		// thousand times larger than it needed to be.
		//
		// What the offset must keep doing, whatever value it takes: removing it outright brings
		// the flicker straight back, and so does matching the engine's arithmetic exactly - one
		// concatenated world-view-projection applied to the local position, the way the engine
		// itself transforms. So the split multiply is not the whole source of the mismatch; the
		// camera relative form used here is equivalent to the engine's absolute one but not bit
		// identical to it.
		device->SetVertexShaderConstantF(0, (float*)&TheRenderManager->ViewProjMatrix, 4);

		device->SetPixelShaderConstantF(0, (float*)&lightColor, 1);
		device->SetPixelShaderConstantF(1, (float*)&lightDir, 1);
		device->SetPixelShaderConstantF(2, (float*)&tuning, 1);
		device->SetPixelShaderConstantF(3, (float*)&lightPos, 1);
		D3DXVECTOR4 hotspot(FL().HotspotLimit, 0.0f, 0.0f, 0.0f);
		device->SetPixelShaderConstantF(6, (float*)&hotspot, 1);

		for (const RenderItem& item : g_renderQueue) {
			if (!item.geometry || !item.diffuse)
				continue;
			const bool useNormalMap = item.useNormalMap && item.normalMap;
			const float specularStrength = item.specularStrength * FL().MaterialLight.Specular;

			D3DXMATRIX world;
			TheRenderManager->CreateD3DMatrix(&world, &item.geometry->m_worldTransform);
			device->SetVertexShaderConstantF(4, (float*)&world, 4);

			D3DXVECTOR4 specular(specularStrength, item.specularPower, item.fallbackGloss, FL().MaterialLight.NormalStrength);
			device->SetPixelShaderConstantF(4, (float*)&specular, 1);

			TheRenderManager->renderState->SetVertexShader(useNormalMap ? g_normalMapVertexShader : g_vertexShader, false);
			TheRenderManager->renderState->SetPixelShader(useNormalMap ? g_normalMapPixelShader : g_pixelShader, false);
			TheRenderManager->renderState->SetTexture(0, item.diffuse);
			TheRenderManager->renderState->SetTexture(1, useNormalMap ? item.normalMap : nullptr);
			SetCullMode(item.geometry);
			DrawGeometryBuffer(item.geometry);
		}

		saved.Restore(device);
	}

}
