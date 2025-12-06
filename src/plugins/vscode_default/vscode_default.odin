package vscode_default

import core "../../core"
import ui "../../ui"
import ui_api "../../ui"
import "core:fmt"
import "core:mem"

// Plugin state
VSCodeDefaultState :: struct {
	root_node:  ^ui.UINode,
	containers: map[string]^ui.UINode, // Map container ID to node
	allocator:  mem.Allocator,
}

// Initialize the plugin
vscode_default_init :: proc(ctx: ^core.PluginContext) -> bool {
	fmt.println("[vscode_default] Initializing...")

	state := new(VSCodeDefaultState, ctx.allocator)
	state.allocator = ctx.allocator
	state.containers = {}

	ctx.user_data = state

	// Create root container - vertical stack covering full window
	root := ui.create_node(ui.ElementID("vscode_root"), .Container, ctx.allocator)
	root.style.width = ui.SIZE_FULL // 100% - full window width
	root.style.height = ui.SIZE_FULL // 100% - full window height
	root.style.color = {0.1, 0.1, 0.1, 1.0} // Dark background
	root.style.layout_dir = .TopDown // Vertical stack
	state.root_node = root

	// Top bar - full width, fixed height
	top_bar := ui.create_node(ui.ElementID("top_bar"), .Container, ctx.allocator)
	top_bar.style.width = ui.SIZE_FULL // Full window width
	top_bar.style.height = ui.sizing_px(30) // Fixed 30px height
	top_bar.style.color = {0.15, 0.15, 0.15, 1.0} // Dark gray
	top_bar.style.layout_dir = .LeftRight
	ui.add_child(root, top_bar)

	// Horizontal stack - full width, grows height
	horizontal_stack := ui.create_node(ui.ElementID("horizontal_stack"), .Container, ctx.allocator)
	horizontal_stack.style.width = ui.SIZE_FULL // Full window width
	horizontal_stack.style.height = ui.sizing_grow() // Grows to fill remaining space
	horizontal_stack.style.color = {0.1, 0.1, 0.1, 1.0} // Dark background
	horizontal_stack.style.layout_dir = .LeftRight // Horizontal layout
	ui.add_child(root, horizontal_stack)

	// Sidebar - fixed width, grows height
	sidebar_left := ui.create_node(ui.ElementID("sidebar_left"), .Container, ctx.allocator)
	sidebar_left.style.width = ui.sizing_px(400) // Fixed 400px width
	sidebar_left.style.height = ui.sizing_grow() // Grows to fill height
	sidebar_left.style.color = {0.2, 0.2, 0.2, 1.0} // Dark gray
	sidebar_left.style.layout_dir = .TopDown
	ui.add_child(horizontal_stack, sidebar_left)
	state.containers["sidebar_left"] = sidebar_left

	// Text buffer/editor - grows width and height
	editor_main := ui.create_node(ui.ElementID("editor_main"), .Container, ctx.allocator)
	editor_main.style.width = ui.sizing_grow() // Grows to fill remaining width
	editor_main.style.height = ui.sizing_grow() // Grows to fill height
	editor_main.style.color = {0.12, 0.12, 0.12, 1.0} // Slightly lighter dark
	editor_main.style.layout_dir = .TopDown
	ui.add_child(horizontal_stack, editor_main)
	state.containers["editor_main"] = editor_main

	// Bottom bar - full width, fixed height
	status_bar := ui.create_node(ui.ElementID("status_bar"), .Container, ctx.allocator)
	status_bar.style.width = ui.SIZE_FULL // Full window width
	status_bar.style.height = ui.sizing_px(30) // Fixed 30px height
	status_bar.style.color = {0.15, 0.15, 0.15, 1.0} // Dark gray
	status_bar.style.layout_dir = .LeftRight
	ui.add_child(root, status_bar)
	state.containers["status_bar"] = status_bar

	// Set root node in UI API
	if ctx.ui_api != nil {
		ui_api_ptr := cast(^ui_api.UIPluginAPI)ctx.ui_api
		ui_api.set_root_node_api(ui_api_ptr, root)
	}

	// Register keyboard shortcuts
	if ctx.shortcut_registry != nil {
		shortcut_registry := cast(^core.ShortcutRegistry)ctx.shortcut_registry

		// Register platform-specific shortcuts for selecting working directory
		// On macOS, users expect Cmd+O, on Windows/Linux users expect Ctrl+O
		KEY_O :: 'o' // SDL keycode for 'O' key

		// Register Ctrl+O for Windows/Linux
		core.register_shortcut(
			shortcut_registry,
			KEY_O,
			{.Ctrl},
			"select_working_directory",
			ctx.plugin_id,
		)

		// Register Cmd+O for macOS
		core.register_shortcut(
			shortcut_registry,
			KEY_O,
			{.Cmd},
			"select_working_directory",
			ctx.plugin_id,
		)
	}

	fmt.println("[vscode_default] Layout created successfully")
	return true
}

