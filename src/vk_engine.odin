package main

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:reflect"
import "core:runtime"
import "core:strings"

import vma "deps:odin-vma"
import "vendor:glfw"
import vk "vendor:vulkan"

import im_glfw "deps:odin-imgui/imgui_impl_glfw"
import im_vk "deps:odin-imgui/imgui_impl_vulkan"
import im "deps:odin-imgui"


VulkanEngine :: struct {
	debug_messenger:              vk.DebugUtilsMessengerEXT,
	window:                       glfw.WindowHandle,
	window_extent:                vk.Extent2D,
	instance:                     vk.Instance,
	physical_device:              vk.PhysicalDevice,
	device:                       vk.Device,

	// Queues
	graphics_queue:               vk.Queue,
	graphics_queue_family:        u32,
	surface:                      vk.SurfaceKHR,

	// Swapchain
	swapchain:                    vk.SwapchainKHR,
	swapchain_images:             []vk.Image,
	swapchain_image_views:        []vk.ImageView,
	swapchain_image_format:       vk.Format,
	swapchain_extent:             vk.Extent2D,

	// Command Pool/Buffer
	frames:                       [FRAME_OVERLAP]FrameData,
	frame_number:                 int,
	deletion_queue:               DeletionQueue,
	allocator:                    vma.Allocator,

	// Draw resources
	draw_image:                   AllocatedImage,
	draw_extent:                  vk.Extent2D,

	// Descriptors
	global_descriptor_allocator:  DescriptorAllocator,
	draw_image_descriptors:       vk.DescriptorSet,
	draw_image_descriptor_layout: vk.DescriptorSetLayout,

	// Pipelines
	gradient_pipeline:            vk.Pipeline,
	gradient_pipeline_layout:     vk.PipelineLayout,

	// Immediate submit
	imm_fence:                    vk.Fence,
	imm_command_buffer:           vk.CommandBuffer,
	imm_command_pool:             vk.CommandPool,
}

immediate_submit :: proc(engine: ^VulkanEngine, procedure: proc(_: vk.CommandBuffer)) {
	vk_check(vk.ResetFences(engine.device, 1, &engine.imm_fence));
	vk_check(vk.ResetCommandBuffer(engine.imm_command_buffer, {}));

	cmd := engine.imm_command_buffer

	cmd_begin_info := init_command_buffer_begin_info({.ONE_TIME_SUBMIT});

	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info));

	procedure(cmd);

	vk_check(vk.EndCommandBuffer(cmd));

	cmd_info := init_command_buffer_submit_info(cmd);
	submit := init_submit_info(&cmd_info, nil, nil);

	// submit command buffer to the queue and execute it.
	//  _renderFence will now block until the graphic commands finish execution
	vk_check(vk.QueueSubmit2(engine.graphics_queue, 1, &submit, engine.imm_fence));

	vk_check(vk.WaitForFences(engine.device, 1, &engine.imm_fence, true, 9_999_999_999));
}

