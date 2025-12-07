package vscode_default

import api "../../api"
import "core:fmt"
import "core:mem"

// Plugin state
VSCodeDefaultState :: struct {
	root_node:        ^api.UINode,
	containers:       map[string]^api.UINode, // Map container ID to node
	tab_container_id: api.ComponentID, // The editor tabs component
	allocator:        mem.Allocator,
}

// Initialize the plugin
vscode_default_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[vscode_default] Initializing...")

	state := new(VSCodeDefaultState, ctx.allocator)
	state.allocator = ctx.allocator
	state.containers = {}

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

	// Sidebar - fixed width, grows height
	sidebar_left := api.create_node(api.ElementID("sidebar_left"), .Container, ctx.allocator)
	sidebar_left.style.width = api.sizing_px(400) // Fixed 400px width
	sidebar_left.style.height = api.sizing_grow() // Grows to fill height
	sidebar_left.style.color = {0.2, 0.2, 0.2, 1.0} // Dark gray
	sidebar_left.style.layout_dir = .TopDown
	api.add_child(horizontal_stack, sidebar_left)
	state.containers["sidebar_left"] = sidebar_left

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

	// Create tab container with three tabs (foo, bar, baz)
	tabs := []api.TabInfo {
		{title = "foo", content_container_id = "tab_content_foo"},
		{title = "bar", content_container_id = "tab_content_bar"},
		{title = "baz", content_container_id = "tab_content_baz"},
	}
	tab_component_id := api.create_tab_container(ctx, api.ElementID("editor_main"), tabs)
	if tab_component_id != api.INVALID_COMPONENT_ID {
		state.tab_container_id = tab_component_id
		fmt.printf("[vscode_default] Created tab container with ID %d\n", u64(tab_component_id))

		// Add sample content to each tab
		// Foo tab content
		foo_text := api.create_node(api.ElementID("foo_content_text"), .Text, ctx.allocator)
		foo_text.text_content = "This is the FOO tab content"
		foo_text.style.color = {0.9, 0.7, 0.3, 1.0} // Orange text
		foo_text.style.width = api.sizing_fit()
		foo_text.style.height = api.sizing_fit()
		api.attach_to_container(ctx, "tab_content_foo", foo_text)

		// Bar tab content
		bar_text := api.create_node(api.ElementID("bar_content_text"), .Text, ctx.allocator)
		bar_text.text_content = "This is the BAR tab content"
		bar_text.style.color = {0.3, 0.9, 0.5, 1.0} // Green text
		bar_text.style.width = api.sizing_fit()
		bar_text.style.height = api.sizing_fit()
		api.attach_to_container(ctx, "tab_content_bar", bar_text)

		// Baz tab content
		baz_text := api.create_node(api.ElementID("baz_content_text"), .Text, ctx.allocator)
		baz_text.text_content = "This is the BAZ tab content"
		baz_text.style.color = {0.5, 0.6, 0.9, 1.0} // Blue text
		baz_text.style.width = api.sizing_fit()
		baz_text.style.height = api.sizing_fit()
		api.attach_to_container(ctx, "tab_content_baz", baz_text)
	} else {
		fmt.eprintln("[vscode_default] Failed to create tab container")
	}

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

		// Editor main for buffer
		layout_payload_editor := api.EventPayload_Layout {
			container_id  = "editor_main",
			target_plugin = "builtin:buffer",
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
		// Could update layout if needed
		return false
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
