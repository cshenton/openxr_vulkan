package engine

import "core:fmt"
import "core:math"
import "core:runtime"
import "core:strings"
import SDL "vendor:sdl2"
import vk "vendor:vulkan"
import xr "openxr"

// OpenXR Substem
Xr_Subsystem :: struct {
	instance:          xr.Instance,
	debug_messenger:   xr.DebugUtilsMessengerEXT,
	system:            xr.SystemId,
	system_properties: xr.SystemProperties,
	view_confs:        []xr.ViewConfigurationView,
	vk_instance:       vk.Instance,
	session:           xr.Session,
	space:             xr.Space,
	colour_swapchains: []xr.Swapchain,
	depth_swapchains:  []xr.Swapchain,
	colour_images:     [][]xr.SwapchainImageVulkanKHR,
	depth_images:      [][]xr.SwapchainImageVulkanKHR,
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

@(private = "file")
xr_init_instance :: proc() -> (instance: xr.Instance) {
	extension_names := [?]cstring{xr.EXT_DEBUG_UTILS_EXTENSION_NAME, xr.KHR_VULKAN_ENABLE_EXTENSION_NAME}
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
		enabledExtensionCount = len(extension_names),
		enabledExtensionNames = &extension_names[0],
	}
	err := xr.CreateInstance(&instance_info, &instance)
	if err != .SUCCESS {
		panic("failed to create XR instance")
	}
	return
}

xr_create_debug_messenger :: proc(instance: xr.Instance) -> (messenger: xr.DebugUtilsMessengerEXT) {
	debug_info := xr.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverities = {.ERROR, .WARNING, .INFO, .VERBOSE},
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
xr_create_vulkan_instance :: proc(instance: xr.Instance, system: xr.SystemId) -> (vk_instance: vk.Instance) {
	// TODO: Query graphics, instance requirements
	// TODO: Parse the concatenated extension list into something we can feed vulkan
	// TODO: Create our vulkan instance

	requirements: xr.GraphicsRequirementsVulkanKHR
	result := xr.GetVulkanGraphicsRequirementsKHR(instance, system, &requirements)
	if result != .SUCCESS {
		panic("Failed to get Vulkan requirements from OpenXR")
	}

	capacity: u32
	result = xr.GetVulkanInstanceExtensionsKHR(instance, system, 0, &capacity, nil)
	if result != .SUCCESS {panic("Failed to get required Vulkan Extensions")}
	instance_extensions_all := make([]u8, capacity)
	result = xr.GetVulkanInstanceExtensionsKHR(instance, system, capacity, &capacity, cstring(&instance_extensions_all[0]))
	if result != .SUCCESS {panic("Failed to get required Vulkan Extensions")}


	// Something like this to get our instance extensions
	instance_extensions := strings.split(string(instance_extensions_all[0:len(instance_extensions_all) - 2]), " ")
	instance_extensions_c := make([]cstring, len(instance_extensions))
	for str, i in instance_extensions {
		instance_extensions_c[i] = strings.clone_to_cstring(str)
	}

	// Something like this to check our vulkan version
	if xr.MAKE_VERSION(1, 2, 0) > requirements.maxApiVersionSupported {panic("Vulkan 1.2 not supported")}

	// Load in our base vulkan procs
	vk.load_proc_addresses_global(rawptr(vkGetInstanceProcAddr))

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
		enabledExtensionCount   = u32(len(instance_extensions_c)),
		ppEnabledExtensionNames = &instance_extensions_c[0],
		// enabledLayerCount       = u32(len(layer_names)),
		// ppEnabledLayerNames     = &layer_names[0],
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
) -> (
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
) {
	capacity: u32
	result := xr.GetVulkanDeviceExtensionsKHR(instance, system, 0, &capacity, nil)
	if result != .SUCCESS {panic("Failed to get required Vulkan Extensions")}
	device_extensions_all := make([]u8, capacity)
	result = xr.GetVulkanDeviceExtensionsKHR(instance, system, capacity, &capacity, cstring(&device_extensions_all[0]))
	if result != .SUCCESS {panic("Failed to get required Vulkan Extensions")}

	// Something like this to get our device extensions
	device_extensions := strings.split(string(device_extensions_all[0:len(device_extensions_all) - 2]), " ")
	device_extensions_c := make([]cstring, len(device_extensions))
	for str, i in device_extensions {
		device_extensions_c[i] = strings.clone_to_cstring(str)
	}

	// TODO: Make sure we request device props2
	result = xr.GetVulkanGraphicsDeviceKHR(instance, system, vk_instance, &physical_device)
	if result != .SUCCESS {panic("Failed to get Vulkan PhysicalDevice")}

	queue_index: u32 = 0
	validation_layers := [1]cstring{"VK_LAYER_KHRONOS_validation"}
	// TODO: Append swapchain extension?
	extensions := [1]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	queue_priority := f32(1)
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}
	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		// TODO: Something here is tripping up createdevice
		// ERROR_EXTENSION_NOT_PRESENT
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,
		pEnabledFeatures        = &vk.PhysicalDeviceFeatures{},
		enabledLayerCount       = len(validation_layers),
		ppEnabledLayerNames     = &validation_layers[0],
		enabledExtensionCount   = u32(len(device_extensions_c)) - 1, // FIXME: fudge to remove VK_EXT_debug_marker
		ppEnabledExtensionNames = &device_extensions_c[0],
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
) -> (
	image_views: []vk.ImageView,
) {
	image_views = make([]vk.ImageView, len(images))
	for img, i in images {
		subresource := vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
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
) -> (
	image_views: [][]vk.ImageView,
) {
	image_views = make([][]vk.ImageView, len(images))
	for view_images, i in images {
		image_views[i] = xr_create_image_views(device, view_images, format)
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

create_render_pass :: proc(device: vk.Device, format: vk.Format) -> (render_pass: vk.RenderPass) {
	color_attachment := vk.AttachmentDescription {
		format = format,
		samples = {._1},
		loadOp = .CLEAR,
		storeOp = .STORE,
		stencilLoadOp = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED,
		finalLayout = .PRESENT_SRC_KHR,
	}

	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}

	render_pass_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
	}

	result := vk.CreateRenderPass(device, &render_pass_info, nil, &render_pass)
	if result != .SUCCESS {
		panic("Render pass creation failed")
	}
	return
}

create_graphics_pipeline :: proc(
	device: vk.Device,
	render_pass: vk.RenderPass,
) -> (
	pipeline: vk.Pipeline,
	pipeline_layout: vk.PipelineLayout,
) {

	// vert_module := app_create_shader_module(device, vertex_main_src[:])
	// frag_module := app_create_shader_module(device, pixel_main_src[:])

	// vert_info := vk.PipelineShaderStageCreateInfo {
	// 	sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
	// 	stage = {.VERTEX},
	// 	module = vert_module,
	// 	pName = "vertex_main",
	// }

	// frag_info := vk.PipelineShaderStageCreateInfo {
	// 	sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
	// 	stage = {.FRAGMENT},
	// 	module = frag_module,
	// 	pName = "pixel_main",
	// }

	// shader_stages := [2]vk.PipelineShaderStageCreateInfo{vert_info, frag_info}

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
		stageCount          = 0,
		// pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly_info,
		pViewportState      = &viewport_info,
		pRasterizationState = &rasterizer_info,
		pMultisampleState   = &multisample_info,
		pColorBlendState    = &color_blend_info,
		pDynamicState       = &dynamic_state_info,
		layout              = pipeline_layout,
		renderPass          = render_pass,
		subpass             = 0,
	}

	result = vk.CreateGraphicsPipelines(device, vk.PipelineCache(0), 1, &pipeline_info, nil, &pipeline)
	if result != .SUCCESS {
		panic("Graphics Pipeline creation failed")
	}

	// vk.DestroyShaderModule(device, frag_module, nil)
	// vk.DestroyShaderModule(device, vert_module, nil)
	return
}