init_imgui :: proc(engine: ^VulkanEngine) {
	pool_sizes := []vk.DescriptorPoolSize {
		{ .SAMPLER, 1000 },
		{ .COMBINED_IMAGE_SAMPLER, 1000 },
		{ .SAMPLED_IMAGE, 1000 },
		{ .STORAGE_IMAGE, 1000 },
		{ .UNIFORM_TEXEL_BUFFER, 1000 },
		{ .STORAGE_TEXEL_BUFFER, 1000 },
		{ .UNIFORM_BUFFER, 1000 },
		{ .STORAGE_BUFFER, 1000 },
		{ .UNIFORM_BUFFER_DYNAMIC, 1000 },
		{ .STORAGE_BUFFER_DYNAMIC, 1000 },
		{ .INPUT_ATTACHMENT, 1000 },
	}

	pool_info := vk.DescriptorPoolCreateInfo {sType = .DESCRIPTOR_POOL_CREATE_INFO}
	pool_info.flags = {.FREE_DESCRIPTOR_SET};
	pool_info.maxSets = 1_000;
	pool_info.poolSizeCount = u32(len(pool_sizes));
	pool_info.pPoolSizes = raw_data(pool_sizes);

	im_pool: vk.DescriptorPool
	vk_check(vk.CreateDescriptorPool(engine.device, &pool_info, nil, &im_pool));

	// 2: initialize imgui library

	// this initializes the core structures of imgui
	im.CreateContext();

	// this initializes imgui for glfw
	im_glfw.InitForVulkan(engine.window, true)

	// this initializes imgui for Vulkan
	init_info := im_vk.InitInfo {}
	init_info.Instance = engine.instance;
	init_info.PhysicalDevice = engine.physical_device;
	init_info.Device = engine.device;
	init_info.Queue = engine.graphics_queue;
	init_info.DescriptorPool = im_pool;
	init_info.MinImageCount = 3;
	init_info.ImageCount = 3;
	init_info.UseDynamicRendering = true;
	init_info.ColorAttachmentFormat = engine.swapchain_image_format;
	init_info.MSAASamples = {._1};

	// We've already loaded the funcs with Odin's built-in loader,
	// imgui needs the addresses of those functions now.
	im_vk.LoadFunctions(proc "c" (function_name: cstring, user_data: rawptr) -> vk.ProcVoidFunction {
		return vk.GetInstanceProcAddr((cast(^vk.Instance)user_data)^, function_name)
	}, &engine.instance)

	im_vk.Init(&init_info, 0)

	// execute a gpu command to upload imgui font textures
	// newer version of imgui automatically creates a command buffer,
	// and destroys the upload data, so we don't actually need to do anything else.
	im_vk.CreateFontsTexture()

	// defer imgui cleanup
	push_deletion_queue(&engine.deletion_queue, im_pool)
}


FrameData :: struct {
	swapchain_semaphore, render_semaphore: vk.Semaphore,
	render_fence:                          vk.Fence,
	command_pool:                          vk.CommandPool,
	main_command_buffer:                   vk.CommandBuffer,
	deletion_queue:                        DeletionQueue,
}

SwapChainSupportDetails :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

current_frame :: proc(engine: ^VulkanEngine) -> ^FrameData {
	return &engine.frames[engine.frame_number % FRAME_OVERLAP]
}

delete_swapchain_support_details :: proc(details: SwapChainSupportDetails) {
	delete(details.formats)
	delete(details.present_modes)
}

fetch_queues :: proc(engine: ^VulkanEngine, device: vk.PhysicalDevice) -> bool {
	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)

	queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
	defer delete(queue_families)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(queue_families))

	has_graphics := false

	for queue_family, i in &queue_families {
		if .GRAPHICS in queue_family.queueFlags {
			engine.graphics_queue_family = u32(i)
			has_graphics = true
		}
	}

	return has_graphics
}

// This allocates format and present_mode slices.
query_swapchain_support :: proc(engine: ^VulkanEngine, device: vk.PhysicalDevice) -> SwapChainSupportDetails {
	details: SwapChainSupportDetails

	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, engine.surface, &details.capabilities)

	{
		format_count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, engine.surface, &format_count, nil)

		formats := make([]vk.SurfaceFormatKHR, format_count)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, engine.surface, &format_count, raw_data(formats))

		details.formats = formats
	}

	{
		present_mode_count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, engine.surface, &present_mode_count, nil)

		present_modes := make([]vk.PresentModeKHR, present_mode_count)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			engine.surface,
			&present_mode_count,
			raw_data(present_modes),
		)

		details.present_modes = present_modes
	}

	return details
}

// This returns true if a surface format was found that matches the requirements.
// Otherwise, this returns the first surface format and false if one wasn't found.
choose_swap_surface_format :: proc(available_formats: []vk.SurfaceFormatKHR) -> (vk.SurfaceFormatKHR, bool) {
	for surface_format in available_formats {
		if surface_format.format == .B8G8R8A8_SRGB && surface_format.colorSpace == .SRGB_NONLINEAR {
			return surface_format, true
		}
	}

	return available_formats[0], false
}

choose_swap_present_mode :: proc(available_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	return .FIFO
}

choose_swap_extent :: proc(engine: ^VulkanEngine, capabilities: ^vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if (capabilities.currentExtent.width != max(u32)) {
		return capabilities.currentExtent
	} else {
		width, height := glfw.GetFramebufferSize(engine.window)

		actual_extent := vk.Extent2D{u32(width), u32(height)}

		actual_extent.width = clamp(
			actual_extent.width,
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		)
		actual_extent.height = clamp(
			actual_extent.height,
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		)

		return actual_extent
	}
}

