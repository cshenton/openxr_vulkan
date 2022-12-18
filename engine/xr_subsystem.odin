package engine

import "core:fmt"
import "core:math"
import "core:runtime"
import SDL "vendor:sdl2"
import vk "vendor:vulkan"
import xr "openxr"

// OpenXR Substem
Xr_Subsystem :: struct {
	instance:          xr.Instance,
	system:            xr.SystemId,
	system_properties: xr.SystemProperties,
}

@(private = "file")
xr_init_instance :: proc() -> (instance: xr.Instance) {
	extension_names := [?]cstring{xr.KHR_VULKAN_ENABLE2_EXTENSION_NAME}
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

xr_get_view_configs :: proc(
	instance: xr.Instance,
	system: xr.SystemId,
) -> (
	view_confs: [4]xr.ViewConfigurationView,
	view_count: u32,
) {
	conf_type := xr.ViewConfigurationType.PRIMARY_STEREO
	err := xr.EnumerateViewConfigurationViews(instance, system, conf_type, 0, &view_count, nil)
	if err != .SUCCESS {
		panic("failed to enumerate configuration views")
	}

	err = xr.EnumerateViewConfigurationViews(instance, system, conf_type, 4, &view_count, &view_confs[0])
	if err != .SUCCESS {
		panic("failed to enumerate configuration views")
	}

	return
}

xr_get_max_vulkan_version :: proc(instance: xr.Instance, system: xr.SystemId) {
	requirements: xr.GraphicsRequirementsVulkanKHR
	fmt.println("here")
	result := xr.GetVulkanGraphicsRequirements2KHR(instance, system, &requirements)
	fmt.println("here")
	if result != .SUCCESS {
		panic("Failed to get Vulkan requirements from OpenXR")
	}
	fmt.println(requirements)
}

xr_init_session :: proc(instance: xr.Instance, system: xr.SystemId) -> (session: xr.Session) {
	graphics_binding := xr.GraphicsBindingVulkanKHR {
		sType = .GRAPHICS_BINDING_VULKAN_KHR,
		// instance: vk.Instance,
		// physicalDevice: vk.PhysicalDevice,
		// device: vk.Device,
		// queueFamilyIndex: u32,
		// queueIndex: u32,
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

xr_subsystem_init :: proc() -> (subsytem: Xr_Subsystem) {
	// TODO: Setup Debug logger
	// TODO: Vulkan init before Session init

	xr.load_base_procs()
	instance := xr_init_instance()
	xr.load_instance_procs(instance)
	system, system_properties := xr_get_system_and_properties(instance)
	xr_get_max_vulkan_version(instance, system)
	view_confs, view_count := xr_get_view_configs(instance, system)

	session := xr_init_session(instance, system)

	subsytem = Xr_Subsystem {
		instance          = instance,
		system            = system,
		system_properties = system_properties,
	}
	return
}

xr_subsystem_quit :: proc(subsytem: ^Xr_Subsystem) {
	using subsytem
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
