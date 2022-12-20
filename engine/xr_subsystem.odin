package engine

import "core:fmt"
import "core:math"
import "core:runtime"
import "core:strings"
import SDL "vendor:sdl2"
import vk "vendor:vulkan"
import xr "openxr"

XR_INSTANCE_EXTENSIONS := [?]cstring{xr.EXT_DEBUG_UTILS_EXTENSION_NAME, xr.KHR_VULKAN_ENABLE_EXTENSION_NAME}
VK_INSTANCE_EXTENSIONS := [?]cstring{vk.EXT_DEBUG_UTILS_EXTENSION_NAME}
VK_DEVICE_EXTENSIONS := [?]cstring{vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME}
VK_INSTANCE_LAYERS := [?]cstring{"VK_LAYER_KHRONOS_validation"}
VK_DEVICE_LAYERS := [?]cstring{"VK_LAYER_KHRONOS_validation"}


// OpenXR Substem
Xr_Subsystem :: struct {
	// Interned strings
	intern:             strings.Intern,

	// OpenXR Resources
	openxr:             xr.Instance,
	debug_messenger:    xr.DebugUtilsMessengerEXT,
	system:             xr.SystemId,
	system_properties:  xr.SystemProperties,
	view_confs:         []xr.ViewConfigurationView,
	session:            xr.Session,
	space:              xr.Space,
	colour_swapchains:  []xr.Swapchain,
	depth_swapchains:   []xr.Swapchain,

	// Vulkan Resources
	vulkan:             vk.Instance,
	physical_device:    vk.PhysicalDevice,
	device:             vk.Device,
	colour_images:      [][]xr.SwapchainImageVulkanKHR,
	depth_images:       [][]xr.SwapchainImageVulkanKHR,
	colour_image_views: [][]vk.ImageView,
	depth_image_views:  [][]vk.ImageView,
	extents:            []vk.Extent2D,
	pipeline_layout:    vk.PipelineLayout,
	pipeline:           vk.Pipeline,
	command_pool:       vk.CommandPool,
	command_buffers:    [2]vk.CommandBuffer,
}

xr_debug_callback :: proc "c" (
	messageSeverity: xr.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: xr.DebugUtilsMessageTypeFlagsEXT,
	callbackData: ^xr.DebugUtilsMessengerCallbackDataEXT,
	userData: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.printf("validation layer: %s\n", callbackData.message)
	return false
}

xr_decompose_version :: proc(version: u64) -> (major, minor, patch: u64) {
	major = (version >> 48) & 0xffff
	minor = (version >> 32) & 0xffff
	patch = (version) & 0xffffffff
	return
}

// Builds a slice of OpenXR instance extensions based on the desired defaults, and the available ones. Crashes if any of our
// requested extensions aren't available.
xr_instance_extensions :: proc(intern: ^strings.Intern) -> (extensions: []cstring) {
	// Query available extensions
	available_count: u32
	xr.EnumerateInstanceExtensionProperties(nil, 0, &available_count, nil)
	available := make([]xr.ExtensionProperties, available_count)
	defer delete(available)
	for ext in &available {ext.sType = .EXTENSION_PROPERTIES}
	xr.EnumerateInstanceExtensionProperties(nil, available_count, &available_count, &available[0])

	// Assert our extensions are all there
	for desired in XR_INSTANCE_EXTENSIONS {
		is_available := false
		for avail in &available {
			if desired != cstring(&avail.extensionName[0]) {continue}
			is_available = true
			break
		}
		if !is_available {panic(fmt.aprintf("OpenXR Instance Extension {} unavailable.", desired))}
	}

	// Copy and return the extensions
	extensions = make([]cstring, len(XR_INSTANCE_EXTENSIONS))
	for ext, i in &extensions {
		cstr, err := strings.intern_get_cstring(intern, string(XR_INSTANCE_EXTENSIONS[i]))
		ext = cstr
	}

	return
}

// Builds a slice of Vulkan instance extensions based on our desired ones, the ones requested by OpenXR, and the ones that are
// available. Skips unavailable ones requested by OpenXR and crashes if ours aren't available.
vk_instance_extensions :: proc(
	instance: xr.Instance,
	system: xr.SystemId,
	intern: ^strings.Intern,
) -> (
	extensions: []cstring,
) {
	// Query available extensions
	available_count: u32
	vk.EnumerateInstanceExtensionProperties(nil, &available_count, nil)
	available := make([]vk.ExtensionProperties, available_count)
	defer delete(available)
	vk.EnumerateInstanceExtensionProperties(nil, &available_count, &available[0])

	// Query requested extensions
	req_count: u32
	xr.GetVulkanInstanceExtensionsKHR(instance, system, 0, &req_count, nil)
	req_concat := make([]u8, req_count)
	defer delete(req_concat)
	xr.GetVulkanInstanceExtensionsKHR(instance, system, req_count, &req_count, cstring(&req_concat[0]))

	// Split them into a usable format
	requested := strings.split(string(req_concat), " ")
	defer delete(requested)

	// Compared requested and desired
	extensions_dyn: [dynamic]cstring
	for desired in VK_INSTANCE_EXTENSIONS {
		is_available := false
		for avail in &available {
			if desired != cstring(&avail.extensionName[0]) {continue}
			is_available = true
			break
		}
		if !is_available {panic(fmt.aprintf("Vulkan Instance Extension {} unavailable.", desired))}
		cstr, err := strings.intern_get_cstring(intern, string(desired))
		append(&extensions_dyn, cstr)
	}

	for req in requested {
		is_available := false
		reqc := strings.clone_to_cstring(req) // Have to do this to handle weird nulls
		defer delete(reqc)
		for avail in &available {
			if reqc != cstring(&avail.extensionName[0]) {continue}
			is_available = true
			break
		}
		// Thanks to a cool bug where OpenXR requests extensions it doesn't have!
		// This causes KHR_enable_vulkan2 to crash internally on device creation so we're doing it manually!
		if !is_available {continue}
		cstr, err := strings.intern_get_cstring(intern, string(reqc))
		append(&extensions_dyn, cstr)
	}

	// Build and return our extension list
	extensions = extensions_dyn[0:len(extensions_dyn)]

	return
}

