package main

import "core:fmt"
import "core:os"
import "core:slice"

import vk "vendor:vulkan"

util_load_shader_module :: proc(file_name: string, device: vk.Device) -> (vk.ShaderModule, bool) {
	buffer, ok := os.read_entire_file(file_name)

	if !ok {
		return 0, false
	}

	defer delete(buffer)

	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(buffer), // codeSize needs to be in bytes
		pCode    = raw_data(slice.reinterpret([]u32, buffer)),
	}

	module: vk.ShaderModule
	if vk.CreateShaderModule(device, &info, nil, &module) != .SUCCESS {
		return 0, false
	}

	return module, true
}
