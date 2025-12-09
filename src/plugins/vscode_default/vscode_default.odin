package vscode_default

import api "../../api"
import "core:fmt"
import "core:mem"

// Resize constants
SIDEBAR_MIN_WIDTH :: 150 // Minimum sidebar width in pixels
SIDEBAR_MAX_WIDTH_PERCENT :: 0.75 // Maximum sidebar width as percentage of window width (75%)
SIDEBAR_DEFAULT_WIDTH :: 400 // Default sidebar width in pixels
RESIZE_HANDLE_WIDTH :: 6 // Width of the resize handle in pixels
TERMINAL_DEFAULT_HEIGHT :: 250 // Default terminal panel height in pixels
TERMINAL_RESIZE_HANDLE_HEIGHT :: 6 // Height of the terminal resize handle

// Plugin state
VSCodeDefaultState :: struct {
	root_node:              ^api.UINode,
	containers:             map[string]^api.UINode, // Map container ID to node
	allocator:              mem.Allocator,
	// Sidebar resize state
	sidebar_node:           ^api.UINode, // Reference to sidebar for resizing
	resize_handle:          ^api.UINode, // The resize handle element
	sidebar_width:          f32, // Current sidebar width
	is_resizing:            bool, // Whether we're currently resizing sidebar
	// Terminal resize state
	terminal_container:     ^api.UINode, // Reference to terminal container for resizing
	terminal_resize_handle: ^api.UINode, // The terminal resize handle
	terminal_height:        f32, // Current terminal height
	is_resizing_terminal:   bool, // Whether we're currently resizing terminal
	// Window state (for dynamic max width calculation)
	window_width:           i32, // Current window width in logical pixels
	window_height:          i32, // Current window height in logical pixels
}