supports_required_features :: proc(required: $T, test: T) -> bool {
	required := required
	test := test

	id := typeid_of(T)
	names := reflect.struct_field_names(id)
	types := reflect.struct_field_types(id)
	offsets := reflect.struct_field_offsets(id)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, " - ")
	reflect.write_type(&builder, type_info_of(T))
	strings.write_string(&builder, "\n")

	has_any_flags := false
	supports_all_flags := true

	for i in 0 ..< len(offsets) {
		// The flags are of type boolean
		if reflect.type_kind(types[i].id) == .Boolean {
			offset := offsets[i]

			// Grab the values at the offsets
			required_value := (cast(^b32)(uintptr(&required) + offset))^
			test_value := (cast(^b32)(uintptr(&test) + offset))^

			// Check if the flag is required
			if required_value {
				strings.write_string(&builder, "   + ")
				strings.write_string(&builder, names[i])

				// Returns false if the test doesn't have the required flag.
				if required_value != test_value {
					strings.write_string(&builder, " \xE2\x9D\x8C\n")
					supports_all_flags = false
				} else {
					strings.write_string(&builder, " \xE2\x9C\x94\n")
					has_any_flags = true
				}
			}
		}
	}

	if has_any_flags {
		fmt.print(strings.to_string(builder))
	}

	return supports_all_flags
}

is_device_suitable :: proc(engine: ^VulkanEngine, device: vk.PhysicalDevice) -> bool {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(device, &properties)

	vk_13_features := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	}

	vk_12_features := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &vk_13_features,
	}

	vk_11_features := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext = &vk_12_features,
	}

	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &vk_11_features,
	}

	vk.GetPhysicalDeviceFeatures2(device, &features)

	fmt.printfln("Required Features:")
	supports_features :=
		supports_required_features(REQUIRED_FEATURES, features) &&
		supports_required_features(REQUIRED_VK_11_FEATURES, vk_11_features) &&
		supports_required_features(REQUIRED_VK_12_FEATURES, vk_12_features) &&
		supports_required_features(REQUIRED_VK_13_FEATURES, vk_13_features)

	extensions_supported := check_device_extension_support(device)

	swapchain_adequate := false
	if extensions_supported {
		swapchain_support := query_swapchain_support(engine, device)
		defer delete_swapchain_support_details(swapchain_support)

		swapchain_adequate = len(swapchain_support.formats) > 0 && len(swapchain_support.present_modes) > 0
	}

	return swapchain_adequate && extensions_supported && properties.deviceType == .DISCRETE_GPU && supports_features
}

check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
	extension_count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)

	available_extensions := make([]vk.ExtensionProperties, extension_count)
	defer delete(available_extensions)
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(available_extensions))

	for &expected_extension in DEVICE_EXTENSIONS {
		found := false

		for available in &available_extensions {
			if libc.strcmp(cstring(&available.extensionName[0]), expected_extension) == 0 {
				found = true
				break
			}
		}

		found or_return
	}

	return true
}

create_surface :: proc(engine: ^VulkanEngine) {
	vk_check(glfw.CreateWindowSurface(engine.instance, engine.window, nil, &engine.surface))
}

init_window :: proc(engine: ^VulkanEngine) -> bool {
	glfw.Init()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

	engine.window = glfw.CreateWindow(
		i32(engine.window_extent.width),
		i32(engine.window_extent.height),
		"Vulkan",
		nil,
		nil,
	)

	return true
}

debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.eprintln("validation layer:", callback_data.pMessage)

	return false
}

setup_debug_messenger :: proc(engine: ^VulkanEngine) {
	if ENABLE_VALIDATION_LAYERS {
		fmt.println("Creating Debug Messenger")
		create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.VERBOSE, .WARNING},
			messageType     = {.GENERAL, .VALIDATION},
			pfnUserCallback = debug_callback,
			pUserData       = nil,
		}

		vk_check(vk.CreateDebugUtilsMessengerEXT(engine.instance, &create_info, nil, &engine.debug_messenger))
	}
}

check_validation_layers :: proc() -> bool {
	layer_count: u32 = 0
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)

	available_layers := make([]vk.LayerProperties, layer_count)
	defer delete(available_layers)
	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers))

	for layer_name in VALIDATION_LAYERS {
		layer_found := false

		for layer_property in &available_layers {
			if libc.strcmp(layer_name, cstring(&layer_property.layerName[0])) == 0 {
				layer_found = true
				break
			}
		}

		layer_found or_return
	}


	return true
}

