package main

import vk "vendor:vulkan"
import vma "deps:odin-vma"
import hlsl "core:math/linalg/hlsl"

AllocatedImage :: struct {
    image: vk.Image,
    image_view: vk.ImageView,
    allocation: vma.Allocation,
    extent: vk.Extent3D,
    format: vk.Format
}

AllocatedBuffer :: struct {
    buffer: vk.Buffer,
    allocation: vma.Allocation,
    info: vma.AllocationInfo
}

Vertex :: struct {
    position: hlsl.float3,
    uv_x: f32,
    normal: hlsl.float3,
    uv_y: f32,
    color: hlsl.float4,
}

GPUMeshBuffers :: struct {
    index_buffer: AllocatedBuffer,
    vertex_buffer: AllocatedBuffer,
    vertex_buffer_address: vk.DeviceAddress,
}

GPUDrawPushConstants :: struct {
    world_matrix: hlsl.float4x4,
    vertex_buffer: vk.DeviceAddress,
}