// Initialize the plugin
vscode_default_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[vscode_default] Initializing...")

	state := new(VSCodeDefaultState, ctx.allocator)
	state.allocator = ctx.allocator
	state.containers = {}

	// Get initial window size for dynamic max width calculation
	window_width, window_height := api.get_window_size(ctx)
	state.window_width = window_width
	state.window_height = window_height

	ctx.user_data = state

	// Create root container - vertical stack covering full window
	root := api.create_node(api.ElementID("vscode_root"), .Container, ctx.allocator)
	api.node_set_width(ctx, root, api.SIZE_FULL) // 100% - full window width
	api.node_set_height(ctx, root, api.SIZE_FULL) // 100% - full window height
	api.node_set_color(ctx, root, {0.1, 0.1, 0.1, 1.0}) // Dark background
	api.node_set_layout_dir(ctx, root, .TopDown) // Vertical stack
	state.root_node = root

	// Top bar - full width, fixed height
	top_bar := api.create_node(api.ElementID("top_bar"), .Container, ctx.allocator)
	api.node_set_width(ctx, top_bar, api.SIZE_FULL) // Full window width
	api.node_set_height(ctx, top_bar, api.sizing_px(30)) // Fixed 30px height
	api.node_set_color(ctx, top_bar, {0.15, 0.15, 0.15, 1.0}) // Dark gray
	api.node_set_layout_dir(ctx, top_bar, .LeftRight)
	api.add_child(ctx, root, top_bar)

	// Horizontal stack - full width, grows height
	horizontal_stack := api.create_node(
		api.ElementID("horizontal_stack"),
		.Container,
		ctx.allocator,
	)
	api.node_set_width(ctx, horizontal_stack, api.SIZE_FULL) // Full window width
	api.node_set_height(ctx, horizontal_stack, api.sizing_grow()) // Grows to fill remaining space
	api.node_set_color(ctx, horizontal_stack, {0.1, 0.1, 0.1, 1.0}) // Dark background
	api.node_set_layout_dir(ctx, horizontal_stack, .LeftRight) // Horizontal layout
	api.add_child(ctx, root, horizontal_stack)

	// Sidebar container (holds sidebar content + resize handle)
	sidebar_container := api.create_node(
		api.ElementID("sidebar_container"),
		.Container,
		ctx.allocator,
	)
	api.node_set_width(ctx, sidebar_container, api.sizing_px(SIDEBAR_DEFAULT_WIDTH))
	api.node_set_height(ctx, sidebar_container, api.sizing_grow())
	api.node_set_color(ctx, sidebar_container, {0.2, 0.2, 0.2, 1.0})
	api.node_set_layout_dir(ctx, sidebar_container, .LeftRight) // Horizontal: content + resize handle
	api.add_child(ctx, horizontal_stack, sidebar_container)
	state.sidebar_node = sidebar_container
	state.sidebar_width = SIDEBAR_DEFAULT_WIDTH

	// Sidebar content area - grows to fill, leaves room for resize handle
	sidebar_left := api.create_node(api.ElementID("sidebar_left"), .Container, ctx.allocator)
	api.node_set_width(ctx, sidebar_left, api.sizing_grow()) // Grows to fill (minus resize handle)
	api.node_set_height(ctx, sidebar_left, api.sizing_grow()) // Grows to fill height
	api.node_set_color(ctx, sidebar_left, {0.2, 0.2, 0.2, 1.0}) // Dark gray
	api.node_set_layout_dir(ctx, sidebar_left, .TopDown)
	api.add_child(ctx, sidebar_container, sidebar_left)
	state.containers["sidebar_left"] = sidebar_left

	// Resize handle - thin vertical bar at right edge of sidebar
	resize_handle := api.create_node(
		api.ElementID("sidebar_resize_handle"),
		.Container,
		ctx.allocator,
	)
	api.node_set_width(ctx, resize_handle, api.sizing_px(RESIZE_HANDLE_WIDTH))
	api.node_set_height(ctx, resize_handle, api.sizing_grow())
	api.node_set_color(ctx, resize_handle, {0.15, 0.15, 0.15, 1.0}) // Slightly darker than sidebar
	api.node_set_cursor(ctx, resize_handle, .Resize) // Show resize cursor on hover
	api.add_child(ctx, sidebar_container, resize_handle)
	state.resize_handle = resize_handle

	// Editor + Terminal vertical stack - grows to fill right side
	editor_terminal_stack := api.create_node(
		api.ElementID("editor_terminal_stack"),
		.Container,
		ctx.allocator,
	)
	api.node_set_width(ctx, editor_terminal_stack, api.sizing_grow()) // Grows to fill remaining width
	api.node_set_height(ctx, editor_terminal_stack, api.sizing_grow()) // Grows to fill height
	api.node_set_color(ctx, editor_terminal_stack, {0.1, 0.1, 0.1, 1.0})
	api.node_set_layout_dir(ctx, editor_terminal_stack, .TopDown) // Vertical: editor on top, terminal below
	api.add_child(ctx, horizontal_stack, editor_terminal_stack)

	// Editor area container - grows to fill available space above terminal
	editor_main := api.create_node(api.ElementID("editor_main"), .Container, ctx.allocator)
	api.node_set_width(ctx, editor_main, api.SIZE_FULL) // Full width of stack
	api.node_set_height(ctx, editor_main, api.sizing_grow()) // Grows to fill remaining height
	api.node_set_color(ctx, editor_main, {0.12, 0.12, 0.12, 1.0}) // Slightly lighter dark
	api.node_set_layout_dir(ctx, editor_main, .TopDown)
	api.add_child(ctx, editor_terminal_stack, editor_main)
	state.containers["editor_main"] = editor_main

	// Terminal resize handle - horizontal bar above terminal
	terminal_resize_handle := api.create_node(
		api.ElementID("terminal_resize_handle"),
		.Container,
		ctx.allocator,
	)
	api.node_set_width(ctx, terminal_resize_handle, api.SIZE_FULL)
	api.node_set_height(ctx, terminal_resize_handle, api.sizing_px(TERMINAL_RESIZE_HANDLE_HEIGHT))
	api.node_set_color(ctx, terminal_resize_handle, {0.15, 0.15, 0.15, 1.0})
	api.node_set_cursor(ctx, terminal_resize_handle, .Resize)
	api.add_child(ctx, editor_terminal_stack, terminal_resize_handle)
	state.terminal_resize_handle = terminal_resize_handle

	// Terminal container - fixed height at bottom
	terminal_container := api.create_node(
		api.ElementID("terminal_container"),
		.Container,
		ctx.allocator,
	)
	api.node_set_width(ctx, terminal_container, api.SIZE_FULL)
	api.node_set_height(ctx, terminal_container, api.sizing_px(TERMINAL_DEFAULT_HEIGHT))
	api.node_set_color(ctx, terminal_container, {0.1, 0.1, 0.1, 1.0})
	api.node_set_layout_dir(ctx, terminal_container, .TopDown)
	api.add_child(ctx, editor_terminal_stack, terminal_container)
	state.terminal_container = terminal_container
	state.terminal_height = TERMINAL_DEFAULT_HEIGHT

	// Terminal content area - actual terminal display
	terminal_bottom := api.create_node(api.ElementID("terminal_bottom"), .Container, ctx.allocator)
	api.node_set_width(ctx, terminal_bottom, api.SIZE_FULL)
	api.node_set_height(ctx, terminal_bottom, api.sizing_grow())
	api.node_set_color(ctx, terminal_bottom, {0.08, 0.08, 0.08, 1.0}) // Darker background for terminal
	api.node_set_layout_dir(ctx, terminal_bottom, .TopDown)
	api.add_child(ctx, terminal_container, terminal_bottom)
	state.containers["terminal_bottom"] = terminal_bottom

	// Bottom bar - full width, fixed height
	status_bar := api.create_node(api.ElementID("status_bar"), .Container, ctx.allocator)
	api.node_set_width(ctx, status_bar, api.SIZE_FULL) // Full window width
	api.node_set_height(ctx, status_bar, api.sizing_px(30)) // Fixed 30px height
	api.node_set_color(ctx, status_bar, {0.15, 0.15, 0.15, 1.0}) // Dark gray
	api.node_set_layout_dir(ctx, status_bar, .LeftRight)
	api.add_child(ctx, root, status_bar)
	state.containers["status_bar"] = status_bar

	// Set root node via API - MUST be done before creating high-level components
	// so they can find containers in the UI tree
	api.set_root_node(ctx, root)

	// Note: Tab container is now created by the buffer_manager plugin
	// when it receives the Layout_Container_Ready event

	// Register keyboard shortcuts via API
	// On macOS, users expect Cmd+O, on Windows/Linux users expect Ctrl+O
	KEY_O :: 'o' // SDL keycode for 'O' key

	// Register Ctrl+O for Windows/Linux
	api.register_shortcut(ctx, KEY_O, {.Ctrl}, "select_working_directory")

	// Register Cmd+O for macOS
	api.register_shortcut(ctx, KEY_O, {.Cmd}, "select_working_directory")

	fmt.println("[vscode_default] Layout created successfully")
	return true
}