get_required_extensions :: proc() -> [dynamic]cstring {
	glfw_extensions := glfw.GetRequiredInstanceExtensions()

	extension_count := len(glfw_extensions)

	extensions: [dynamic]cstring
	resize(&extensions, extension_count)

	for ext, i in glfw_extensions {
		extensions[i] = ext
	}

	if ENABLE_VALIDATION_LAYERS {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	return extensions
}

create_instance :: proc(engine: ^VulkanEngine) -> bool {
	// Loads vulkan api functions needed to create an instance
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))

	if ENABLE_VALIDATION_LAYERS && !check_validation_layers() {
		panic("validation layers are not available")
	}

	app_info := vk.ApplicationInfo{}
	app_info.sType = .APPLICATION_INFO
	app_info.pApplicationName = "Hello Triangle"
	app_info.applicationVersion = vk.MAKE_VERSION(0, 0, 1)
	app_info.pEngineName = "No Engine"
	app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0)
	app_info.apiVersion = vk.API_VERSION_1_3

	create_info: vk.InstanceCreateInfo
	create_info.sType = .INSTANCE_CREATE_INFO
	create_info.pApplicationInfo = &app_info

	extensions := get_required_extensions()
	defer delete(extensions)

	create_info.ppEnabledExtensionNames = raw_data(extensions)
	create_info.enabledExtensionCount = cast(u32)len(extensions)

	debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT{}
	if ENABLE_VALIDATION_LAYERS {
		fmt.println("yeaaa")
		create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
		create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)

		debug_create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
		debug_create_info.messageSeverity = {.WARNING, .ERROR}
		debug_create_info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
		debug_create_info.pfnUserCallback = debug_callback

		create_info.pNext = &debug_create_info
	} else {
		create_info.enabledLayerCount = 0
		create_info.pNext = nil
	}

	vk_check(vk.CreateInstance(&create_info, nil, &engine.instance))

	// Load instance-specific procedures
	vk.load_proc_addresses_instance(engine.instance)

	n_ext: u32
	vk.EnumerateInstanceExtensionProperties(nil, &n_ext, nil)

	extension_props := make([]vk.ExtensionProperties, n_ext)
	defer delete(extension_props)

	vk.EnumerateInstanceExtensionProperties(nil, &n_ext, raw_data(extension_props))

	fmt.println("Available Extensions:")

	bytes, ok := os.read_entire_file("")

	for ext in &extension_props {
		fmt.printfln(" - %s", cstring(&ext.extensionName[0]))
	}

	if ENABLE_VALIDATION_LAYERS && !check_validation_layers() {
		panic("Validation layers are not available")
	}

	return true
}

pick_physical_device :: proc(engine: ^VulkanEngine) {
	device_count: u32 = 0

	vk.EnumeratePhysicalDevices(engine.instance, &device_count, nil)

	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(engine.instance, &device_count, raw_data(devices))

	for device in devices {
		if is_device_suitable(engine, device) {
			engine.physical_device = device
			break
		}
	}

	if engine.physical_device == nil {
		panic("No GPU found that supports all required features.")
	}
}

create_logical_device :: proc(engine: ^VulkanEngine) {
	queue_priority: f32 = 1.0

	queue_create_info: vk.DeviceQueueCreateInfo
	queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO
	queue_create_info.queueFamilyIndex = engine.graphics_queue_family
	queue_create_info.queueCount = 1
	queue_create_info.pQueuePriorities = &queue_priority

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &REQUIRED_FEATURES,
		pQueueCreateInfos       = &queue_create_info,
		queueCreateInfoCount    = 1,
		ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
		enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
	}

	vk_check(vk.CreateDevice(engine.physical_device, &device_create_info, nil, &engine.device))

	vk.GetDeviceQueue(engine.device, engine.graphics_queue_family, 0, &engine.graphics_queue)
}

