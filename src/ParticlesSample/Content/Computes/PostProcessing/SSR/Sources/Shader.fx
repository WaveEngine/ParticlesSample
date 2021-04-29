[Begin_ResourceLayout]

	cbuffer Parameters : register(b0)
	{		
		float4x4 View : packoffset(c0); [View]
		float4x4 Projection : packoffset(c4); [Projection]
		float4x4 InverseProjection : packoffset(c8); [ProjectionInverse]		
		int NumRayMarchSamples : packoffset(c12.x); [Default(150)]
		float MaxReflectionDistance : packoffset(c12.y); [Default(10.0)]
		int RefinementSteps : packoffset(c12.z); [Default(4)]
		float PixelThickness : packoffset(c12.w); [Default(0.0003)]
		float MaxRoughness : packoffset(c13.x); [Default(0.8)]
		float2 Jitter : packoffset(c13.y); [CameraJitter]
	}
	
	Texture2D Color : register(t0);
	Texture2D Depth : register(t1);	
	Texture2D Noise : register(t2); 
	Texture2D<float4> ZPrePass : register(t3); [ZPrePass]
	RWTexture2D<float4> Output : register(u0); [Output(Color)]
	
	SamplerState Sampler : register(s0); 

[End_ResourceLayout]

[Begin_Pass:Default]

	[Profile 11_0]
	[Entrypoints CS = CS]
	
	float3 GetScreenPos(float2 uv, float depth)
	{	    
	    float x = uv.x * 2.0 - 1.0;
  		float y = (1.0 - uv.y) * 2.0 - 1.0;
  		return float3(x,y, depth);
	}
	
	float3 GetViewPos(float3 screenPos)
	{
	    float4 viewPos = mul(float4(screenPos, 1), InverseProjection);
	    return viewPos.xyz / viewPos.w;
	}
	
	float4 RayTraceReflection(float3 ScreenSpaceReflectionVec,  float3 ScreenSpacePos)
	{
		float3 PrevRaySample = ScreenSpacePos;
		float iterations = 0;
		
		// Raymarch in the direction of the ScreenSpaceReflectionVec until you get an intersection with your z buffer
		for (int RayStepIdx = 0; RayStepIdx < NumRayMarchSamples; ++RayStepIdx)
		{
			float3 RaySample = ((float)RayStepIdx / NumRayMarchSamples) * ScreenSpaceReflectionVec + ScreenSpacePos;
			
			// Check borders
			if (RaySample.x < 0.01 || RaySample.x > 0.99 || RaySample.y < 0.01 || RaySample.y > 0.99)
			{
				return float4(0,0,0,1);
			}
			
			float ZBufferVal = Depth.SampleLevel(Sampler,RaySample.xy, 0).r;
					 
			// Check Depth intersection
			float diff =  RaySample.z - ZBufferVal;
			if (RaySample.z > ZBufferVal && diff <= PixelThickness && ScreenSpacePos.z < ZBufferVal)
			{			
				// Binary Search Refinement
				float3 MinRaySample = PrevRaySample;
				float3 MaxRaySample = RaySample;
				float3 MidRaySample;
				for (int i = 0; i < RefinementSteps; i++)
				{
					MidRaySample = lerp(MinRaySample, MaxRaySample, 0.5);
					float ZBufferVal = Depth.SampleLevel(Sampler, MidRaySample.xy, 0).r;
			
					if (MidRaySample.z > ZBufferVal)
						MaxRaySample = MidRaySample;
					else
						MinRaySample = MidRaySample;
				}
								
				return Color.SampleLevel(Sampler, MidRaySample.xy,0);
			}
			
			PrevRaySample = RaySample;
			iterations++;
		}
	
		return float4(0,0,0,1);
	}
	
	static const float PI = 3.14159265358979323846;
	// Brian Karis, Epic Games "Real Shading in Unreal Engine 4"		
	float3 ImportanceSampleGGX( float2 Xi, float Roughness, float3 N )
	{
		float a = Roughness * Roughness;
		float Phi = 2 * PI * Xi.x;
		float CosTheta = sqrt( (1 - Xi.y) / ( 1 + (a*a - 1) * Xi.y ) );
		float SinTheta = sqrt( 1 - CosTheta * CosTheta );
		float3 H;
		H.x = SinTheta * cos( Phi );
		H.y = SinTheta * sin( Phi );
		H.z = CosTheta;
		float3 UpVector = float3(1,0,0);
		float3 TangentX = normalize( cross( UpVector, N ) );
		float3 TangentY = cross( N, TangentX );
		// Tangent to world space
		return TangentX * H.x + TangentY * H.y + N * H.z;
	}

	static const float BRDFBias = 0.7;


	float3 Decode( float2 f )
	{
	    f = f * 2.0 - 1.0;
	 
	    // https://twitter.com/Stubbesaurus/status/937994790553227264
	    float3 n = float3( f.x, f.y, 1.0 - abs( f.x ) - abs( f.y ) );
	    float t = saturate( -n.z );
	    n.xy += n.xy >= 0.0 ? -t : t;
	    return normalize( n );
	}

	[numthreads(8, 8, 1)]
	void CS(uint3 DispatchID : SV_DispatchThreadID)
	{
		float2 BufferSize;
		Output.GetDimensions(BufferSize.x, BufferSize.y);
		
		uint2 PixelID = uint2(DispatchID.x, DispatchID.y);
		float2 PixelUV = (PixelID.xy + 0.5) / BufferSize;
					
		float DeviceZ = Depth[PixelID].x;
		
		float3 screenPos = GetScreenPos(PixelUV, DeviceZ);		
		float3 ViewPos = GetViewPos(screenPos);

		float4 zprepass = ZPrePass[PixelID];
	
		float3 WorldNormal = Decode(zprepass.xy);
		if (zprepass.z >= MaxRoughness)
		{
			Output[DispatchID.xy] = float4(0,0,0,1);
			return;
		}		
	
		float3 ViewNormal = normalize(mul(WorldNormal.xyz, (float3x3)View));
		
		// ScreenSpacePos --> (screencoord.xy, device_z)
		float4 ScreenSpacePos = float4(PixelUV, DeviceZ, 1.0);
		
		float2 Xi = Noise.SampleLevel(Sampler, (PixelUV + Jitter), 0).xy; // Blue noise generated by https://github.com/bartwronski/BlueNoiseGenerator/
		Xi.y = lerp(Xi.y, 0.0, BRDFBias);
		float3 H = ImportanceSampleGGX(Xi, zprepass.z, ViewNormal);
	
		// Compute world space reflection vector
		//float3 ReflectionVector = reflect(normalize(ViewPos), ViewNormal);	
		float3 ReflectionVector = reflect(normalize(ViewPos), H.xyz);
		
		// Compute second sreen space point so that we can get the SS reflection vector	
		float4 ScreenSpaceReflectionPoint = float4(MaxReflectionDistance * ReflectionVector + ViewPos, 1.0);
		ScreenSpaceReflectionPoint = mul(ScreenSpaceReflectionPoint, Projection);
		ScreenSpaceReflectionPoint /= ScreenSpaceReflectionPoint.w;
		ScreenSpaceReflectionPoint.xy = (ScreenSpaceReflectionPoint.xy) * float2(0.5, -0.5) + float2(0.5, 0.5);
	
		// Compute the sreen space reflection vector as the difference of the two screen space points
		float3 ScreenSpaceReflectionVec = normalize(ScreenSpaceReflectionPoint.xyz - ScreenSpacePos.xyz);
		
		// Raymarching					
		float4 rayTrace = RayTraceReflection(ScreenSpaceReflectionVec, ScreenSpacePos.xyz);		
				
		// Reflection result
		Output[DispatchID.xy] = rayTrace;
	}

[End_Pass]