create_framebuffers :: proc(
	device: vk.Device,
	render_pass: vk.RenderPass,
	extent: vk.Extent2D,
	image_views: []vk.ImageView,
) -> (
	framebuffers: []vk.Framebuffer,
) {
	framebuffers = make([]vk.Framebuffer, len(image_views))
	for view, i in image_views {
		attachments := [1]vk.ImageView{view}
		framebuffer_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = render_pass,
			attachmentCount = 1,
			pAttachments    = &attachments[0],
			width           = extent.width,
			height          = extent.height,
			layers          = 1,
		}

		result := vk.CreateFramebuffer(device, &framebuffer_info, nil, &framebuffers[i])
		if result != .SUCCESS {
			panic("Framebuffer creation failed")
		}
	}
	return
}

xr_subsystem_init :: proc() -> (subsytem: Xr_Subsystem) {
	xr.load_base_procs()
	instance := xr_init_instance()
	xr.load_instance_procs(instance)
	debug_messenger := xr_create_debug_messenger(instance)
	system, system_properties := xr_get_system_and_properties(instance)
	view_confs := xr_get_view_configs(instance, system)
	vk_instance := xr_create_vulkan_instance(instance, system)
	device, physical_device := xr_create_vulkan_device(instance, system, vk_instance)
	session := xr_init_session(instance, system, vk_instance, physical_device, device)
	space := xr_init_space(session)
	colour_format, depth_format := xr_query_formats(session)
	colour_swapchains, colour_images := xr_create_colour_swapchains(session, view_confs, colour_format)
	depth_swapchains, depth_images := xr_create_depth_swapchains(session, view_confs, depth_format)
	colour_image_views := xr_create_view_image_views(device, colour_images, colour_format)
	depth_image_views := xr_create_view_image_views(device, depth_images, depth_format)
	extents := create_extents(view_confs)

	// Create image views
	// 

	render_pass := create_render_pass(device, colour_format)
	pipeline, pipeline_layout := create_graphics_pipeline(device, render_pass)

	// Ugh we need a framebuffer for each image in each swapchain for each viiiiiiiiiew
	// framebuffers := create_framebuffers(device, render_pass, extents[0], colour_image_views)


	// command_pool := app_create_command_pool(device, queue_index)
	// command_buffers := app_create_command_buffers(device, command_pool)
	// image_available_semaphores, render_finished_semaphores, in_flight_fences := app_create_sync_objects(device)

	// Render loop
	// for each view, for depth colour
	// acquire image, wait image (on xrSwapchain)
	// render into those images (or into the pre-created vk.ImageView)
	// release image

	subsytem = Xr_Subsystem {
		instance          = instance,
		debug_messenger   = debug_messenger,
		system            = system,
		system_properties = system_properties,
		view_confs        = view_confs,
		vk_instance       = vk_instance,
		session           = session,
		space             = space,
		colour_swapchains = colour_swapchains,
		depth_swapchains  = depth_swapchains,
		colour_images     = colour_images,
		depth_images      = depth_images,
	}
	return
}

xr_subsystem_quit :: proc(subsytem: ^Xr_Subsystem) {
	fmt.println("quitting")

	using subsytem
	for chain in colour_swapchains {
		xr.DestroySwapchain(chain)
	}
	for chain in depth_swapchains {
		xr.DestroySwapchain(chain)
	}
	xr.DestroySpace(space)
	xr.DestroySession(session)
	vk.DestroyInstance(vk_instance, nil)
	xr.DestroyDebugUtilsMessengerEXT(debug_messenger)
	xr.DestroyInstance(instance)
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
