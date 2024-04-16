dxc shaders/shaders.hlsl -HV 2021 -T vs_6_0 -E VSMain -spirv -fspv-target-env=vulkan1.3
dxc shaders/shaders.hlsl -HV 2021 -T ps_6_0 -E PSMain -spirv -fspv-target-env=vulkan1.3