// Update the plugin
vscode_default_update :: proc(ctx: ^api.PluginContext, dt: f32) {
	// No-op for now
}

// Shutdown the plugin
vscode_default_shutdown :: proc(ctx: ^api.PluginContext) {
	fmt.println("[vscode_default] Shutting down...")

	state := cast(^VSCodeDefaultState)ctx.user_data
	if state == nil do return

	// Cleanup containers map
	delete(state.containers)

	// Note: UI nodes will be cleaned up by the renderer
	// We don't need to manually free them here

	free(state)
}

// Handle events
vscode_default_on_event :: proc(ctx: ^api.PluginContext, event: ^api.Event) -> bool {
	if event == nil do return false

	state := cast(^VSCodeDefaultState)ctx.user_data
	if state == nil do return false

	#partial switch event.type {
	case .Mouse_Down:
		// Check if mouse down is on a resize handle
		#partial switch payload in event.payload {
		case api.EventPayload_MouseDown:
			if payload.button == .Left {
				if payload.element_id == api.ElementID("sidebar_resize_handle") {
					state.is_resizing = true
					return true // Consume the event
				}
				if payload.element_id == api.ElementID("terminal_resize_handle") {
					state.is_resizing_terminal = true
					return true // Consume the event
				}
			}
		}
		return false

	case .Mouse_Up:
		// Stop resizing on mouse up
		#partial switch payload in event.payload {
		case api.EventPayload_MouseUp:
			if payload.button == .Left {
				if state.is_resizing {
					state.is_resizing = false
					return true // Consume the event
				}
				if state.is_resizing_terminal {
					state.is_resizing_terminal = false
					return true // Consume the event
				}
			}
		}
		return false

	case .Mouse_Move:
		// Handle resize dragging
		#partial switch payload in event.payload {
		case api.EventPayload_MouseMove:
			// Sidebar resize
			if state.is_resizing {
				// Update sidebar width based on mouse delta
				new_width := state.sidebar_width + payload.delta_x

				// Calculate dynamic max width (75% of window width)
				max_width := f32(state.window_width) * SIDEBAR_MAX_WIDTH_PERCENT

				// Clamp to min/max values
				if new_width < SIDEBAR_MIN_WIDTH {
					new_width = SIDEBAR_MIN_WIDTH
				} else if new_width > max_width {
					new_width = max_width
				}

				// Update state and UI
				state.sidebar_width = new_width
				if state.sidebar_node != nil {
					api.node_set_width(ctx, state.sidebar_node, api.sizing_px(int(new_width)))
				}

				return true // Consume the event
			}

			// Terminal resize (dragging up increases height, dragging down decreases)
			if state.is_resizing_terminal {
				// Dragging up (negative delta_y) increases terminal height
				new_height := state.terminal_height - payload.delta_y

				// Clamp to min/max values
				TERMINAL_MIN_HEIGHT :: 100
				TERMINAL_MAX_HEIGHT_PERCENT :: 0.75
				max_height := f32(state.window_height) * TERMINAL_MAX_HEIGHT_PERCENT

				if new_height < TERMINAL_MIN_HEIGHT {
					new_height = TERMINAL_MIN_HEIGHT
				} else if new_height > max_height {
					new_height = max_height
				}

				// Update state and UI
				state.terminal_height = new_height
				if state.terminal_container != nil {
					api.node_set_height(
						ctx,
						state.terminal_container,
						api.sizing_px(int(new_height)),
					)
				}

				return true // Consume the event
			}
		}
		return false

	case .Custom_Signal:
		// Handle keyboard shortcut events
		#partial switch payload in event.payload {
		case api.EventPayload_Custom:
			if payload.name == "select_working_directory" {
				fmt.println(
					"[vscode_default] Keyboard shortcut triggered: select_working_directory",
				)

				// Open native folder selection dialog using Platform API
				api.show_folder_dialog(ctx, "")

				return true // Consume the event
			}
		}
		return false

	case .App_Startup:
		fmt.println(
			"[vscode_default] Received App_Startup event, emitting Layout_Container_Ready events",
		)

		// Emit Layout_Container_Ready events for each container and dispatch to plugins

		// Sidebar for filetree
		layout_payload_sidebar := api.EventPayload_Layout {
			container_id  = "sidebar_left",
			target_plugin = "builtin:filetree",
		}
		sidebar_event, _ := api.emit_event(ctx, .Layout_Container_Ready, layout_payload_sidebar)
		if sidebar_event != nil {
			api.dispatch_event(ctx, sidebar_event)
		}

		// Editor main for buffer manager
		layout_payload_editor := api.EventPayload_Layout {
			container_id  = "editor_main",
			target_plugin = "builtin:buffer_manager",
		}
		editor_event, _ := api.emit_event(ctx, .Layout_Container_Ready, layout_payload_editor)
		if editor_event != nil {
			api.dispatch_event(ctx, editor_event)
		}

		// Terminal bottom for terminal plugin
		layout_payload_terminal := api.EventPayload_Layout {
			container_id  = "terminal_bottom",
			target_plugin = "builtin:terminal",
		}
		terminal_event, _ := api.emit_event(ctx, .Layout_Container_Ready, layout_payload_terminal)
		if terminal_event != nil {
			api.dispatch_event(ctx, terminal_event)
		}

		// Status bar for status plugin (future)
		layout_payload_status := api.EventPayload_Layout {
			container_id  = "status_bar",
			target_plugin = "builtin:status",
		}
		status_event, _ := api.emit_event(ctx, .Layout_Container_Ready, layout_payload_status)
		if status_event != nil {
			api.dispatch_event(ctx, status_event)
		}

		return false // Don't consume the event, let others see it

	case .Window_Resize:
		// Update window dimensions and clamp panels if needed
		#partial switch payload in event.payload {
		case api.EventPayload_WindowResize:
			state.window_width = payload.width
			state.window_height = payload.height

			// Calculate new max width (75% of window width)
			max_width := f32(payload.width) * SIDEBAR_MAX_WIDTH_PERCENT

			// If sidebar is wider than new max, clamp it
			if state.sidebar_width > max_width {
				state.sidebar_width = max_width
				if state.sidebar_node != nil {
					api.node_set_width(ctx, state.sidebar_node, api.sizing_px(int(max_width)))
				}
			}

			// Calculate new max height for terminal (75% of window height)
			TERMINAL_MAX_HEIGHT_PERCENT :: 0.75
			max_height := f32(payload.height) * TERMINAL_MAX_HEIGHT_PERCENT

			// If terminal is taller than new max, clamp it
			if state.terminal_height > max_height {
				state.terminal_height = max_height
				if state.terminal_container != nil {
					api.node_set_height(
						ctx,
						state.terminal_container,
						api.sizing_px(int(max_height)),
					)
				}
			}
		}
		return false // Don't consume, let others handle it too
	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> api.PluginVTable {
	return api.PluginVTable {
		init = vscode_default_init,
		update = vscode_default_update,
		shutdown = vscode_default_shutdown,
		on_event = vscode_default_on_event,
	}
}
