package main

import "core:/c/libc"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:runtime"
import "core:slice"
import "core:strings"

import win "core:sys/windows"
import "vendor:glfw"
import vk "vendor:vulkan"

import im "deps:odin-imgui"
import "deps:odin-imgui/imgui_impl_glfw"
import "deps:odin-imgui/imgui_impl_vulkan"

// Set required features here. This will also be passed into device creation to enable these features.
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

vk_check :: proc(result: vk.Result, loc := #caller_location) {
	p := context.assertion_failure_proc
	if result != .SUCCESS {
		p("vk_check failed", reflect.enum_string(result), loc)
	}
}

VulkanEngine :: struct {
	debug_messenger:        vk.DebugUtilsMessengerEXT,
	window:                 glfw.WindowHandle,
	instance:               vk.Instance,
	physical_device:        vk.PhysicalDevice,
	device:                 vk.Device,
	// Queues
	graphics_queue:         vk.Queue,
	graphics_queue_family:  u32,
	surface:                vk.SurfaceKHR,
	// Swapchain
	swapchain:              vk.SwapchainKHR,
	swapchain_images:       []vk.Image,
	swapchain_image_views:  []vk.ImageView,
	swapchain_image_format: vk.Format,
	swapchain_extent:       vk.Extent2D,
	// Command Pool/Buffer
	frames:                 [FRAME_OVERLAP]FrameData,
	frame_number:           int,
}

FrameData :: struct {
	swapchain_semaphore, render_semaphore: vk.Semaphore,
	render_fence:                          vk.Fence,
	command_pool:                          vk.CommandPool,
	main_command_buffer:                   vk.CommandBuffer,
}

current_frame :: proc(engine: ^VulkanEngine) -> ^FrameData {
	return &engine.frames[engine.frame_number % FRAME_OVERLAP]
}

SwapChainSupportDetails :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
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

	engine.window = glfw.CreateWindow(800, 600, "Vulkan", nil, nil)

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

	extensions := make([dynamic]cstring, extension_count)

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

create_commands :: proc(engine: ^VulkanEngine) {
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
}

init_sync_structures :: proc(engine: ^VulkanEngine) {
	fence_create_info := init_fence_create_info({.SIGNALED})
	semaphore_create_info := init_semaphore_create_info({})

	for &frame in &engine.frames {
		vk_check(vk.CreateFence(engine.device, &fence_create_info, nil, &frame.render_fence))

		vk_check(vk.CreateSemaphore(engine.device, &semaphore_create_info, nil, &frame.swapchain_semaphore))
		vk_check(vk.CreateSemaphore(engine.device, &semaphore_create_info, nil, &frame.render_semaphore))
	}
}

init_vulkan :: proc(engine: ^VulkanEngine) -> bool {
	create_instance(engine) or_return
	setup_debug_messenger(engine)
	create_surface(engine)

	pick_physical_device(engine)
	fetch_queues(engine, engine.physical_device)
	create_logical_device(engine)
	create_swapchain(engine)
	create_image_views(engine)

	create_commands(engine)
	init_sync_structures(engine)

	return true
}

cleanup_window :: proc(engine: ^VulkanEngine) {
	glfw.DestroyWindow(engine.window)
	glfw.Terminate()
}

cleanup_vulkan :: proc(engine: ^VulkanEngine) {
	vk.DeviceWaitIdle(engine.device)

	for &frame in engine.frames {
		vk.DestroyCommandPool(engine.device, frame.command_pool, nil)

		vk.DestroyFence(engine.device, frame.render_fence, nil)
		vk.DestroySemaphore(engine.device, frame.render_semaphore, nil)
		vk.DestroySemaphore(engine.device, frame.swapchain_semaphore, nil)
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
		draw(engine)
	}
}

transition_image :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	current_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
) {
	image_barrier := vk.ImageMemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.ALL_COMMANDS},
		srcAccessMask = {.MEMORY_WRITE},
		dstStageMask  = {.ALL_COMMANDS},
		dstAccessMask = {.MEMORY_WRITE | .MEMORY_READ},
		oldLayout     = current_layout,
		newLayout     = new_layout,
	}

	aspect_mask: vk.ImageAspectFlags = (new_layout == .ATTACHMENT_OPTIMAL) ? {.DEPTH} : {.COLOR}

	sub_image := vk.ImageSubresourceRange {
		aspectMask     = aspect_mask,
		baseMipLevel   = 0,
		levelCount     = vk.REMAINING_MIP_LEVELS,
		baseArrayLayer = 0,
		layerCount     = vk.REMAINING_ARRAY_LAYERS,
	}

	image_barrier.subresourceRange = sub_image
	image_barrier.image = image

	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &image_barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

draw :: proc(engine: ^VulkanEngine) {
	vk_check(vk.WaitForFences(engine.device, 1, &current_frame(engine).render_fence, true, 1_000_000_000))
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

	//start the command buffer recording
	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	util_transition_image(cmd, engine.swapchain_images[swapchain_image_index], .UNDEFINED, .GENERAL)

	clear_color: vk.ClearColorValue
	flash: f32 = math.abs(math.sin(f32(engine.frame_number) / 120.0))
	clear_color = vk.ClearColorValue {
		float32 = {0.0, 0.0, flash, 1.0},
	}

	clear_range := init_image_subresource_range({.COLOR})

	vk.CmdClearColorImage(cmd, engine.swapchain_images[swapchain_image_index], .GENERAL, &clear_color, 1, &clear_range)

	//make the swapchain image into presentable mode
	util_transition_image(cmd, engine.swapchain_images[swapchain_image_index], .GENERAL, .PRESENT_SRC_KHR)
	
	//finalize the command buffer (we can no longer add commands, but it can now be executed)
	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := init_command_buffer_submit_info(cmd)

	wait_info := init_semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT}, current_frame(engine).swapchain_semaphore)
	signal_info := init_semaphore_submit_info({.ALL_GRAPHICS}, current_frame(engine).render_semaphore)

	submit := init_submit_info(&cmd_info, &signal_info, &wait_info)

	vk_check(vk.QueueSubmit2(engine.graphics_queue, 1, &submit, current_frame(engine).render_fence))

	present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		pSwapchains = &engine.swapchain,
		swapchainCount = 1,
		pWaitSemaphores = &current_frame(engine).render_semaphore,
		pImageIndices = &swapchain_image_index,
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

main :: proc() {
	when ODIN_OS == .Windows {
		// Use UTF-8 for console output (fixes emojis/unicode/utf-8 shenanigans)
		win.SetConsoleOutputCP(win.CP_UTF8)
	}
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	app := VulkanEngine{}

	if !run(&app) {
		fmt.println("App could not be initialized.")
	}
}
