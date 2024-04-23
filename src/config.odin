package main

import vk "vendor:vulkan"

// Set required features to enable here. These are used to pick the physical device as well.
REQUIRED_FEATURES := vk.PhysicalDeviceFeatures2 {
	sType = .PHYSICAL_DEVICE_FEATURES_2,
	pNext = &REQUIRED_VK_13_FEATURES,
	features = {multiDrawIndirect = true, geometryShader = true},
}

REQUIRED_VK_11_FEATURES := vk.PhysicalDeviceVulkan11Features {
	sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
	pNext = &REQUIRED_VK_12_FEATURES,
}

REQUIRED_VK_12_FEATURES := vk.PhysicalDeviceVulkan12Features {
	sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	pNext               = &REQUIRED_VK_13_FEATURES,
	bufferDeviceAddress = true,
	descriptorIndexing  = true,
}

REQUIRED_VK_13_FEATURES := vk.PhysicalDeviceVulkan13Features {
	sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	dynamicRendering = true,
	synchronization2 = true,
}

// Set required extensions to support.
DEVICE_EXTENSIONS := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME}

VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}

when ODIN_DEBUG {
	ENABLE_VALIDATION_LAYERS := true
} else {
	ENABLE_VALIDATION_LAYERS := false
}

FRAME_OVERLAP :: 2
