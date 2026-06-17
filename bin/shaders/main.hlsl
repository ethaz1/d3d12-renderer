cbuffer FrameConstants : register(b0)
{
   float4x4 world;
   float4x4 view;
   float4x4 proj;
}

struct PSInput {
   float4 position : SV_POSITION;
   float4 color : COLOR;            
};

PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
   PSInput result;                                       // object data comes with positions in object space

   float4 worldPos = mul(world, position);                    // location in relation to the world (world space)
   float4 viewPos = mul(view, worldPos);                 // location in relation to the camera (view space)
   float4 projPos = mul(proj, viewPos);               

   //float4 worldPos = mul(position, world);  
   //float4 viewPos = mul(worldPos, view);    
   //float4 projPos = mul(viewPos, proj);     

   result.position = projPos;
   result.color = (color + 1.0) / 2.0;
   return result;
}

float4 PSMain(PSInput input) : SV_TARGET {
   return input.color;
};