init_commands :: proc(engine: ^VulkanEngine) {
	command_pool_info := vk.CommandPoolCreateInfo{}
	command_pool_info.sType = .COMMAND_POOL_CREATE_INFO
	command_pool_info.pNext = nil
	command_pool_info.flags = {.RESET_COMMAND_BUFFER}
	command_pool_info.queueFamilyIndex = engine.graphics_queue_family

	for i in 0 ..< FRAME_OVERLAP {
		vk_check(vk.CreateCommandPool(engine.device, &command_pool_info, nil, &engine.frames[i].command_pool))

		// allocate the default command buffer that we will use for rendering
		cmd_alloc_info := vk.CommandBufferAllocateInfo{}
		cmd_alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO
		cmd_alloc_info.pNext = nil
		cmd_alloc_info.commandPool = engine.frames[i].command_pool
		cmd_alloc_info.commandBufferCount = 1
		cmd_alloc_info.level = .PRIMARY

		vk_check(vk.AllocateCommandBuffers(engine.device, &cmd_alloc_info, &engine.frames[i].main_command_buffer))
	}

	vk_check(vk.CreateCommandPool(engine.device, &command_pool_info, nil, &engine.imm_command_pool));

	// allocate the command buffer for immediate submits
	cmd_alloc_info := init_command_buffer_allocate_info(engine.imm_command_pool, 1);

	vk_check(vk.AllocateCommandBuffers(engine.device, &cmd_alloc_info, &engine.imm_command_buffer));

	push_deletion_queue(&engine.deletion_queue, engine.imm_command_pool)
}

