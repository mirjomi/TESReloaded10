#pragma once


class ShadowManager { // Never disposed
public:
	static void Initialize();
	
	enum ShadowMapTypeEnum {
		MapNear = 0,
		MapMiddle = 1,
		MapFar = 2,
		MapLod = 3,
		MapOrtho = 4,
	};


	NiNode*					GetRefNode(TESObjectREFR* Ref, ShadowsExteriorEffect::FormsStruct* Forms);
	static bool				IsRefracting(TESObjectREFR* Ref);
	void					AccumChildren(NiAVObject* NiObject, ShadowsExteriorEffect::FormsStruct* Forms, bool isLand, bool isLOD, NiFrustumPlanes* arPlanes = nullptr);
	void					AccumObject(std::vector<NiAVObject*>* containersAccum, NiAVObject* NiObject, ShadowsExteriorEffect::FormsStruct* Forms, bool isLODLand);

	// Reused by AccumChildren instead of a fresh container per call. AccumChildren runs once per
	// reference per cascade, it is iterative rather than recursive, and the shadow pass is single
	// threaded, so one buffer held here is enough. clear() keeps the capacity between calls.
	std::vector<NiAVObject*>	ContainerStack;
	void					RenderAccums();
	void					RenderShadowMap(ShadowsExteriorEffect::ShadowMapSettings* ShadowMap, D3DXMATRIX* ViewProj);
	void					AccumExteriorCell(TESObjectCELL* Cell, ShadowsExteriorEffect::ShadowMapSettings* ShadowMap);
	void					RenderShadowCubeMap(ShadowSceneLight** Lights, UInt32 LightIndex);
	void					RenderShadowSpotlight(NiSpotLight** Lights, UInt32 LightIndex);
	void					RenderShadowMaps();
	void					ClearShadowCascade(D3DVIEWPORT9* ViewPort, D3DXVECTOR4* ClearColor);
	void                    BlurShadowAtlas();

	ShadowRenderPass*				geometryPass;
	AlphaShadowRenderPass*			alphaPass;
	SkinnedGeoShadowRenderPass*		skinnedGeoPass;
	SpeedTreeShadowRenderPass*		speedTreePass;
	TerrainLODPass*					terrainLODPass;

	NiVector4				BillboardRight;
	NiVector4				BillboardUp;
	ShaderRecordVertex*		ShadowMapVertex;
	ShaderRecordPixel*		ShadowMapPixel;
	ShaderRecordVertex*		ShadowCubeMapVertex;
	ShaderRecordPixel*		ShadowCubeMapPixel;
	ShaderRecordVertex*		ShadowMapBlurVertex;
	ShaderRecordPixel*		ShadowMapBlurPixel;
	ShaderRecordPixel*		ShadowMapClearPixel;
	D3DVIEWPORT9			ShadowCubeMapViewPort;
	ShaderRecordVertex*		CurrentVertex;
	ShaderRecordPixel*		CurrentPixel;
	bool					AlphaEnabled;
	int						PointLightsNum;
	float					shadowMapsRenderTime;
	bool					ShadowShadersLoaded;

	// ShadowMap.pso bakes the storage mode and whether the slope bias exists into the compiled
	// shader. What it was built with is recorded here rather than re-derived from the settings, so
	// SyncShadowMapShader can compare the two and reload when they no longer agree. -1 forces the
	// first load.
	int						CompiledShadowMode = -1;
	int						CompiledSlopeBias = -1;
	void					LoadShadowMapPixelShader(int mode, bool slopeBias);
	void					SyncShadowMapShader();
	int						FrameCounter;

	// Actors drawn into the sun cascades, this frame and the one before. The temporal filter cannot
	// tell a moving actor's shadow from a static one, so it is told where they are - see PublishMovers.
	struct TrackedMover {
		UInt32				RefID;
		D3DXVECTOR3			Position;	// root node, world space
		D3DXVECTOR4			Bound;		// world bound: xyz centre, w radius
		float				Texel;		// world size of a texel in the finest cascade that drew it
	};
	struct MoverStep {
		float				Distance;	// from the camera
		size_t				Index;		// into Movers
		D3DXVECTOR3			Step;		// world space movement since the previous frame
	};
	std::vector<TrackedMover>	Movers;
	std::vector<TrackedMover>	PreviousMovers;
	std::vector<MoverStep>		MoverSteps;
	bool					TrackMovers;
	void					TrackMover(TESObjectREFR* Ref, NiNode* Node, ShadowsExteriorEffect::ShadowMapSettings* ShadowMap);
	void					PublishMovers();

private:
	bool					CheckShaderFlags(NiGeometry* Geometry);
	void					RecalculateBillboardVectors(D3DXVECTOR3* SunDir);
};