// Update the plugin
vscode_default_update :: proc(ctx: ^core.PluginContext, dt: f32) {
	// No-op for now
}

// Shutdown the plugin
vscode_default_shutdown :: proc(ctx: ^core.PluginContext) {
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
vscode_default_on_event :: proc(ctx: ^core.PluginContext, event: ^core.Event) -> bool {
	if event == nil do return false

	state := cast(^VSCodeDefaultState)ctx.user_data
	if state == nil do return false

	#partial switch event.type {
	case .Custom_Signal:
		// Handle keyboard shortcut events
		#partial switch payload in event.payload {
		case core.EventPayload_Custom:
			if payload.name == "select_working_directory" {
				fmt.println("[vscode_default] Keyboard shortcut triggered: select_working_directory")
				fmt.println("[vscode_default] TODO: Open directory picker dialog")
				return true // Consume the event
			}
		}
		return false

	case .App_Startup:
		fmt.println(
			"[vscode_default] Received App_Startup event, emitting Layout_Container_Ready events",
		)

		// Emit Layout_Container_Ready events for each container and dispatch to plugins
		plugin_registry := cast(^core.PluginRegistry)ctx.plugin_registry

		// Sidebar for filetree
		layout_payload_sidebar := core.EventPayload_Layout {
			container_id  = "sidebar_left",
			target_plugin = "builtin:filetree",
		}
		sidebar_event, _ := core.emit_event_typed(
			ctx.eventbus,
			.Layout_Container_Ready,
			layout_payload_sidebar,
		)
		if sidebar_event != nil && plugin_registry != nil {
			core.dispatch_event_to_plugins(plugin_registry, sidebar_event)
		}

		// Editor main for buffer
		layout_payload_editor := core.EventPayload_Layout {
			container_id  = "editor_main",
			target_plugin = "builtin:buffer",
		}
		editor_event, _ := core.emit_event_typed(
			ctx.eventbus,
			.Layout_Container_Ready,
			layout_payload_editor,
		)
		if editor_event != nil && plugin_registry != nil {
			core.dispatch_event_to_plugins(plugin_registry, editor_event)
		}

		// Status bar for status plugin (future)
		layout_payload_status := core.EventPayload_Layout {
			container_id  = "status_bar",
			target_plugin = "builtin:status",
		}
		status_event, _ := core.emit_event_typed(
			ctx.eventbus,
			.Layout_Container_Ready,
			layout_payload_status,
		)
		if status_event != nil && plugin_registry != nil {
			core.dispatch_event_to_plugins(plugin_registry, status_event)
		}

		return false // Don't consume the event, let others see it

	case .Window_Resize:
		// Could update layout if needed
		return false
	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> core.PluginVTable {
	return core.PluginVTable {
		init = vscode_default_init,
		update = vscode_default_update,
		shutdown = vscode_default_shutdown,
		on_event = vscode_default_on_event,
	}
}
