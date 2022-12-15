package openxr_vulkan

import "engine"

main :: proc() {
        using engine
	engine := engine_init()
	defer engine_quit(&engine)

	for !engine.quit {
		engine_run(&engine)
	}
}