// Builds a slice of Vulkan device extensions based on our desired ones, the ones requested by OpenXR, and the ones that are
// available. Skips unavailable ones requested by OpenXR and crashes if ours aren't available.
vk_device_extensions :: proc(
	instance: xr.Instance,
	system: xr.SystemId,
	physical_device: vk.PhysicalDevice,
	intern: ^strings.Intern,
) -> (
	extensions: []cstring,
) {
	// Query available extensions
	available_count: u32
	vk.EnumerateDeviceExtensionProperties(physical_device, nil, &available_count, nil)
	available := make([]vk.ExtensionProperties, available_count)
	defer delete(available)
	vk.EnumerateDeviceExtensionProperties(physical_device, nil, &available_count, &available[0])

	// Query requested extensions
	req_count: u32
	xr.GetVulkanDeviceExtensionsKHR(instance, system, 0, &req_count, nil)
	req_concat := make([]u8, req_count)
	defer delete(req_concat)
	xr.GetVulkanDeviceExtensionsKHR(instance, system, req_count, &req_count, cstring(&req_concat[0]))

	// Split them into a usable format
	requested := strings.split(string(req_concat), " ")
	defer delete(requested)

	// Compared requested and desired
	extensions_dyn: [dynamic]cstring
	for desired in VK_DEVICE_EXTENSIONS {
		is_available := false
		for avail in &available {
			if desired != cstring(&avail.extensionName[0]) {continue}
			is_available = true
			break
		}
		if !is_available {panic(fmt.aprintf("Vulkan Device Extension {} unavailable.", desired))}
		cstr, err := strings.intern_get_cstring(intern, string(desired))
		append(&extensions_dyn, cstr)
	}

	for req in requested {
		is_available := false
		reqc := strings.clone_to_cstring(req)
		defer delete(reqc)
		for avail in &available {
			if reqc != cstring(&avail.extensionName[0]) {continue}
			is_available = true
			break
		}
		// Thanks to a cool bug where OpenXR requests extensions it doesn't have!
		// This causes KHR_enable_vulkan2 to crash internally on device creation so we're doing it manually!
		if !is_available {continue}
		cstr, err := strings.intern_get_cstring(intern, string(reqc))
		append(&extensions_dyn, cstr)
	}

	// Build and return our extension list
	extensions = extensions_dyn[0:len(extensions_dyn)]

	return
}


@(private = "file")
xr_init_instance :: proc(intern: ^strings.Intern) -> (instance: xr.Instance) {
	xr.load_base_procs()
	extension_names := xr_instance_extensions(intern)
	application_info := xr.ApplicationInfo {
		apiVersion         = xr.CURRENT_API_VERSION,
		applicationName    = xr.make_string(APPLICATION_NAME, 128),
		applicationVersion = 1,
		engineName         = xr.make_string(ENGINE_NAME, 128),
		engineVersion      = 1,
	}
	instance_info := xr.InstanceCreateInfo {
		sType                 = .INSTANCE_CREATE_INFO,
		applicationInfo       = application_info,
		enabledExtensionCount = u32(len(extension_names)),
		enabledExtensionNames = &extension_names[0],
	}
	err := xr.CreateInstance(&instance_info, &instance)
	if err != .SUCCESS {
		panic("failed to create XR instance")
	}
	xr.load_instance_procs(instance)
	return
}

xr_create_debug_messenger :: proc(instance: xr.Instance) -> (messenger: xr.DebugUtilsMessengerEXT) {
	debug_info := xr.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverities = {.ERROR, .WARNING, .INFO},
		messageTypes = {.GENERAL, .VALIDATION, .CONFORMANCE, .PERFORMANCE},
		userCallback = xr_debug_callback,
	}
	result := xr.CreateDebugUtilsMessengerEXT(instance, &debug_info, &messenger)
	if result != .SUCCESS {
		panic("Failed to create Debug Messenger")
	}
	return
}

xr_get_system_and_properties :: proc(instance: xr.Instance) -> (system: xr.SystemId, properties: xr.SystemProperties) {
	system_info := xr.SystemGetInfo {
		sType      = .SYSTEM_GET_INFO,
		formFactor = .HEAD_MOUNTED_DISPLAY,
	}
	err := xr.GetSystem(instance, &system_info, &system)
	if err != .SUCCESS {
		panic("failed to get system")
	}

	err = xr.GetSystemProperties(instance, system, &properties)
	if err != .SUCCESS {
		panic("failed to get system properties")
	}

	return
}

