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
		apiVersion         = xr_version(1, 0, 25),
		applicationName    = xr_string(APPLICATION_NAME, 128),
		applicationVersion = 1,
		engineName         = xr_string(ENGINE_NAME, 128),
		engineVersion      = 1,
	}
	instance_info := xr.InstanceCreateInfo {
		sType                  = .INSTANCE_CREATE_INFO,
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
	// Get OpenXR System
	xr_system: xr.SystemId
	{
		system_info := xr.SystemGetInfo {
			sType       = .SYSTEM_GET_INFO,
			formFactor = .HEAD_MOUNTED_DISPLAY,
		}
		err := xr.GetSystem(instance, &system_info, &xr_system)
		if err != .SUCCESS {panic("failed to get system")}
	}

	xr_system_props: xr.SystemProperties
	{
		err := xr.GetSystemProperties(instance, xr_system, &xr_system_props)
		if err != .SUCCESS {panic("failed to get system properties")}

		using xr_system_props
		fmt.printf("System properties for system %v: \"%s\", vendor ID %v\n", systemId, systemName, vendorId)
		fmt.printf("\tMax layers          : %d\n", graphicsProperties.maxLayerCount)
		fmt.printf("\tMax swapchain height: %d\n", graphicsProperties.maxSwapchainImageHeight)
		fmt.printf("\tMax swapchain width : %d\n", graphicsProperties.maxSwapchainImageWidth)
		fmt.printf("\tOrientation Tracking: %d\n", trackingProperties.orientationTracking)
		fmt.printf("\tPosition Tracking   : %d\n", trackingProperties.positionTracking)
	}
	return
}

xr_get_max_vulkan_version :: proc(instance: xr.Instance, system: xr.SystemId) {
        requirements: xr.GraphicsRequirementsVulkanKHR
	xr.GetVulkanGraphicsRequirementsKHR(instance, system, &requirements)
        // requirements: xr.GraphicsRequirementsVulkan2KHR
        // result := xr.get_vulkan_graphics_requirements2_khr(instance, system, &requirements)
        // if result != .Success {
        //         panic("Failed to get Vulkan requirements from OpenXR")
        // }
        fmt.println(requirements)
}

xr_subsystem_init :: proc() -> (subsytem: Xr_Subsystem) {
	xr.load_base_procs()
	instance := xr_init_instance()
	xr.load_instance_procs(instance)
	system, system_properties := xr_get_system_and_properties(instance)
        xr_get_max_vulkan_version(instance, system)

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
xr_version :: proc(major, minor, patch: u64) -> u64 {
	return (((major) & 0xffff) << 48) | (((minor) & 0xffff) << 32) | ((patch) & 0xffffffff)
}

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

@(private = "file")
xr_string :: proc(str: string, $n: int) -> [n]u8 {
	result: [n]u8
	copy(result[:], str)
	return result
}