create_image_views :: proc(engine: ^VulkanEngine) {
	engine.swapchain_image_views = make([]vk.ImageView, len(engine.swapchain_images))

	for i in 0 ..< len(engine.swapchain_images) {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = engine.swapchain_images[i],
			viewType = .D2,
			format = engine.swapchain_image_format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange =  {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		vk_check(vk.CreateImageView(engine.device, &create_info, nil, &engine.swapchain_image_views[i]))
	}
}

create_swapchain :: proc(engine: ^VulkanEngine) {
	swapchain_support := query_swapchain_support(engine, engine.physical_device)
	defer delete_swapchain_support_details(swapchain_support)

	surface_format, _ := choose_swap_surface_format(swapchain_support.formats)
	present_mode := choose_swap_present_mode(swapchain_support.present_modes)
	extent := choose_swap_extent(engine, &swapchain_support.capabilities)

	image_count := swapchain_support.capabilities.minImageCount + 1

	if swapchain_support.capabilities.maxImageCount > 0 && image_count > swapchain_support.capabilities.maxImageCount {
		image_count = swapchain_support.capabilities.maxImageCount
	}

	create_info: vk.SwapchainCreateInfoKHR
	create_info.sType = .SWAPCHAIN_CREATE_INFO_KHR
	create_info.surface = engine.surface
	create_info.minImageCount = image_count
	create_info.imageFormat = surface_format.format
	create_info.imageColorSpace = surface_format.colorSpace
	create_info.imageExtent = extent
	create_info.imageArrayLayers = 1
	create_info.imageUsage = {.COLOR_ATTACHMENT}

	// TODO: Support multiple queues?
	create_info.imageSharingMode = .EXCLUSIVE
	create_info.queueFamilyIndexCount = 0 // Optional
	create_info.pQueueFamilyIndices = nil // Optional

	create_info.preTransform = swapchain_support.capabilities.currentTransform
	create_info.compositeAlpha = {.OPAQUE}
	create_info.presentMode = present_mode
	create_info.clipped = true
	create_info.oldSwapchain = {}

	vk_check(vk.CreateSwapchainKHR(engine.device, &create_info, nil, &engine.swapchain))

	vk.GetSwapchainImagesKHR(engine.device, engine.swapchain, &image_count, nil)
	engine.swapchain_images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(engine.device, engine.swapchain, &image_count, raw_data(engine.swapchain_images))

	engine.swapchain_image_format = surface_format.format
	engine.swapchain_extent = extent

	draw_image_extent := vk.Extent3D{engine.window_extent.width, engine.window_extent.height, 1}

	engine.draw_image.format = .R16G16B16A16_SFLOAT
	engine.draw_image.extent = draw_image_extent

	draw_image_usages := vk.ImageUsageFlags{.TRANSFER_SRC, .TRANSFER_DST, .STORAGE, .COLOR_ATTACHMENT}

	rimg_info := init_image_create_info(engine.draw_image.format, draw_image_usages, draw_image_extent)

	rimg_alloc_info := vma.AllocationCreateInfo {
		usage         = .GPU_ONLY,
		requiredFlags = {.DEVICE_LOCAL},
	}

	vma.CreateImage(
		engine.allocator,
		&rimg_info,
		&rimg_alloc_info,
		&engine.draw_image.image,
		&engine.draw_image.allocation,
		nil,
	)

	rview_info := init_imageview_create_info(engine.draw_image.format, engine.draw_image.image, {.COLOR})

	vk_check(vk.CreateImageView(engine.device, &rview_info, nil, &engine.draw_image.image_view))

	push_deletion_queue(&engine.deletion_queue, engine.draw_image.image_view)
	push_deletion_queue(&engine.deletion_queue, engine.draw_image.image, engine.draw_image.allocation)
}

init_sync_structures :: proc(engine: ^VulkanEngine) {
	fence_create_info := init_fence_create_info({.SIGNALED})
	semaphore_create_info := init_semaphore_create_info({})

	for &frame in &engine.frames {
		vk_check(vk.CreateFence(engine.device, &fence_create_info, nil, &frame.render_fence))

		vk_check(vk.CreateSemaphore(engine.device, &semaphore_create_info, nil, &frame.swapchain_semaphore))
		vk_check(vk.CreateSemaphore(engine.device, &semaphore_create_info, nil, &frame.render_semaphore))
	}

	vk.CreateFence(engine.device, &fence_create_info, nil, &engine.imm_fence)
	push_deletion_queue(&engine.deletion_queue, engine.imm_fence)
}

init_descriptors :: proc(engine: ^VulkanEngine) {
	//create a descriptor pool that will hold 10 sets with 1 image each
	sizes: []PoolSizeRatio = {{.STORAGE_IMAGE, 1}}

	init_pool(&engine.global_descriptor_allocator, engine.device, 10, sizes)

	{
		engine.draw_image_descriptor_layout = create_descriptor_set_layout(
			engine,
			[?]DescriptorBinding{{0, .STORAGE_IMAGE}},
			{.COMPUTE},
		)
	}

	//allocate a descriptor set for our draw image
	engine.draw_image_descriptors = allocate_pool(
		&engine.global_descriptor_allocator,
		engine.device,
		engine.draw_image_descriptor_layout,
	)

	img_info := vk.DescriptorImageInfo{}
	img_info.imageLayout = .GENERAL
	img_info.imageView = engine.draw_image.image_view

	draw_image_write := vk.WriteDescriptorSet{}
	draw_image_write.sType = .WRITE_DESCRIPTOR_SET
	draw_image_write.pNext = nil

	draw_image_write.dstBinding = 0
	draw_image_write.dstSet = engine.draw_image_descriptors
	draw_image_write.descriptorCount = 1
	draw_image_write.descriptorType = .STORAGE_IMAGE
	draw_image_write.pImageInfo = &img_info

	vk.UpdateDescriptorSets(engine.device, 1, &draw_image_write, 0, nil)
}

init_pipelines :: proc(engine: ^VulkanEngine) {
	init_background_pipelines(engine)
}

init_background_pipelines :: proc(engine: ^VulkanEngine) {
	// TODO: ensure last write is updated
	is_shaders_updated()

	info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		pSetLayouts    = &engine.draw_image_descriptor_layout,
		setLayoutCount = 1,
	}

	vk.CreatePipelineLayout(engine.device, &info, nil, &engine.gradient_pipeline_layout)

	compute_draw_shader, ok := util_load_shader_module("./shaders/out/gradient.comp.spv", engine.device)

	if !ok {
		fmt.eprintln("Error when building the compute shader")
	}

	stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = compute_draw_shader,
		pName  = "main",
	}

	compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = engine.gradient_pipeline_layout,
		stage  = stage_info,
	}

	vk_check(
		vk.CreateComputePipelines(engine.device, 0, 1, &compute_pipeline_create_info, nil, &engine.gradient_pipeline),
	)

	vk.DestroyShaderModule(engine.device, compute_draw_shader, nil)

	push_deletion_queue(&engine.deletion_queue, engine.gradient_pipeline_layout)
	push_deletion_queue(&engine.deletion_queue, engine.gradient_pipeline)
}

