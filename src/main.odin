package main

import api "api"
import win "core"
import core "core"
import "core:fmt"
import "core:os"
import "core:sync"
import buffer_manager "plugins/buffer_manager"
import filetree "plugins/filetree"
import image_viewer "plugins/image_viewer"
import text_editor "plugins/text_editor"
import vscode_default "plugins/vscode_default"
import "ui"
import sdl "vendor:sdl3"

// Convert SDL mouse button to API MouseButton
sdl_button_to_mouse_button :: proc(sdl_button: u8) -> api.MouseButton {
	switch sdl_button {
	case 1:
		return .Left
	case 2:
		return .Middle
	case 3:
		return .Right
	case 4:
		return .X1
	case 5:
		return .X2
	}
	return .Left // Default to left button
}

// Set cursor based on cursor type
set_cursor_for_type :: proc(window: ^sdl.Window, cursor_type: api.CursorType) {
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
	// If a path argument is provided, change to that directory
	if len(os.args) > 1 {
		os.set_current_directory(os.args[1])
	}

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
	ui_api_ptr := ui.init_ui_api(renderer_ctx)
	if ui_api_ptr == nil {
		fmt.eprintln("Failed to initialize UI Plugin API")
		return
	}
	defer ui.destroy_ui_api(ui_api_ptr)

	// Initialize Platform API (for native dialogs, etc.)
	platform_api_ptr := ui.init_platform_api(window_ctx.window)
	if platform_api_ptr == nil {
		fmt.eprintln("Failed to initialize Platform API")
		return
	}
	defer ui.destroy_platform_api(platform_api_ptr)

	// Initialize Component Registry (for high-level UI components)
	component_registry := ui.init_component_registry(ui_api_ptr)
	if component_registry == nil {
		fmt.eprintln("Failed to initialize Component Registry")
		return
	}
	defer ui.destroy_component_registry(component_registry)

	// Initialize VesslAPI - the main API interface for plugins
	vessl_api := init_vessl_api(
		eventbus,
		plugin_registry,
		shortcut_registry,
		ui_api_ptr,
		platform_api_ptr,
		component_registry,
		window_ctx,
	)
	if vessl_api == nil {
		fmt.eprintln("Failed to initialize VesslAPI")
		return
	}
	defer destroy_vessl_api()

	// Register and initialize vscode_default plugin
	vscode_plugin := new(core.Plugin)
	vscode_plugin.id = "builtin:vscode_default"
	vscode_plugin.vtable = vscode_default.get_vtable()
	vscode_plugin.priority = 0 // Default priority
	vscode_plugin.user_data = nil

	handle := core.register_plugin(plugin_registry, vscode_plugin)
	if handle == 0 {
		fmt.eprintln("Failed to register vscode_default plugin")
		return
	}

	// Initialize plugin with VesslAPI
	if !core.init_plugin(plugin_registry, "builtin:vscode_default", vessl_api) {
		fmt.eprintln("Failed to initialize vscode_default plugin")
		return
	}

	// Register and initialize filetree plugin
	filetree_plugin := new(core.Plugin)
	filetree_plugin.id = "builtin:filetree"
	filetree_plugin.vtable = filetree.get_vtable()
	filetree_plugin.priority = 10 // Higher priority to consume file events first
	filetree_plugin.user_data = nil

	filetree_handle := core.register_plugin(plugin_registry, filetree_plugin)
	if filetree_handle == 0 {
		fmt.eprintln("Failed to register filetree plugin")
		return
	}

	// Initialize filetree plugin with VesslAPI
	if !core.init_plugin(plugin_registry, "builtin:filetree", vessl_api) {
		fmt.eprintln("Failed to initialize filetree plugin")
		return
	}

	// Register and initialize buffer_manager plugin
	buffer_manager_plugin := new(core.Plugin)
	buffer_manager_plugin.id = "builtin:buffer_manager"
	buffer_manager_plugin.vtable = buffer_manager.get_vtable()
	buffer_manager_plugin.priority = 0 // Default priority
	buffer_manager_plugin.user_data = nil

	buffer_manager_handle := core.register_plugin(plugin_registry, buffer_manager_plugin)
	if buffer_manager_handle == 0 {
		fmt.eprintln("Failed to register buffer_manager plugin")
		return
	}

	if !core.init_plugin(plugin_registry, "builtin:buffer_manager", vessl_api) {
		fmt.eprintln("Failed to initialize buffer_manager plugin")
		return
	}

	// Register and initialize image_viewer plugin
	// Higher priority (10) so it handles image files before text_editor
	image_viewer_plugin := new(core.Plugin)
	image_viewer_plugin.id = "builtin:image_viewer"
	image_viewer_plugin.vtable = image_viewer.get_vtable()
	image_viewer_plugin.priority = 10 // High priority to handle images before text editor
	image_viewer_plugin.user_data = nil

	image_viewer_handle := core.register_plugin(plugin_registry, image_viewer_plugin)
	if image_viewer_handle == 0 {
		fmt.eprintln("Failed to register image_viewer plugin")
		return
	}

	if !core.init_plugin(plugin_registry, "builtin:image_viewer", vessl_api) {
		fmt.eprintln("Failed to initialize image_viewer plugin")
		return
	}

	// Register and initialize text_editor plugin
	// Default priority (0) so it acts as fallback for all other files
	text_editor_plugin := new(core.Plugin)
	text_editor_plugin.id = "builtin:text_editor"
	text_editor_plugin.vtable = text_editor.get_vtable()
	text_editor_plugin.priority = 0 // Default priority (catch-all fallback)
	text_editor_plugin.user_data = nil

	text_editor_handle := core.register_plugin(plugin_registry, text_editor_plugin)
	if text_editor_handle == 0 {
		fmt.eprintln("Failed to register text_editor plugin")
		return
	}

	if !core.init_plugin(plugin_registry, "builtin:text_editor", vessl_api) {
		fmt.eprintln("Failed to initialize text_editor plugin")
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
	prev_mouse_x: f32 = 0
	prev_mouse_y: f32 = 0
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
				// SDL3 provides precise scroll values for smooth scrolling
				// Accumulate scroll delta - will be consumed in render_frame
				ui.accumulate_scroll_delta(renderer_ctx, event.wheel.x, event.wheel.y)

				// Input that implies motion: Request 60FPS for 500ms
				// to allow scroll damping/inertia to settle.
				animation_until = sdl.GetTicks() + 500

				// Request immediate render for scroll feedback
				sync.mutex_lock(&render_required_mutex)
				render_required = true
				needs_render = true
				sync.mutex_unlock(&render_required_mutex)

			case .MOUSE_MOTION:
				// Update mouse position
				prev_mouse_x = mouse_x
				prev_mouse_y = mouse_y
				mouse_x = f32(event.motion.x)
				mouse_y = f32(event.motion.y)

				// Calculate delta in window coordinates
				delta_x := mouse_x - prev_mouse_x
				delta_y := mouse_y - prev_mouse_y

				// Scale coordinates to renderer space (for high DPI displays)
				render_width, render_height := win.get_renderer_output_size(window_ctx)
				scale_x := f32(render_width) / f32(window_ctx.width)
				scale_y := f32(render_height) / f32(window_ctx.height)

				// Emit Mouse_Move event with scaled coordinates
				mouse_move_payload := core.EventPayload_MouseMove {
					delta_x = delta_x * scale_x,
					delta_y = delta_y * scale_y,
					x       = mouse_x * scale_x,
					y       = mouse_y * scale_y,
				}
				mouse_move_event, _ := core.emit_event_typed(
					eventbus,
					.Mouse_Move,
					mouse_move_payload,
				)
				if mouse_move_event != nil {
					core.dispatch_event_to_plugins(plugin_registry, mouse_move_event)
				}

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

				// Scale coordinates to renderer space (for high DPI displays)
				render_width, render_height := win.get_renderer_output_size(window_ctx)
				scale_x := f32(render_width) / f32(window_ctx.width)
				scale_y := f32(render_height) / f32(window_ctx.height)
				render_mouse_x := mouse_x * scale_x
				render_mouse_y := mouse_y * scale_y

				// Find the element under the mouse (need to update pointer state first)
				ui.update_pointer_state(renderer_ctx, render_mouse_x, render_mouse_y, mouse_down)
				hovered_element := ui.find_hovered_element_id(renderer_ctx)

				// Emit Mouse_Down event with scaled coordinates
				mouse_down_payload := core.EventPayload_MouseDown {
					element_id = hovered_element,
					button     = sdl_button_to_mouse_button(event.button.button),
					x          = render_mouse_x,
					y          = render_mouse_y,
				}
				mouse_down_event, _ := core.emit_event_typed(
					eventbus,
					.Mouse_Down,
					mouse_down_payload,
				)
				if mouse_down_event != nil {
					core.dispatch_event_to_plugins(plugin_registry, mouse_down_event)
				}

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

				// Scale coordinates to renderer space (for high DPI displays)
				render_width, render_height := win.get_renderer_output_size(window_ctx)
				scale_x := f32(render_width) / f32(window_ctx.width)
				scale_y := f32(render_height) / f32(window_ctx.height)
				render_mouse_x := mouse_x * scale_x
				render_mouse_y := mouse_y * scale_y

				// Find the element under the mouse (need to update pointer state first)
				ui.update_pointer_state(renderer_ctx, render_mouse_x, render_mouse_y, mouse_down)
				hovered_element := ui.find_hovered_element_id(renderer_ctx)

				// Emit Mouse_Up event with scaled coordinates
				mouse_up_payload := core.EventPayload_MouseUp {
					element_id = hovered_element,
					button     = sdl_button_to_mouse_button(event.button.button),
					x          = render_mouse_x,
					y          = render_mouse_y,
				}
				mouse_up_event, _ := core.emit_event_typed(eventbus, .Mouse_Up, mouse_up_payload)
				if mouse_up_event != nil {
					core.dispatch_event_to_plugins(plugin_registry, mouse_up_event)
				}

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

				// Emit Window_Resize event with renderer dimensions (physical pixels)
				// This matches the UI coordinate system used by Clay and mouse events
				resize_payload := api.EventPayload_WindowResize {
					width  = render_width,
					height = render_height,
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

		// Check for pending folder selection from dialog callback
		if folder_path, has_pending := ui.check_pending_folder_selection(); has_pending {
			fmt.printf("[main] Folder selected via dialog: %s\n", folder_path)

			// Emit Working_Directory_Changed event
			wd_payload := core.EventPayload_WorkingDirectory {
				path = folder_path,
			}
			wd_event, _ := core.emit_event_typed(eventbus, .Working_Directory_Changed, wd_payload)
			if wd_event != nil {
				core.dispatch_event_to_plugins(plugin_registry, wd_event)
			}

			// Free the folder path string (it was cloned in the callback)
			delete(folder_path)

			// Request render to show updated UI
			sync.mutex_lock(&render_required_mutex)
			render_required = true
			needs_render = true
			sync.mutex_unlock(&render_required_mutex)
		}

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
			hovered_cursor := ui.render_frame(renderer_ctx, mouse_click_this_frame, dt)

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

		// Reset event arena at end of frame - events are short-lived and have been processed
		// This prevents the arena from filling up and causing event allocation failures
		core.reset_event_arena(eventbus)
	}
}
