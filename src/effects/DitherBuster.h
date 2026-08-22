#pragma once

class DitherBusterEffect : public EffectRecord
{
public:
	DitherBusterEffect() : EffectRecord("DitherBuster") {};

	struct DitherBusterSettingsStruct {
		float Strength;
		float MaskPower;
		float DitherThreshold;
		float Radius;
	};
	DitherBusterSettingsStruct Settings;

	struct DitherBusterStruct {
		D3DXVECTOR4		Data;
	};

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();

	DitherBusterStruct	Constants;
};
