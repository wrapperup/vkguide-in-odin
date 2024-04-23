RWTexture2D<float4> image;
struct MyUniform {
  float yo;
  float so;
  float ay;
}

[numthreads(16, 16, 1)]
[shader("compute")]
void main(uint3 dispatchThreadID: SV_DispatchThreadID,
          uint3 groupThreadID: SV_GroupThreadID) {
  let texelCoord = dispatchThreadID.xy;
  var size = uint2(0, 0);
  image.GetDimensions(size.x, size.y);

  if (texelCoord.x < size.x && texelCoord.y < size.y) {
    var color = float4(0.0, 0.0, 0.0, 1.0);

    if (groupThreadID.x != 0 && groupThreadID.y != 0) {
      color.x = float(texelCoord.x) / (size.x);
      color.y = float(texelCoord.y) / (size.y);
    }

    image[texelCoord] = color;
  }
}
