package vscode_default

import api "../../api"
import "core:fmt"
import "core:mem"

// Resize constants
SIDEBAR_MIN_WIDTH :: 150 // Minimum sidebar width in pixels
SIDEBAR_MAX_WIDTH_PERCENT :: 0.75 // Maximum sidebar width as percentage of window width (75%)
SIDEBAR_DEFAULT_WIDTH :: 400 // Default sidebar width in pixels
RESIZE_HANDLE_WIDTH :: 6 // Width of the resize handle in pixels

// Plugin state
VSCodeDefaultState :: struct {
	root_node:     ^api.UINode,
	containers:    map[string]^api.UINode, // Map container ID to node
	allocator:     mem.Allocator,
	// Resize state
	sidebar_node:  ^api.UINode, // Reference to sidebar for resizing
	resize_handle: ^api.UINode, // The resize handle element
	sidebar_width: f32, // Current sidebar width
	is_resizing:   bool, // Whether we're currently resizing
	// Window state (for dynamic max width calculation)
	window_width:  i32, // Current window width in logical pixels
}

// Initialize the plugin
vscode_default_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[vscode_default] Initializing...")

	state := new(VSCodeDefaultState, ctx.allocator)
	state.allocator = ctx.allocator
	state.containers = {}

	// Get initial window size for dynamic max width calculation
	window_width, _ := api.get_window_size(ctx)
	state.window_width = window_width

	ctx.user_data = state

	// Create root container - vertical stack covering full window
	root := api.create_node(api.ElementID("vscode_root"), .Container, ctx.allocator)
	root.style.width = api.SIZE_FULL // 100% - full window width
	root.style.height = api.SIZE_FULL // 100% - full window height
	root.style.color = {0.1, 0.1, 0.1, 1.0} // Dark background
	root.style.layout_dir = .TopDown // Vertical stack
	state.root_node = root

	// Top bar - full width, fixed height
	top_bar := api.create_node(api.ElementID("top_bar"), .Container, ctx.allocator)
	top_bar.style.width = api.SIZE_FULL // Full window width
	top_bar.style.height = api.sizing_px(30) // Fixed 30px height
	top_bar.style.color = {0.15, 0.15, 0.15, 1.0} // Dark gray
	top_bar.style.layout_dir = .LeftRight
	api.add_child(root, top_bar)

	// Horizontal stack - full width, grows height
	horizontal_stack := api.create_node(
		api.ElementID("horizontal_stack"),
		.Container,
		ctx.allocator,
	)
	horizontal_stack.style.width = api.SIZE_FULL // Full window width
	horizontal_stack.style.height = api.sizing_grow() // Grows to fill remaining space
	horizontal_stack.style.color = {0.1, 0.1, 0.1, 1.0} // Dark background
	horizontal_stack.style.layout_dir = .LeftRight // Horizontal layout
	api.add_child(root, horizontal_stack)

	// Sidebar container (holds sidebar content + resize handle)
	sidebar_container := api.create_node(
		api.ElementID("sidebar_container"),
		.Container,
		ctx.allocator,
	)
	sidebar_container.style.width = api.sizing_px(SIDEBAR_DEFAULT_WIDTH)
	sidebar_container.style.height = api.sizing_grow()
	sidebar_container.style.color = {0.2, 0.2, 0.2, 1.0}
	sidebar_container.style.layout_dir = .LeftRight // Horizontal: content + resize handle
	api.add_child(horizontal_stack, sidebar_container)
	state.sidebar_node = sidebar_container
	state.sidebar_width = SIDEBAR_DEFAULT_WIDTH

	// Sidebar content area - grows to fill, leaves room for resize handle
	sidebar_left := api.create_node(api.ElementID("sidebar_left"), .Container, ctx.allocator)
	sidebar_left.style.width = api.sizing_grow() // Grows to fill (minus resize handle)
	sidebar_left.style.height = api.sizing_grow() // Grows to fill height
	sidebar_left.style.color = {0.2, 0.2, 0.2, 1.0} // Dark gray
	sidebar_left.style.layout_dir = .TopDown
	api.add_child(sidebar_container, sidebar_left)
	state.containers["sidebar_left"] = sidebar_left

	// Resize handle - thin vertical bar at right edge of sidebar
	resize_handle := api.create_node(
		api.ElementID("sidebar_resize_handle"),
		.Container,
		ctx.allocator,
	)
	resize_handle.style.width = api.sizing_px(RESIZE_HANDLE_WIDTH)
	resize_handle.style.height = api.sizing_grow()
	resize_handle.style.color = {0.15, 0.15, 0.15, 1.0} // Slightly darker than sidebar
	resize_handle.cursor = .Resize // Show resize cursor on hover
	api.add_child(sidebar_container, resize_handle)
	state.resize_handle = resize_handle

	// Editor area container - grows width and height (will hold tab container)
	editor_main := api.create_node(api.ElementID("editor_main"), .Container, ctx.allocator)
	editor_main.style.width = api.sizing_grow() // Grows to fill remaining width
	editor_main.style.height = api.sizing_grow() // Grows to fill height
	editor_main.style.color = {0.12, 0.12, 0.12, 1.0} // Slightly lighter dark
	editor_main.style.layout_dir = .TopDown
	api.add_child(horizontal_stack, editor_main)
	state.containers["editor_main"] = editor_main

	// Bottom bar - full width, fixed height
	status_bar := api.create_node(api.ElementID("status_bar"), .Container, ctx.allocator)
	status_bar.style.width = api.SIZE_FULL // Full window width
	status_bar.style.height = api.sizing_px(30) // Fixed 30px height
	status_bar.style.color = {0.15, 0.15, 0.15, 1.0} // Dark gray
	status_bar.style.layout_dir = .LeftRight
	api.add_child(root, status_bar)
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
		// Check if mouse down is on the resize handle
		#partial switch payload in event.payload {
		case api.EventPayload_MouseDown:
			if payload.element_id == api.ElementID("sidebar_resize_handle") &&
			   payload.button == .Left {
				state.is_resizing = true
				return true // Consume the event
			}
		}
		return false

	case .Mouse_Up:
		// Stop resizing on mouse up
		#partial switch payload in event.payload {
		case api.EventPayload_MouseUp:
			if state.is_resizing && payload.button == .Left {
				state.is_resizing = false
				return true // Consume the event
			}
		}
		return false

	case .Mouse_Move:
		// Handle resize dragging
		#partial switch payload in event.payload {
		case api.EventPayload_MouseMove:
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
					state.sidebar_node.style.width = api.sizing_px(int(new_width))
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
		// Update window width and clamp sidebar if needed
		#partial switch payload in event.payload {
		case api.EventPayload_WindowResize:
			state.window_width = payload.width

			// Calculate new max width (75% of window width)
			max_width := f32(payload.width) * SIDEBAR_MAX_WIDTH_PERCENT

			// If sidebar is wider than new max, clamp it
			if state.sidebar_width > max_width {
				state.sidebar_width = max_width
				if state.sidebar_node != nil {
					state.sidebar_node.style.width = api.sizing_px(int(max_width))
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