xr_get_view_configs :: proc(instance: xr.Instance, system: xr.SystemId) -> (view_confs: []xr.ViewConfigurationView) {
	view_count: u32
	conf_type := xr.ViewConfigurationType.PRIMARY_STEREO
	err := xr.EnumerateViewConfigurationViews(instance, system, conf_type, 0, &view_count, nil)
	if err != .SUCCESS {
		panic("failed to enumerate configuration views")
	}
	view_confs = make([]xr.ViewConfigurationView, view_count)
	err = xr.EnumerateViewConfigurationViews(instance, system, conf_type, 4, &view_count, &view_confs[0])
	if err != .SUCCESS {
		panic("failed to enumerate configuration views")
	}

	return
}
xr_create_vulkan_instance :: proc(
	instance: xr.Instance,
	system: xr.SystemId,
	intern: ^strings.Intern,
) -> (
	vk_instance: vk.Instance,
) {
	// Check our desired Vulkan version is available (it's not... which is why we're using 1.2)
	requirements: xr.GraphicsRequirementsVulkanKHR
	result := xr.GetVulkanGraphicsRequirementsKHR(instance, system, &requirements)
	if result != .SUCCESS {panic("Failed to get Vulkan requirements from OpenXR")}
	if xr.MAKE_VERSION(1, 2, 0) > requirements.maxApiVersionSupported {panic("Vulkan 1.2 not supported")}

	// Load in our base vulkan procs
	vk.load_proc_addresses_global(rawptr(vkGetInstanceProcAddr))

	// Build our list of instance extension
	extension_names := vk_instance_extensions(instance, system, intern)
	defer delete(extension_names)

	application_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "Odin Vulkan OpenXR",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "No Engine",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}
	instance_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &application_info,
		enabledExtensionCount   = u32(len(extension_names)),
		ppEnabledExtensionNames = &extension_names[0],
		// enabledLayerCount       = len(VK_INSTANCE_LAYERS),
		// ppEnabledLayerNames     = &VK_INSTANCE_LAYERS[0],
	}
	vk_result := vk.CreateInstance(&instance_info, nil, &vk_instance)
	if vk_result != .SUCCESS {panic("Vulkan instance creation failed")}
	vk.load_proc_addresses_instance(vk_instance)

	return
}


xr_create_vulkan_device :: proc(
	instance: xr.Instance,
	system: xr.SystemId,
	vk_instance: vk.Instance,
	intern: ^strings.Intern,
) -> (
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
) {
	result := xr.GetVulkanGraphicsDeviceKHR(instance, system, vk_instance, &physical_device)
	if result != .SUCCESS {panic("Failed to get Vulkan PhysicalDevice")}

	extension_names := vk_device_extensions(instance, system, physical_device, intern)
	defer delete(extension_names)

	// TODO: actually query queue families
	queue_index: u32 = 0
	queue_priority := f32(1)
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}
	dynamic_rendering := vk.PhysicalDeviceDynamicRenderingFeatures {
		sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		dynamicRendering = true,
	}
	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &dynamic_rendering,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,
		pEnabledFeatures        = &vk.PhysicalDeviceFeatures{},
		// enabledLayerCount       = len(VK_DEVICE_LAYERS),
		// ppEnabledLayerNames     = &VK_DEVICE_LAYERS[0],
		enabledExtensionCount   = u32(len(extension_names)),
		ppEnabledExtensionNames = &extension_names[0],
	}
	vkresult := vk.CreateDevice(physical_device, &device_create_info, nil, &device)
	if vkresult != .SUCCESS {
		panic("Failed to create device")
	}
	vk.load_proc_addresses_device(device)
	return
}

xr_init_session :: proc(
	instance: xr.Instance,
	system: xr.SystemId,
	vk_instance: vk.Instance,
	physical_device: vk.PhysicalDevice,
	device: vk.Device,
) -> (
	session: xr.Session,
) {
	graphics_binding := xr.GraphicsBindingVulkanKHR {
		sType            = .GRAPHICS_BINDING_VULKAN_KHR,
		instance         = vk_instance,
		physicalDevice   = physical_device,
		device           = device,
		queueFamilyIndex = 0,
		queueIndex       = 0,
	}
	session_info := xr.SessionCreateInfo {
		sType    = .SESSION_CREATE_INFO,
		next     = &graphics_binding,
		systemId = system,
	}
	err := xr.CreateSession(instance, &session_info, &session)
	if err != .SUCCESS {
		panic("failed to create session")
	}
	return
}

xr_init_space :: proc(session: xr.Session) -> (space: xr.Space) {
	session_info := xr.ReferenceSpaceCreateInfo {
		sType = .REFERENCE_SPACE_CREATE_INFO,
		referenceSpaceType = .STAGE,
		poseInReferenceSpace = {orientation = {x = 0, y = 0, z = 0, w = 1.0}, position = {x = 0, y = 0, z = 0}},
	}
	result := xr.CreateReferenceSpace(session, &session_info, &space)
	if result != .SUCCESS {panic("failed to create reference space")}
	return
}

