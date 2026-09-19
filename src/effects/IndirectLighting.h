#pragma once

// Ambient occlusion and indirect bounce, rendered into buffers of the effect's own ahead of the
// exterior shadow composite so that the composite can apply them to the ambient term only. The
// occlusion and bounce model is Boomstick467's Screen Space Indirect Lighting (CC0).
class IndirectLightingEffect : public EffectRecord
{
public:
	IndirectLightingEffect() : EffectRecord("IndirectLighting") {
		Constants.Data = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);
		Constants.Bounce = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);
		Constants.Control = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);
		Textures.BufferTexture = nullptr;
		Textures.BufferSurface = nullptr;
		Textures.ScratchTexture = nullptr;
		Textures.ScratchSurface = nullptr;
	};

	bool bNVAOLoaded = false;

	struct IndirectLightingSettingsStruct {
		bool	Enabled;
	};
	IndirectLightingSettingsStruct	Settings;

	struct IndirectLightingStruct {
		D3DXVECTOR4	Data;		// x: radius, y: occlusion strength, z: contrast, w: range
		D3DXVECTOR4	Bounce;		// x: hemisphere bias, y: bounce threshold, z: bounce strength
		D3DXVECTOR4	Control;	// x: the exterior composite applies the result this frame, y: weight bounce by the sun shadow
	};
	IndirectLightingStruct	Constants;

	struct IndirectLightingTextures {
		IDirect3DTexture9* BufferTexture;
		IDirect3DSurface9* BufferSurface;
		IDirect3DTexture9* ScratchTexture;
		IDirect3DSurface9* ScratchSurface;
	};
	IndirectLightingTextures	Textures;

	void	RegisterConstants();
	void	RegisterTextures();
	void	UpdateSettings();
	bool	ShouldRender();

	bool	RenderBuffers(IDirect3DDevice9* Device, bool composited);
};