init_vulkan :: proc(engine: ^VulkanEngine) -> bool {
	create_instance(engine) or_return
	setup_debug_messenger(engine)
	create_surface(engine)

	pick_physical_device(engine)
	fetch_queues(engine, engine.physical_device)
	create_logical_device(engine)

	vulkan_functions := vma.create_vulkan_functions()

	allocator_info := vma.AllocatorCreateInfo {
		vulkanApiVersion = vk.API_VERSION_1_3,
		physicalDevice   = engine.physical_device,
		device           = engine.device,
		instance         = engine.instance,
		flags            = {.BUFFER_DEVICE_ADDRESS},
		pVulkanFunctions = &vulkan_functions,
	}

	vma.CreateAllocator(&allocator_info, &engine.allocator)

	push_deletion_queue(&engine.deletion_queue, engine.allocator)

	create_swapchain(engine)
	create_image_views(engine)

	init_commands(engine)
	init_sync_structures(engine)

	init_descriptors(engine)
	init_pipelines(engine)

	init_imgui(engine)

	return true
}

cleanup_window :: proc(engine: ^VulkanEngine) {
	glfw.DestroyWindow(engine.window)
	glfw.Terminate()
}

cleanup_vulkan :: proc(engine: ^VulkanEngine) {
	vk.DeviceWaitIdle(engine.device)

	// Cleanup queued resources
	flush_deletion_queue(engine, &engine.deletion_queue)

	delete_deletion_queue(engine.deletion_queue)

	im_vk.Shutdown()

	for &frame in engine.frames {
		vk.DestroyCommandPool(engine.device, frame.command_pool, nil)

		vk.DestroyFence(engine.device, frame.render_fence, nil)
		vk.DestroySemaphore(engine.device, frame.render_semaphore, nil)
		vk.DestroySemaphore(engine.device, frame.swapchain_semaphore, nil)

		delete_deletion_queue(frame.deletion_queue)
	}

	for &image_view in engine.swapchain_image_views {
		vk.DestroyImageView(engine.device, image_view, nil)
	}

	for &image in engine.swapchain_images {
		vk.DestroyImage(engine.device, image, nil)
	}

	delete(engine.swapchain_image_views)
	delete(engine.swapchain_images)

	vk.DestroySwapchainKHR(engine.device, engine.swapchain, nil)
	vk.DestroyDevice(engine.device, nil)
	vk.DestroySurfaceKHR(engine.instance, engine.surface, nil)

	vk.DestroyDebugUtilsMessengerEXT(engine.instance, engine.debug_messenger, nil)
	vk.DestroyInstance(engine.instance, nil)
}

main_loop :: proc(engine: ^VulkanEngine) {
	for (!glfw.WindowShouldClose(engine.window)) {
		glfw.PollEvents()

		im_vk.NewFrame()
		im_glfw.NewFrame()
		im.NewFrame()

		im.ShowDemoWindow()

		im.Render()

		draw(engine)
	}
}

draw_imgui :: proc(engine: ^VulkanEngine, cmd: vk.CommandBuffer, target_image_view: vk.ImageView) {
	color_attachment := init_attachment_info(target_image_view, nil, .GENERAL)
	render_info := init_rendering_info(engine.swapchain_extent, &color_attachment, nil)

	vk.CmdBeginRendering(cmd, &render_info)

	im_vk.RenderDrawData(im.GetDrawData(), cmd)

	vk.CmdEndRendering(cmd)
}

draw_background :: proc(engine: ^VulkanEngine, cmd: vk.CommandBuffer) {
	clear_color: vk.ClearColorValue
	flash: f32 = math.abs(math.sin(f32(engine.frame_number) / 120.0))
	clear_color = vk.ClearColorValue {
		float32 = {0.0, 0.0, flash, 1.0},
	}

	clear_range := init_image_subresource_range({.COLOR})

	vk.CmdClearColorImage(cmd, engine.draw_image.image, .GENERAL, &clear_color, 1, &clear_range)

	// bind the gradient drawing compute pipeline
	vk.CmdBindPipeline(cmd, .COMPUTE, engine.gradient_pipeline)

	// bind the descriptor set containing the draw image for the compute pipeline
	vk.CmdBindDescriptorSets(
		cmd,
		.COMPUTE,
		engine.gradient_pipeline_layout,
		0,
		1,
		&engine.draw_image_descriptors,
		0,
		nil,
	)

	// execute the compute pipeline dispatch. We are using 16x16 workgroup size so we need to divide by it
	vk.CmdDispatch(
		cmd,
		u32(math.ceil(f32(engine.draw_extent.width) / 16.0)),
		u32(math.ceil(f32(engine.draw_extent.height) / 16.0)),
		1,
	)
}