xr_query_formats :: proc(session: xr.Session) -> (colour_format, depth_format: vk.Format) {
	colour_format = .UNDEFINED
	depth_format = .UNDEFINED

	format_count: u32
	result := xr.EnumerateSwapchainFormats(session, 0, &format_count, nil)
	if result != .SUCCESS {panic("failed to enumerate swapchain formats")}
	formats := make([]i64, format_count)
	result = xr.EnumerateSwapchainFormats(session, format_count, &format_count, &formats[0])
	if result != .SUCCESS {panic("failed to enumerate swapchain formats")}

	for format in formats {
		if vk.Format(format) != .B8G8R8A8_SRGB {continue}
		colour_format = .B8G8R8A8_SRGB
	}

	for format in formats {
		if vk.Format(format) != .D16_UNORM {continue}
		depth_format = .D16_UNORM
	}

	if colour_format == .UNDEFINED || depth_format == .UNDEFINED {
		panic("Could not find desired depth/colour format")
	}

	return
}

xr_create_swapchain :: proc(
	session: xr.Session,
	view_conf: xr.ViewConfigurationView,
	format: vk.Format,
	usage: xr.SwapchainUsageFlags,
) -> (
	swapchain: xr.Swapchain,
) {
	swapchain_info := xr.SwapchainCreateInfo {
		sType       = .SWAPCHAIN_CREATE_INFO,
		usageFlags  = usage,
		format      = i64(format),
		sampleCount = view_conf.recommendedSwapchainSampleCount,
		width       = view_conf.recommendedImageRectWidth,
		height      = view_conf.recommendedImageRectHeight,
		faceCount   = 1,
		arraySize   = 1,
		mipCount    = 1,
	}
	result := xr.CreateSwapchain(session, &swapchain_info, &swapchain)
	if result != .SUCCESS {panic("Swapchain creation failed")}

	return
}

xr_get_swapchain_images :: proc(swapchain: xr.Swapchain) -> (images: []xr.SwapchainImageVulkanKHR) {
	image_count: u32
	result := xr.EnumerateSwapchainImages(swapchain, 0, &image_count, nil)
	if result != .SUCCESS {panic("failed to enumerate swapchain images")}
	images = make([]xr.SwapchainImageVulkanKHR, image_count)
	for img in &images {
		img.sType = .SWAPCHAIN_IMAGE_VULKAN_KHR
	}

	result = xr.EnumerateSwapchainImages(swapchain, image_count, &image_count, cast(^xr.SwapchainImageBaseHeader)&images[0])
	if result != .SUCCESS {panic("failed to enumerate swapchain images")}

	return
}

xr_create_colour_swapchains :: proc(
	session: xr.Session,
	view_confs: []xr.ViewConfigurationView,
	colour_format: vk.Format,
) -> (
	colour_swapchains: []xr.Swapchain,
	colour_images: [][]xr.SwapchainImageVulkanKHR,
) {
	view_count := len(view_confs)
	colour_swapchains = make([]xr.Swapchain, view_count)
	colour_images = make([][]xr.SwapchainImageVulkanKHR, view_count)

	for i in 0 ..< view_count {
		colour_swapchains[i] = xr_create_swapchain(session, view_confs[i], colour_format, {.SAMPLED, .COLOR_ATTACHMENT})
		colour_images[i] = xr_get_swapchain_images(colour_swapchains[i])
	}

	return
}

xr_create_depth_swapchains :: proc(
	session: xr.Session,
	view_confs: []xr.ViewConfigurationView,
	depth_format: vk.Format,
) -> (
	depth_swapchains: []xr.Swapchain,
	depth_images: [][]xr.SwapchainImageVulkanKHR,
) {
	view_count := len(view_confs)
	depth_swapchains = make([]xr.Swapchain, view_count)
	depth_images = make([][]xr.SwapchainImageVulkanKHR, view_count)

	for i in 0 ..< view_count {
		depth_swapchains[i] = xr_create_swapchain(session, view_confs[i], depth_format, {.DEPTH_STENCIL_ATTACHMENT})
		depth_images[i] = xr_get_swapchain_images(depth_swapchains[i])
	}

	return
}

xr_create_image_views :: proc(
	device: vk.Device,
	images: []xr.SwapchainImageVulkanKHR,
	format: vk.Format,
	is_depth: bool,
) -> (
	image_views: []vk.ImageView,
) {
	image_views = make([]vk.ImageView, len(images))
	for img, i in images {
		subresource := vk.ImageSubresourceRange {
			aspectMask     = is_depth ? {.DEPTH} : {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		}
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = img.image,
			viewType = .D2,
			format = format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = subresource,
		}
		vk.CreateImageView(device, &view_info, nil, &image_views[i])
	}

	return
}

xr_create_view_image_views :: proc(
	device: vk.Device,
	images: [][]xr.SwapchainImageVulkanKHR,
	format: vk.Format,
	is_depth: bool,
) -> (
	image_views: [][]vk.ImageView,
) {
	image_views = make([][]vk.ImageView, len(images))
	for view_images, i in images {
		image_views[i] = xr_create_image_views(device, view_images, format, is_depth)
	}
	return
}

create_extents :: proc(view_confs: []xr.ViewConfigurationView) -> (extents: []vk.Extent2D) {
	extents = make([]vk.Extent2D, len(view_confs))
	for conf, i in view_confs {
		extents[i] = vk.Extent2D{conf.recommendedImageRectWidth, conf.recommendedImageRectHeight}
	}
	return
}

