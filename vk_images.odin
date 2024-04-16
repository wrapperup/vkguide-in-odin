package main

import vk "vendor:vulkan"

util_transition_image :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	current_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
) {
	image_barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
	}

	image_barrier.pNext = nil

	image_barrier.srcStageMask = {.ALL_COMMANDS}
	image_barrier.srcAccessMask = {.MEMORY_WRITE}
	image_barrier.dstStageMask = {.ALL_COMMANDS}
	image_barrier.dstAccessMask = {.MEMORY_WRITE, .MEMORY_READ}

	image_barrier.oldLayout = current_layout
	image_barrier.newLayout = new_layout

	aspect_mask: vk.ImageAspectFlags = (new_layout == .DEPTH_ATTACHMENT_OPTIMAL) ? {.DEPTH} : {.COLOR}
	image_barrier.subresourceRange = init_image_subresource_range(aspect_mask)
	image_barrier.image = image

	dep_info := vk.DependencyInfo{}
	dep_info.sType = .DEPENDENCY_INFO
	dep_info.pNext = nil

	dep_info.imageMemoryBarrierCount = 1
	dep_info.pImageMemoryBarriers = &image_barrier

	vk.CmdPipelineBarrier2(cmd, &dep_info)
}
