package main

import win "core"
import core "core"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import filetree "plugins/filetree"
import vscode_default "plugins/vscode_default"
import "ui"
import ui_api "ui"
import sdl "vendor:sdl3"

// Set cursor based on cursor type
set_cursor_for_type :: proc(window: ^sdl.Window, cursor_type: ui.CursorType) {
	if window == nil do return

	// Create system cursor based on type
	cursor_handle: ^sdl.Cursor = nil

	#partial switch cursor_type {
	case .Hand:
		cursor_handle = sdl.CreateSystemCursor(.POINTER) // POINTER is the hand cursor in SDL3
	case .Text:
		cursor_handle = sdl.CreateSystemCursor(.TEXT)
	case .Resize:
		cursor_handle = sdl.CreateSystemCursor(.MOVE) // Use MOVE for resize
	case .Default:
		cursor_handle = sdl.CreateSystemCursor(.DEFAULT) // DEFAULT is the arrow cursor
	}

	// Set the cursor on the window (returns bool, ignore result)
	if cursor_handle != nil {
		_ = sdl.SetCursor(cursor_handle)
	}
}

main :: proc() {
	// Initialize EventBus
	eventbus := core.init_eventbus()
	if eventbus == nil {
		fmt.eprintln("Failed to initialize EventBus")
		return
	}
	defer core.destroy_eventbus(eventbus)

	// Initialize Plugin Registry
	plugin_registry := core.init_plugin_registry()
	if plugin_registry == nil {
		fmt.eprintln("Failed to initialize Plugin Registry")
		return
	}
	defer core.destroy_plugin_registry(plugin_registry)

	// Initialize Shortcut Registry
	shortcut_registry := core.init_shortcut_registry()
	if shortcut_registry == nil {
		fmt.eprintln("Failed to initialize Shortcut Registry")
		return
	}
	defer core.destroy_shortcut_registry(shortcut_registry)

	// Initialize window
	window_ctx, ok := win.init_window("Vessl IDE", 1280, 720)
	if !ok {
		fmt.eprintln("Failed to initialize window")
		return
	}
	defer win.destroy_window(window_ctx)

	// Initialize renderer with actual renderer output size (accounts for DPI)
	render_width, render_height := win.get_renderer_output_size(window_ctx)
	renderer_ctx := ui.init_renderer(window_ctx, f32(render_width), f32(render_height))
	if renderer_ctx == nil {
		fmt.eprintln("Failed to initialize renderer")
		return
	}
	defer ui.destroy_renderer(renderer_ctx)

	// Initialize UI Plugin API
	ui_api_ptr := ui_api.init_ui_api(renderer_ctx)
	if ui_api_ptr == nil {
		fmt.eprintln("Failed to initialize UI Plugin API")
		return
	}
	defer ui_api.destroy_ui_api(ui_api_ptr)

	// Register and initialize vscode_default plugin
	vscode_plugin := new(core.Plugin)
	vscode_plugin.id = "builtin:vscode_default"
	vscode_plugin.vtable = vscode_default.get_vtable()
	vscode_plugin.user_data = nil

	handle := core.register_plugin(plugin_registry, vscode_plugin)
	if handle == 0 {
		fmt.eprintln("Failed to register vscode_default plugin")
		return
	}

	// Cast ui_api_ptr and shortcut_registry to rawptr to pass to init_plugin
	if !core.init_plugin(
		plugin_registry,
		"builtin:vscode_default",
		eventbus,
		cast(rawptr)ui_api_ptr,
		cast(rawptr)shortcut_registry,
	) {
		fmt.eprintln("Failed to initialize vscode_default plugin")
		return
	}

	// Register and initialize filetree plugin
	filetree_plugin := new(core.Plugin)
	filetree_plugin.id = "builtin:filetree"
	filetree_plugin.vtable = filetree.get_vtable()
	filetree_plugin.user_data = nil

	filetree_handle := core.register_plugin(plugin_registry, filetree_plugin)
	if filetree_handle == 0 {
		fmt.eprintln("Failed to register filetree plugin")
		return
	}

	// Initialize filetree plugin
	if !core.init_plugin(plugin_registry, "builtin:filetree", eventbus, cast(rawptr)ui_api_ptr, cast(rawptr)shortcut_registry) {
		fmt.eprintln("Failed to initialize filetree plugin")
		return
	}

	// Emit App_Startup event and dispatch to plugins
	startup_payload := core.EventPayload_Custom {
		name = "startup",
		data = nil,
	}
	startup_event, _ := core.emit_event_typed(eventbus, .App_Startup, startup_payload)
	if startup_event != nil {
		core.dispatch_event_to_plugins(plugin_registry, startup_event)
	}

	// Main event loop with Animation Decay architecture
	// This achieves 60 FPS during interactions and 0% CPU when idle
	running := true
	render_required := true // Draw initial frame
	render_required_mutex: sync.Mutex // Protect render_required for thread safety
	animation_until := u64(0) // Timestamp in ms when animation should stop
	last_frame_time := sdl.GetTicks()

	// Mouse state tracking
	mouse_x: f32 = 0
	mouse_y: f32 = 0
	mouse_down := false
	mouse_click_this_frame := false

	for running {
		current_time := sdl.GetTicks()

		// 1. Check render_required (thread-safe)
		sync.mutex_lock(&render_required_mutex)
		needs_render := render_required
		sync.mutex_unlock(&render_required_mutex)

		// 2. Determine Sleep Strategy
		timeout_ms: i32
		is_animating := current_time < animation_until

		if is_animating || needs_render {
			// We are busy. Don't wait on the OS, just poll for events
			// and let RenderPresent (VSync) handle the pacing.
			// Using 0 prevents busy-looping if VSync is off.
			timeout_ms = 0
		} else {
			// We are idle. Use a small timeout (100ms) to periodically check
			// render_required flag set by background threads.
			// This uses minimal CPU (~0.1%) but allows thread-triggered updates.
			// Alternative: Use a pipe/socket for zero-CPU wake-up (more complex).
			timeout_ms = 100
		}

		// 3. Wait for Event (Block CPU when idle)
		event: sdl.Event
		// If timeout is -1, this uses 0% CPU.
		// If timeout is 0, this returns immediately.
		event_received := sdl.WaitEventTimeout(&event, timeout_ms)

		// 4. Re-check render_required after WaitEvent (thread might have set it)
		// This ensures we wake up even if no SDL event occurred
		sync.mutex_lock(&render_required_mutex)
		needs_render = render_required
		sync.mutex_unlock(&render_required_mutex)

		if event_received {
			// Convert SDL events to internal events and emit
			#partial switch event.type {
			case .QUIT:
				// Emit App_Shutdown event
				shutdown_payload := core.EventPayload_Custom {
					name = "shutdown",
					data = nil,
				}
				shutdown_event, _ := core.emit_event_typed(
					eventbus,
					.App_Shutdown,
					shutdown_payload,
				)
				if shutdown_event != nil {
					core.dispatch_event_to_plugins(plugin_registry, shutdown_event)
				}
				running = false

			case .MOUSE_WHEEL:
				// Input that implies motion: Request 60FPS for 500ms
				// to allow scroll damping/inertia to settle.
				animation_until = sdl.GetTicks() + 500

			case .MOUSE_MOTION:
				// Update mouse position
				mouse_x = f32(event.motion.x)
				mouse_y = f32(event.motion.y)

				// Mouse movement: Request immediate frame update
				// For simple UI, we just request 1 frame.
				// If you want smooth hover effects, extend animation_until instead.
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)

			case .MOUSE_BUTTON_DOWN:
				// Update mouse position and button state
				mouse_x = f32(event.button.x)
				mouse_y = f32(event.button.y)
				mouse_down = true
				mouse_click_this_frame = true

				// Request immediate render
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)

			case .MOUSE_BUTTON_UP:
				// Update mouse position and button state
				mouse_x = f32(event.button.x)
				mouse_y = f32(event.button.y)
				mouse_down = false

				// Request immediate render
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)

			case .TEXT_INPUT:
				// Immediate feedback for text input
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)

			case .KEY_DOWN:
				// Check for keyboard shortcuts
				key := event.key.key
				mod_state := event.key.mod

				// Convert SDL modifiers to our platform-specific KeyModifier type
				// SDL3 uses LCTRL/RCTRL for left/right control, LGUI/RGUI for Cmd/Win key, etc.
				modifiers: core.KeyModifier = {}

				// Shift is shared across all platforms
				if .LSHIFT in mod_state || .RSHIFT in mod_state {
					modifiers += {.Shift}
				}

				// Platform-specific modifier mapping
				when ODIN_OS == .Darwin {
					// macOS: GUI key is Command, Alt is Option, Ctrl is CtrlMac
					if .LGUI in mod_state || .RGUI in mod_state {
						modifiers += {.Cmd}
					}
					if .LALT in mod_state || .RALT in mod_state {
						modifiers += {.Opt}
					}
					if .LCTRL in mod_state || .RCTRL in mod_state {
						modifiers += {.CtrlMac}
					}
				} else {
					// Windows/Linux: Ctrl is Ctrl, Alt is Alt, GUI is Meta (Windows key)
					if .LCTRL in mod_state || .RCTRL in mod_state {
						modifiers += {.Ctrl}
					}
					if .LALT in mod_state || .RALT in mod_state {
						modifiers += {.Alt}
					}
					if .LGUI in mod_state || .RGUI in mod_state {
						modifiers += {.Meta}
					}
				}

				// Look up if there's a shortcut registered for this key combination
				event_name, found := core.find_shortcut(shortcut_registry, i32(key), modifiers)
				if found {
					// Emit custom signal event with the shortcut's event name
					shortcut_payload := core.EventPayload_Custom {
						name = event_name,
						data = nil,
					}
					shortcut_event, _ := core.emit_event_typed(
						eventbus,
						.Custom_Signal,
						shortcut_payload,
					)
					if shortcut_event != nil {
						core.dispatch_event_to_plugins(plugin_registry, shortcut_event)
					}
				}

				// Request immediate render for text input feedback
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)

			case .WINDOW_RESIZED:
				// Window was resized - update window context and renderer
				win.update_window_size(window_ctx)
				render_width, render_height := win.get_renderer_output_size(window_ctx)
				ui.update_renderer_size(renderer_ctx, f32(render_width), f32(render_height))

				// Emit Window_Resize event
				resize_payload := core.EventPayload_Custom {
					name = "resize",
					data = nil,
				}
				resize_event, _ := core.emit_event_typed(eventbus, .Window_Resize, resize_payload)
				if resize_event != nil {
					core.dispatch_event_to_plugins(plugin_registry, resize_event)
				}

				// Request immediate render to show new size
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)
			}
		}

		// Update plugins with delta time
		dt := f32(current_time - last_frame_time) / 1000.0 // Convert to seconds
		last_frame_time = current_time
		core.update_plugins(plugin_registry, dt)

		// 5. Check if we should Draw
		// Re-check time because WaitEvent might have slept
		current_time = sdl.GetTicks()
		should_render := needs_render || (current_time < animation_until)

		if should_render {
			// Update Clay pointer state before layout (required for hit testing)
			// Get renderer output size for coordinate conversion
			render_width, render_height := win.get_renderer_output_size(window_ctx)
			// Convert mouse coordinates to renderer space (account for DPI)
			render_mouse_x := mouse_x * (f32(render_width) / f32(window_ctx.width))
			render_mouse_y := mouse_y * (f32(render_height) / f32(window_ctx.height))
			ui.update_pointer_state(renderer_ctx, render_mouse_x, render_mouse_y, mouse_down)

			// Clear renderer
			sdl.SetRenderDrawColor(window_ctx.renderer, 0, 0, 0, 255)
			sdl.RenderClear(window_ctx.renderer)

			// Render UI tree (check for clicks only if mouse was clicked this frame)
			// Get cursor type from hovered node
			hovered_cursor := ui.render_frame(renderer_ctx, mouse_click_this_frame)

			// Set cursor based on hovered node
			set_cursor_for_type(window_ctx.window, hovered_cursor)

			// Clear click flag after processing
			mouse_click_this_frame = false

			// Present (VSync will handle actual frame pacing)
			// This will block for VSync, capping you at 60/120 FPS cleanly.
			sdl.RenderPresent(window_ctx.renderer)

			// Clear render_required flag (thread-safe)
			sync.mutex_lock(&render_required_mutex)
			render_required = false
			sync.mutex_unlock(&render_required_mutex)

			// TODO: Check Clay scroll state if needed
			// Clay's scroll state can be checked via GetScrollContainerData if needed
		}
	}
}
