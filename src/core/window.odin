package core

import sdl "vendor:sdl3"

WindowContext :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	width:    i32,
	height:   i32,
}

init_window :: proc(title: cstring, width: i32, height: i32) -> (^WindowContext, bool) {
	if !sdl.Init(sdl.INIT_VIDEO) {
		return nil, false
	}

	sdl.SetHint(sdl.HINT_RENDER_VSYNC, "1")
	sdl.SetHint(sdl.HINT_RENDER_GPU_LOW_POWER, "1")

	// Create window with resizable flag - required for maximization
	window := sdl.CreateWindow(title, width, height, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		sdl.Quit()
		return nil, false
	}

	renderer := sdl.CreateRenderer(window, nil)
	if renderer == nil {
		sdl.DestroyWindow(window)
		sdl.Quit()
		return nil, false
	}

	ctx := new(WindowContext)
	ctx.window = window
	ctx.renderer = renderer
	ctx.width = width
	ctx.height = height

	// Maximize the window (requires resizable flag)
	sdl.MaximizeWindow(window)

	// Sync window to ensure maximization has taken effect
	sdl.SyncWindow(window)

	// Get the actual window size after maximization (logical pixels)
	actual_width, actual_height: i32
	sdl.GetWindowSize(window, &actual_width, &actual_height)
	ctx.width = actual_width
	ctx.height = actual_height

	return ctx, true
}

destroy_window :: proc(ctx: ^WindowContext) {
	if ctx == nil do return

	if ctx.renderer != nil {
		sdl.DestroyRenderer(ctx.renderer)
	}
	if ctx.window != nil {
		sdl.DestroyWindow(ctx.window)
	}
	sdl.Quit()
	free(ctx)
}

get_window_size :: proc(ctx: ^WindowContext) -> (width: i32, height: i32) {
	if ctx == nil do return 0, 0
	return ctx.width, ctx.height
}

// Update window size from SDL (call this when window is resized)
update_window_size :: proc(ctx: ^WindowContext) {
	if ctx == nil || ctx.window == nil do return
	sdl.GetWindowSize(ctx.window, &ctx.width, &ctx.height)
}

// Get renderer output size (physical pixels, accounts for DPI scaling)
get_renderer_output_size :: proc(ctx: ^WindowContext) -> (width: i32, height: i32) {
	if ctx == nil || ctx.renderer == nil do return 0, 0
	output_width, output_height: i32
	sdl.GetRenderOutputSize(ctx.renderer, &output_width, &output_height)
	return output_width, output_height
}