LAST_WRITE: os.File_Time

is_shaders_updated :: proc() -> bool {
	lib_last_write, lib_last_write_err := os.last_write_time_by_name("./shaders/out/gradient.comp.spv")

	if LAST_WRITE == lib_last_write {
		return false
	}

	LAST_WRITE = lib_last_write

	return true
}

draw :: proc(engine: ^VulkanEngine) {
	vk_check(vk.WaitForFences(engine.device, 1, &current_frame(engine).render_fence, true, 1_000_000_000))

	// Delete resources for the current frame
	flush_deletion_queue(engine, &current_frame(engine).deletion_queue)

	when ODIN_DEBUG {
		if is_shaders_updated() {
			fmt.println("Updating shader module")
			init_pipelines(engine)
		}
	}

	vk_check(vk.ResetFences(engine.device, 1, &current_frame(engine).render_fence))

	swapchain_image_index: u32

	vk_check(
		vk.AcquireNextImageKHR(
			engine.device,
			engine.swapchain,
			1_000_000_000,
			current_frame(engine).swapchain_semaphore,
			vk.Fence(0), // null
			&swapchain_image_index,
		),
	)

	//naming it cmd for shorter writing
	cmd := current_frame(engine).main_command_buffer

	// now that we are sure that the commands finished executing, we can safely
	// reset the command buffer to begin recording again.
	vk_check(vk.ResetCommandBuffer(cmd, {.RELEASE_RESOURCES}))

	//begin the command buffer recording. We will use this command buffer exactly once, so we want to let vulkan know that
	cmd_begin_info := init_command_buffer_begin_info({.ONE_TIME_SUBMIT})


	engine.draw_extent.width = engine.draw_image.extent.width
	engine.draw_extent.height = engine.draw_image.extent.height

	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	// transition our main draw image into general layout so we can write into it
	// we will overwrite it all so we dont care about what was the older layout
	util_transition_image(cmd, engine.draw_image.image, .UNDEFINED, .GENERAL)

	draw_background(engine, cmd)

	//transition the draw image and the swapchain image into their correct transfer layouts
	util_transition_image(cmd, engine.draw_image.image, .GENERAL, .TRANSFER_SRC_OPTIMAL)
	util_transition_image(cmd, engine.swapchain_images[swapchain_image_index], .UNDEFINED, .TRANSFER_DST_OPTIMAL)

	// execute a copy from the draw image into the swapchain
	util_copy_image_to_image(
		cmd,
		engine.draw_image.image,
		engine.swapchain_images[swapchain_image_index],
		engine.draw_extent,
		engine.swapchain_extent,
	)

	// set swapchain image layout to Attachment Optimal so we can draw it
	util_transition_image(cmd, engine.swapchain_images[swapchain_image_index], .TRANSFER_DST_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL);

	//draw imgui into the swapchain image
	draw_imgui(engine, cmd, engine.swapchain_image_views[swapchain_image_index]);

	// set swapchain image layout to Present so we can show it on the screen
	util_transition_image(cmd, engine.swapchain_images[swapchain_image_index], .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)

	//finalize the command buffer (we can no longer add commands, but it can now be executed)
	vk_check(vk.EndCommandBuffer(cmd))


	cmd_info := init_command_buffer_submit_info(cmd)

	wait_info := init_semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT}, current_frame(engine).swapchain_semaphore)
	signal_info := init_semaphore_submit_info({.ALL_GRAPHICS}, current_frame(engine).render_semaphore)

	submit := init_submit_info(&cmd_info, &signal_info, &wait_info)

	vk_check(vk.QueueSubmit2(engine.graphics_queue, 1, &submit, current_frame(engine).render_fence))

	present_info := vk.PresentInfoKHR {
		sType           = .PRESENT_INFO_KHR,
		pSwapchains     = &engine.swapchain,
		swapchainCount  = 1,
		pWaitSemaphores = &current_frame(engine).render_semaphore,
		pImageIndices   = &swapchain_image_index,
	}

	vk_check(vk.QueuePresentKHR(engine.graphics_queue, &present_info))

	engine.frame_number += 1
}

run :: proc(engine: ^VulkanEngine) -> bool {
	init_window(engine) or_return
	defer cleanup_window(engine)

	init_vulkan(engine) or_return
	defer cleanup_vulkan(engine)

	main_loop(engine)

	return true
}
