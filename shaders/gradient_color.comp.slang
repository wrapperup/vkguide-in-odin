struct PushConstants {
  float4 data1;
  float4 data2;
  float4 data3;
  float4 data4;
};

RWTexture2D<float4> image;

[[vk_push_constant]]
PushConstants push_constants;

[numthreads(16, 16, 1)]
[shader("compute")]
void main(uint3 dispatchThreadID: SV_DispatchThreadID,
          uint3 groupThreadID: SV_GroupThreadID) {
  let texelCoord = dispatchThreadID.xy;

  var size = uint2(0, 0);
  image.GetDimensions(size.x, size.y);

  let top_color = push_constants.data1;
  let bottom_color = push_constants.data2;

  if (texelCoord.x < size.x && texelCoord.y < size.y) {
    float blend = float(texelCoord.y) / (size.y);

    image[texelCoord] = lerp(top_color, bottom_color, blend);
  }
}
