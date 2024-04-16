package main

import vk "vendor:vulkan"

init_command_pool_create_info :: proc(
	queue_family_index: u32,
	flags: vk.CommandPoolCreateFlags,
) -> vk.CommandPoolCreateInfo {
	info := vk.CommandPoolCreateInfo{}
	info.sType = .COMMAND_POOL_CREATE_INFO
	info.pNext = nil
	info.queueFamilyIndex = queue_family_index
	info.flags = flags

	return info
}

init_command_buffer_allocate_info :: proc(pool: vk.CommandPool, count: u32) -> vk.CommandBufferAllocateInfo {
	info := vk.CommandBufferAllocateInfo{}
	info.sType = .COMMAND_BUFFER_ALLOCATE_INFO
	info.pNext = nil

	info.commandPool = pool
	info.commandBufferCount = count
	info.level = .PRIMARY
	return info
}

init_fence_create_info :: proc(flags: vk.FenceCreateFlags) -> vk.FenceCreateInfo {
	info := vk.FenceCreateInfo{}
	info.sType = .FENCE_CREATE_INFO
	info.pNext = nil

	info.flags = flags

	return info
}

init_semaphore_create_info :: proc(flags: vk.SemaphoreCreateFlags) -> vk.SemaphoreCreateInfo {
	info := vk.SemaphoreCreateInfo{}
	info.sType = .SEMAPHORE_CREATE_INFO
	info.pNext = nil
	info.flags = flags
	return info
}

init_command_buffer_begin_info :: proc(flags: vk.CommandBufferUsageFlags) -> vk.CommandBufferBeginInfo {
	info := vk.CommandBufferBeginInfo{}
	info.sType = .COMMAND_BUFFER_BEGIN_INFO
	info.pNext = nil

	info.pInheritanceInfo = nil
	info.flags = flags

	return info
}

init_image_subresource_range :: proc(aspect_mask: vk.ImageAspectFlags) -> vk.ImageSubresourceRange {
	sub_image := vk.ImageSubresourceRange{}
	sub_image.aspectMask = aspect_mask
	sub_image.baseMipLevel = 0
	sub_image.levelCount = vk.REMAINING_MIP_LEVELS
	sub_image.baseArrayLayer = 0
	sub_image.layerCount = vk.REMAINING_ARRAY_LAYERS

	return sub_image
}

init_semaphore_submit_info :: proc(
	stage_mask: vk.PipelineStageFlags2,
	semaphore: vk.Semaphore,
) -> vk.SemaphoreSubmitInfo {
	info := vk.SemaphoreSubmitInfo{}
	info.sType = .SEMAPHORE_SUBMIT_INFO
	info.pNext = nil
	info.semaphore = semaphore
	info.stageMask = stage_mask
	info.deviceIndex = 0
	info.value = 1

	return info
}

init_command_buffer_submit_info :: proc(cmd: vk.CommandBuffer) -> vk.CommandBufferSubmitInfo {
	info := vk.CommandBufferSubmitInfo{}
	info.sType = .COMMAND_BUFFER_SUBMIT_INFO
	info.pNext = nil
	info.commandBuffer = cmd
	info.deviceMask = 0

	return info
}

init_submit_info :: proc(
	cmd: ^vk.CommandBufferSubmitInfo,
	signal_semaphore_info: ^vk.SemaphoreSubmitInfo,
	wait_semaphore_info: ^vk.SemaphoreSubmitInfo,
) -> vk.SubmitInfo2 {
	info := vk.SubmitInfo2{}
	info.sType = .SUBMIT_INFO_2
	info.pNext = nil

	info.waitSemaphoreInfoCount = wait_semaphore_info == nil ? 0 : 1
	info.pWaitSemaphoreInfos = wait_semaphore_info

	info.signalSemaphoreInfoCount = signal_semaphore_info == nil ? 0 : 1
	info.pSignalSemaphoreInfos = signal_semaphore_info

	info.commandBufferInfoCount = 1
	info.pCommandBufferInfos = cmd

	return info
}