cbuffer FrameConstants : register(b0)
{
   column_major float4x4 world;
   column_major float4x4 view;
   column_major float4x4 proj;
}

struct PSInput {
   float4 position : SV_POSITION;
   float4 color : COLOR;            
};

PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
   PSInput result;                                       // object data comes with positions in object space
   
   float4 worldPos = mul(world, position);
   float4 viewPos  = mul(view, worldPos);
   float4 clipPos  = mul(proj, viewPos);


   result.position = clipPos;
   result.color = (color + 1.0) / 2.0;
   return result;
}

float4 PSMain(PSInput input) : SV_TARGET {
   return input.color;
};