create_shader_module :: proc(device: vk.Device, src: []u8) -> (module: vk.ShaderModule) {
	module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(src),
		pCode    = cast(^u32)&src[0],
	}

	result := vk.CreateShaderModule(device, &module_info, nil, &module)
	if result != .SUCCESS {
		panic("Shader module creation failed")
	}
	return
}

create_graphics_pipeline :: proc(device: vk.Device) -> (pipeline: vk.Pipeline, pipeline_layout: vk.PipelineLayout) {

	vert_module := create_shader_module(device, vertex_main_src[:])
	frag_module := create_shader_module(device, pixel_main_src[:])

	vert_info := vk.PipelineShaderStageCreateInfo {
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {.VERTEX},
		module = vert_module,
		pName = "vertex_main",
	}

	frag_info := vk.PipelineShaderStageCreateInfo {
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {.FRAGMENT},
		module = frag_module,
		pName = "pixel_main",
	}

	shader_stages := [2]vk.PipelineShaderStageCreateInfo{vert_info, frag_info}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 0,
		vertexAttributeDescriptionCount = 0,
	}

	input_assembly_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	viewport_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer_info := vk.PipelineRasterizationStateCreateInfo {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = false,
		rasterizerDiscardEnable = false,
		polygonMode = .FILL,
		lineWidth = 1.0,
		cullMode = {.BACK},
		frontFace = .CLOCKWISE,
		depthBiasEnable = false,
	}

	multisample_info := vk.PipelineMultisampleStateCreateInfo {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable = false,
		rasterizationSamples = {._1},
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable = false,
	}

	color_blend_info := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false,
		logicOp = .COPY,
		attachmentCount = 1,
		pAttachments = &color_blend_attachment,
		blendConstants = {0.0, 0.0, 0.0, 0.0},
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 0,
		pushConstantRangeCount = 0,
	}

	result := vk.CreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout)
	if result != .SUCCESS {
		panic("Pipeline layout creation failed")
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly_info,
		pViewportState      = &viewport_info,
		pRasterizationState = &rasterizer_info,
		pMultisampleState   = &multisample_info,
		pColorBlendState    = &color_blend_info,
		pDynamicState       = &dynamic_state_info,
		layout              = pipeline_layout,
		subpass             = 0,
	}

	result = vk.CreateGraphicsPipelines(device, vk.PipelineCache(0), 1, &pipeline_info, nil, &pipeline)
	if result != .SUCCESS {
		panic("Graphics Pipeline creation failed")
	}

	vk.DestroyShaderModule(device, frag_module, nil)
	vk.DestroyShaderModule(device, vert_module, nil)
	return
}

create_command_pool :: proc(device: vk.Device, queue_index: u32) -> (command_pool: vk.CommandPool) {
	pool_info := vk.CommandPoolCreateInfo {
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = queue_index,
	}

	result := vk.CreateCommandPool(device, &pool_info, nil, &command_pool)
	if result != .SUCCESS {
		panic("Command Pool creation failed")
	}
	return
}

create_command_buffers :: proc(device: vk.Device, command_pool: vk.CommandPool) -> (command_buffers: [2]vk.CommandBuffer) {
	command_buffer_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = 2,
	}

	result := vk.AllocateCommandBuffers(device, &command_buffer_info, &command_buffers[0])
	if result != .SUCCESS {
		panic("Command Buffer allocation failed")
	}
	return
}

xr_subsystem_init :: proc() -> (subsytem: Xr_Subsystem) {
	intern: strings.Intern
	strings.intern_init(&intern)

	vk.load_proc_addresses_global(rawptr(vkGetInstanceProcAddr))
	openxr := xr_init_instance(&intern)
	debug_messenger := xr_create_debug_messenger(openxr)
	system, system_properties := xr_get_system_and_properties(openxr)
	view_confs := xr_get_view_configs(openxr, system)
	vulkan := xr_create_vulkan_instance(openxr, system, &intern)
	device, physical_device := xr_create_vulkan_device(openxr, system, vulkan, &intern)
	session := xr_init_session(openxr, system, vulkan, physical_device, device)
	space := xr_init_space(session)
	colour_format, depth_format := xr_query_formats(session)
	colour_swapchains, colour_images := xr_create_colour_swapchains(session, view_confs, colour_format)
	depth_swapchains, depth_images := xr_create_depth_swapchains(session, view_confs, depth_format)
	colour_image_views := xr_create_view_image_views(device, colour_images, colour_format, false)
	depth_image_views := xr_create_view_image_views(device, depth_images, depth_format, true)
	extents := create_extents(view_confs)

	pipeline, pipeline_layout := create_graphics_pipeline(device)
	command_pool := create_command_pool(device, 0)
	command_buffers := create_command_buffers(device, command_pool)
	// image_available_semaphores, render_finished_semaphores, in_flight_fences := app_create_sync_objects(device)

	// Render loop
	// for each view, for depth colour
	// acquire image, wait image (on xrSwapchain)
	// render into those images (or into the pre-created vk.ImageView)
	// release image

	subsytem = Xr_Subsystem {
		intern             = intern,
		openxr             = openxr,
		debug_messenger    = debug_messenger,
		system             = system,
		system_properties  = system_properties,
		view_confs         = view_confs,
		session            = session,
		space              = space,
		colour_swapchains  = colour_swapchains,
		depth_swapchains   = depth_swapchains,
		vulkan             = vulkan,
		device             = device,
		physical_device    = physical_device,
		colour_images      = colour_images,
		depth_images       = depth_images,
		colour_image_views = colour_image_views,
		depth_image_views  = depth_image_views,
		extents            = extents,
		pipeline_layout    = pipeline_layout,
		pipeline           = pipeline,
		command_pool       = command_pool,
		command_buffers    = command_buffers,
	}
	return
}

