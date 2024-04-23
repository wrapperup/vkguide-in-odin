package main

import vk "vendor:vulkan"
import vma "deps:odin-vma"

AllocatedImage :: struct {
    image: vk.Image,
    image_view: vk.ImageView,
    allocation: vma.Allocation,
    extent: vk.Extent3D,
    format: vk.Format
}
