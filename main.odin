package openxr_vulkan

import "engine"

main :: proc() {
	using engine

	xr_subsystem := xr_subsystem_init()
	defer xr_subsystem_quit(&xr_subsystem)

	// eng := engine_init()
	// defer engine_quit(&eng)

	// for !eng.quit {
	// 	engine_run(&eng)
	// }
}
