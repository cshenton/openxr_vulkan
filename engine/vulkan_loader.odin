package engine

import vk "vendor:vulkan"

// Link just the proc address loader
foreign import vulkan_loader "vulkan-1.lib"
foreign vulkan_loader {
	@(link_name = "vkGetInstanceProcAddr")
	vkGetInstanceProcAddr :: proc "system" (instance: vk.Instance, name: cstring) -> vk.ProcVoidFunction ---
}