xr_subsystem_quit :: proc(subsytem: ^Xr_Subsystem) {
	fmt.println("quitting")
	using subsytem

	vk.DestroyCommandPool(device, command_pool, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout, nil)
	vk.DestroyPipeline(device, pipeline, nil)
	for view in colour_image_views {
		for img in view {
			vk.DestroyImageView(device, img, nil)
		}
	}
	for view in depth_image_views {
		for img in view {
			vk.DestroyImageView(device, img, nil)
		}
	}
	for view in colour_images {
		for img in view {
			vk.DestroyImage(device, img.image, nil)
		}
	}
	for view in depth_images {
		for img in view {
			vk.DestroyImage(device, img.image, nil)
		}
	}
	for chain in colour_swapchains {
		xr.DestroySwapchain(chain)
	}
	for chain in depth_swapchains {
		xr.DestroySwapchain(chain)
	}
	xr.DestroySpace(space)
	// OpenXR runtime is _very cool_ and doesn't clean up its Vulkan resources, so calling this spits out a bunch of errors
	// FIXME: When Valve gets back on why their driver isn't working, actually clean up properly
	// vk.DestroyDevice(device, nil)
	// vk.DestroyInstance(vulkan, nil)
	xr.DestroySession(session)
	xr.DestroyDebugUtilsMessengerEXT(debug_messenger)
	xr.DestroyInstance(openxr)
}

xr_pump_events :: proc(subsystem: ^Xr_Subsystem) {
	using subsystem


}

