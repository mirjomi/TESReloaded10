#include "IndirectLighting.h"

void IndirectLightingEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_IndirectLightingData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_IndirectLightingBounce", &Constants.Bounce);
	TheShaderManager->RegisterConstant("TESR_IndirectLightingControl", &Constants.Control);
}

void IndirectLightingEffect::RegisterTextures() {
	// Full resolution, as the shader this is based on ran: its blur is narrow, so a lower
	// resolution buffer would need an edge aware upsample to come back to the same place.
	// Sixteen bit float because the bounce can take the multiplier above 1.
	TheTextureManager->InitTexture("TESR_IndirectLightingBuffer", &Textures.BufferTexture, &Textures.BufferSurface,
		TheRenderManager->width, TheRenderManager->height, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_IndirectLightingScratch", &Textures.ScratchTexture, &Textures.ScratchSurface,
		TheRenderManager->width, TheRenderManager->height, D3DFMT_A16B16G16R16F);
}

void IndirectLightingEffect::UpdateSettings() {
	const char* sectionName = TheShaderManager->GameState.isExterior ? "Shaders.IndirectLighting.Exteriors" : "Shaders.IndirectLighting.Interiors";

	Settings.Enabled = TheSettingManager->GetSettingI(sectionName, "Enabled");
	Constants.Data.x = max(TheSettingManager->GetSettingF(sectionName, "Radius"), 1.0f);
	Constants.Data.y = max(TheSettingManager->GetSettingF(sectionName, "Strength"), 0.0f);
	Constants.Data.z = max(TheSettingManager->GetSettingF(sectionName, "Contrast"), 0.0f);
	Constants.Data.w = max(TheSettingManager->GetSettingF(sectionName, "Range"), 0.0f);
	Constants.Bounce.x = std::clamp(TheSettingManager->GetSettingF(sectionName, "HemisphereBias"), 0.0f, 1.0f);
	Constants.Bounce.y = std::clamp(TheSettingManager->GetSettingF(sectionName, "BounceThreshold"), 0.0f, 1.0f);
	Constants.Bounce.z = max(TheSettingManager->GetSettingF(sectionName, "BounceStrength"), 0.0f);
}

bool IndirectLightingEffect::ShouldRender() {
	return Settings.Enabled && !bNVAOLoaded;
}

// Render occlusion and bounce into the effect's own buffers. Returns whether it did, which is
// what decides whether anything downstream may read them this frame.
//
// composited says the exterior shadow composite will run this frame and apply the result to the
// ambient itself. The sun shadow buffer only holds a sun term in that same case, so it also gates
// weighting the bounce by it.
bool IndirectLightingEffect::RenderBuffers(IDirect3DDevice9* Device, bool composited) {
	// Cleared before anything can return, so a frame that renders nothing leaves the composite
	// reading no occlusion rather than whatever the buffer held last.
	Constants.Control = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);

	if (!Enabled || !Effect || !ShouldRender() || !Textures.BufferSurface || !Textures.ScratchSurface)
		return false;

	Constants.Control.x = composited ? 1.0f : 0.0f;
	Constants.Control.y = composited ? 1.0f : 0.0f;

	// Each pass draws into the buffer and is copied into the scratch, which the next pass reads.
	// No source copy: the passes read the frame through TESR_RenderedBuffer, untouched here.
	Device->SetRenderTarget(0, Textures.BufferSurface);
	Render(Device, Textures.BufferSurface, Textures.ScratchSurface, 0, false, NULL);
	return true;
}