xr_frame :: proc(subsystem: ^Xr_Subsystem) {
	using subsystem

	result: xr.Result

	quit_mainloop: bool
	run_framecycle: bool
	session_running: bool
	session_state: xr.SessionState

	// Handle runtime Events
	// we do this before xrWaitFrame() so we can go idle or
	// break out of the main render loop as early as possible and don't have to
	// uselessly render or submit one. Calling xrWaitFrame commits you to
	// calling xrBeginFrame eventually.
	runtime_event := xr.EventDataBuffer {
		sType = .EVENT_DATA_BUFFER,
	}
	poll_result := xr.PollEvent(openxr, &runtime_event)
	for poll_result == .SUCCESS {
		#partial switch (runtime_event.sType) 
		{
		case .EVENT_DATA_INSTANCE_LOSS_PENDING:
			event := cast(^xr.EventDataInstanceLossPending)&runtime_event
			fmt.printf("EVENT: instance loss pending at %v! Destroying instance.\n", event.lossTime)
			quit_mainloop = true
			continue
		case .EVENT_DATA_SESSION_STATE_CHANGED:
			event := cast(^xr.EventDataSessionStateChanged)&runtime_event
			fmt.printf("EVENT: session state changed from %v to %v\n", session_state, event.state)
			session_state = event.state

			/*
				 * react to session state changes, see OpenXR spec 9.3 diagram. What we need to react to:
				 *
				 * * READY -> xrBeginSession STOPPING -> xrEndSession (note that the same session can be restarted)
				 * * EXITING -> xrDestroySession (EXITING only happens after we went through STOPPING and called
				 *
				 * After exiting it is still possible to create a new session but we don't do that here.
				 *
				 * * IDLE -> don't run render loop, but keep polling for events
				 * * SYNCHRONIZED, VISIBLE, FOCUSED -> run render loop
				 */
			switch (session_state) 
			{
			// skip render loop, keep polling
			case .IDLE, .UNKNOWN:
				run_framecycle = false

			// do nothing, run render loop normally
			case .FOCUSED, .SYNCHRONIZED, .VISIBLE:
				run_framecycle = true

			// begin session and then run render loop
			case .READY:
				// start session only if it is not running, i.e. not when we already called xrBeginSession
				// but the runtime did not switch to the next state yet
				if !session_running {
					result = xr.BeginSession(
						session,
						&xr.SessionBeginInfo{sType = .SESSION_BEGIN_INFO, primaryViewConfigurationType = .PRIMARY_STEREO},
					)

					if result != .SUCCESS {
						panic("Failed to begin session")
					}

					session_running = true
				}
				// after beginning the session, run render loop
				run_framecycle = true

			// end session, skip render loop, keep polling for next state change
			case .STOPPING:
				// end session only if it is running, i.e. not when we already called xrEndSession but the
				// runtime did not switch to the next state yet
				if session_running {
					result = xr.EndSession(session)
					if result != .SUCCESS {
						panic("Failed to end session")
					}
					session_running = false
				}
				// after ending the session, don't run render loop
				run_framecycle = false

			// destroy session, skip render loop, exit render loop and quit
			case .LOSS_PENDING, .EXITING:
				result = xr.DestroySession(session)
				if result != .SUCCESS {
					panic("Failed to destroy session")
				}
				quit_mainloop = true
				run_framecycle = false
			}

		case .EVENT_DATA_INTERACTION_PROFILE_CHANGED:
			fmt.println("EVENT: interaction profile changed!")

		// for i in 0 ..< 2 {
		// 	profile_state := xr.InteractionProfileState {
		// 		sType = .INTERACTION_PROFILE_STATE,
		// 	}
		// 	err := xr.GetCurrentInteractionProfile(session, xr_hand_paths[i], &profile_state)
		// 	if err != .Success {
		// 		panic("Failed to get interaction profile")
		// 	}

		// 	prof := profile_state.interactionProfile
		// 	strl: u32
		// 	profile_str: [xr.MAX_PATH_LENGTH]u8
		// 	err = xr.path_to_string(xr_instance, prof, xr.MAX_PATH_LENGTH, &strl, cstring(&profile_str[0]))
		// 	if err != .Success {
		// 		fmt.println(err)
		// 		fmt.println("Failed to get profile string")
		// 	} else {
		// 		fmt.printf("Event: Interaction profile changed for %d: %s\n", i, cstring(&profile_str[0]))
		// 	}

		// }
		case:
			fmt.printf("Unhandled event (type {})\n", runtime_event.sType)
		}

		runtime_event.sType = .EVENT_DATA_BUFFER
		poll_result = xr.PollEvent(openxr, &runtime_event)
	}

	if poll_result == .EVENT_UNAVAILABLE {
		// processed all events in the queue
	} else {
		fmt.println("Failed to poll events!")
		return
	}


	if !run_framecycle {
		return
	}

	// Wait for our turn to do head-pose dependent computation and render a frame
	frame_state := xr.FrameState {
		sType = .FRAME_STATE,
	}
	frame_wait_info := xr.FrameWaitInfo {
		sType = .FRAME_WAIT_INFO,
	}
	result = xr.WaitFrame(session, &frame_wait_info, &frame_state)
	if result != .SUCCESS {panic("Failed to wait frame")}

	//! @todo Move this action processing to before xrWaitFrame, probably.
	// active_actionsets := [1]xr.ActiveActionSet{{actionSet = xr_action_set, subactionPath = xr.NULL_PATH}}
	// actions_sync_info := xr.ActionsSyncInfo {
	// 	type                  = .TypeActionsSyncInfo,
	// 	countActiveActionSets = 1,
	// 	activeActionSets      = &active_actionsets[0],
	// }
	// err = xr.sync_actions(xr_session, &actions_sync_info)
	// if err != .Success {
	// 	// continue
	// 	// fmt.println("Failed to sync actions")
	// }

	// query each value / location with a subaction path != XR_NULL_PATH
	// resulting in individual values per hand/.
	// grab_value: [2]xr.ActionStateFloat
	// hand_locations: [2]xr.SpaceLocation

	// for i in 0 ..< 2 {
	// 	hand_pose_state := xr.ActionStatePose {
	// 		type = .TypeActionStatePose,
	// 	}
	// 	err = xr.get_action_state_pose(
	// 		xr_session,
	// 		&xr.ActionStateGetInfo{
	// 			type = .TypeActionStateGetInfo,
	// 			action = xr_hand_pose_action,
	// 			subactionPath = xr_hand_paths[i],
	// 		},
	// 		&hand_pose_state,
	// 	)
	// 	if err != .Success {
	// 		fmt.println("Failed to get pose")
	// 	}

	// 	hand_locations[i].type = .TypeSpaceLocation
	// 	hand_locations[i].next = nil

	// 	err = xr.locate_space(xr_hand_pose_spaces[i], xr_space, frame_state.predictedDisplayTime, &hand_locations[i])
	// 	if err != .Success {
	// 		fmt.println("Failed to locate space")
	// 	}

	// 	grab_value[i].type = .TypeActionStateFloat
	// 	grab_value[i].next = nil
	// 	xr.get_action_state_float(
	// 		xr_session,
	// 		&xr.ActionStateGetInfo{
	// 			type = .TypeActionStateGetInfo,
	// 			action = xr_grab_action_float,
	// 			subactionPath = xr_hand_paths[i],
	// 		},
	// 		&grab_value[i],
	// 	)
	// 	if err != .Success {
	// 		fmt.println("Failed to get grab action")
	// 	}

	// 	if grab_value[i].isActive == 1 && grab_value[i].currentState > 0.75 {
	// 		vibration := xr.HapticVibration {
	// 			type      = .TypeHapticVibration,
	// 			amplitude = 0.5,
	// 			duration  = xr.MIN_HAPTIC_DURATION,
	// 			frequency = xr.FREQUENCY_UNSPECIFIED,
	// 		}

	// 		haptic_action_info := xr.HapticActionInfo {
	// 			type          = .TypeHapticActionInfo,
	// 			action        = xr_haptic_action,
	// 			subactionPath = xr_hand_paths[i],
	// 		}

	// 		err = xr.apply_haptic_feedback(xr_session, &haptic_action_info, cast(^xr.HapticBaseHeader)&vibration)
	// 		if err != .Success {
	// 			fmt.println("Failed to apply haptics")
	// 		}
	// 	}
	// }


	// Begin frame
	result = xr.BeginFrame(session, &xr.FrameBeginInfo{sType = .FRAME_BEGIN_INFO})
	if result != .SUCCESS {panic("Failed to begin frame")}

	// Create view, projection matrices
	view_locate_info := xr.ViewLocateInfo {
		sType                 = .VIEW_LOCATE_INFO,
		viewConfigurationType = .PRIMARY_STEREO,
		displayTime           = frame_state.predictedDisplayTime,
		space                 = space,
	}

	view_state := xr.ViewState {
		sType = .VIEW_STATE,
	}
	view_count := u32(len(view_confs))

	views: [2]xr.View
	result = xr.LocateViews(session, &view_locate_info, &view_state, 0, &view_count, nil)
	result = xr.LocateViews(session, &view_locate_info, &view_state, view_count, &view_count, &views[0])
	if result != .SUCCESS {panic("Failed to locate views")}

	proj_views: [2]xr.CompositionLayerProjectionView
	for i in 0 ..< 2 {
		width := i32(view_confs[i].recommendedImageRectWidth)
		height := i32(view_confs[i].recommendedImageRectHeight)
		proj_views[i] = {
			sType = .COMPOSITION_LAYER_PROJECTION,
			subImage = {swapchain = colour_swapchains[i], imageRect = {extent = {width = width, height = height}}},
			pose = views[i].pose,
			fov = views[i].fov,
		}
	}

	for i in 0 ..< 2 {
		if !bool(frame_state.shouldRender) {
			fmt.println("should_render = false, skipping frame")
			continue
		}

		colour_index: u32
		acquire_info := xr.SwapchainImageAcquireInfo {
			sType = .SWAPCHAIN_IMAGE_ACQUIRE_INFO,
		}
		result = xr.AcquireSwapchainImage(colour_swapchains[i], &acquire_info, &colour_index)
		if result != .SUCCESS {panic("Failed to acquire swapchain image")}

		depth_index: u32
		depth_acquire_info := xr.SwapchainImageAcquireInfo {
			sType = .SWAPCHAIN_IMAGE_ACQUIRE_INFO,
		}
		result = xr.AcquireSwapchainImage(depth_swapchains[i], &depth_acquire_info, &depth_index)
		if result != .SUCCESS {panic("Failed to acquire swapchain image")}


		colour_wait_info := xr.SwapchainImageWaitInfo {
			sType   = .SWAPCHAIN_IMAGE_WAIT_INFO,
			timeout = 1000,
		}
		result = xr.WaitSwapchainImage(colour_swapchains[i], &colour_wait_info)
		if result != .SUCCESS {panic("Failed to wait for swapchain image")}

		depth_wait_info := xr.SwapchainImageWaitInfo {
			sType   = .SWAPCHAIN_IMAGE_WAIT_INFO,
			timeout = 1000,
		}
		result = xr.WaitSwapchainImage(depth_swapchains[i], &depth_wait_info)
		if result != .SUCCESS {panic("Failed to wait for swapchain image")}


		// TODO:
		// Grab our image view ([i][foo_index])
		// Record and queue command

		colour_release_info := xr.SwapchainImageReleaseInfo {
			sType = .SWAPCHAIN_IMAGE_RELEASE_INFO,
		}
		result = xr.ReleaseSwapchainImage(colour_swapchains[i], &colour_release_info)
		if result != .SUCCESS {panic("Failed to release swapchain image")}

		depth_release_info := xr.SwapchainImageReleaseInfo {
			sType = .SWAPCHAIN_IMAGE_RELEASE_INFO,
		}
		result = xr.ReleaseSwapchainImage(depth_swapchains[i], &depth_release_info)
		if result != .SUCCESS {panic("Failed to release swapchain image")}
	}

	projection_layer := xr.CompositionLayerProjection {
		sType = .COMPOSITION_LAYER_PROJECTION,
		layerFlags = {.BLEND_TEXTURE_SOURCE_ALPHA},
		space = space,
		viewCount = 2,
		views = &proj_views[0],
	}

	submitted_layer_count: u32 = 1
	submitted_layers := [1]^xr.CompositionLayerBaseHeader{cast(^xr.CompositionLayerBaseHeader)&projection_layer}
	if .ORIENTATION_VALID in view_state.viewStateFlags {
		fmt.println("submitting 0 layers because orientation is invalid")
		submitted_layer_count = 0
	}

	if !bool(frame_state.shouldRender) {
		fmt.println("submitting 0 layers because shouldRender = fals")
		submitted_layer_count = 0
	}

	frame_end_info := xr.FrameEndInfo {
		sType                = .FRAME_END_INFO,
		displayTime          = frame_state.predictedDisplayTime,
		layerCount           = submitted_layer_count,
		layers               = &submitted_layers[0],
		environmentBlendMode = .OPAQUE,
	}

	result = xr.EndFrame(session, &frame_end_info)
	if result != .SUCCESS {panic("Failed to end frame")}
}

// Utilities
@(private = "file")
xr_proj :: proc(fov: xr.Fovf, near: f32, far: f32) -> (proj: matrix[4, 4]f32) {
	left := math.tan(fov.angleLeft)
	right := math.tan(fov.angleRight)
	down := math.tan(fov.angleDown)
	up := math.tan(fov.angleUp)
	width := right - left
	height := (up - down)
	proj = matrix[4, 4]f32 {
		2 / width, 0, (right + left) / width, 0, 
		0, 2 / height, (up + down) / height, 0, 
		0, 0, -(far + near) / (far - near), -(far * (near + near)) / (far - near), 
		0, 0, -1, 0, 
	}
	return
}
