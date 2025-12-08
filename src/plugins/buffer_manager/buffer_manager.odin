package buffer_manager

import api "../../api"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"

// Open file entry - tracks files that are open in tabs
OpenFileEntry :: struct {
	path:         string, // Full file path
	tab_index:    int, // Index in the tab container
	container_id: string, // Content container ID for this tab
}

// Plugin state
BufferManagerState :: struct {
	tab_container_id: api.ComponentID, // The tab container component
	open_files:       [dynamic]OpenFileEntry, // List of open files
	next_tab_id:      int, // Counter for generating unique tab content IDs
	attached:         bool, // Whether we've attached to a container
	ctx:              ^api.PluginContext, // Store plugin context for API calls
	allocator:        mem.Allocator,
}

// Initialize the plugin
buffer_manager_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[buffer_manager] Initializing...")

	state := new(BufferManagerState, ctx.allocator)
	state.allocator = ctx.allocator
	state.tab_container_id = api.INVALID_COMPONENT_ID
	state.open_files = {}
	state.next_tab_id = 0
	state.attached = false
	state.ctx = ctx

	ctx.user_data = state

	fmt.println("[buffer_manager] Initialized successfully")
	return true
}

// Update the plugin
buffer_manager_update :: proc(ctx: ^api.PluginContext, dt: f32) {
	// No-op for now
}

// Shutdown the plugin
buffer_manager_shutdown :: proc(ctx: ^api.PluginContext) {
	fmt.println("[buffer_manager] Shutting down...")

	state := cast(^BufferManagerState)ctx.user_data
	if state == nil do return

	// Cleanup open files list
	for entry in state.open_files {
		delete(entry.path)
		delete(entry.container_id)
	}
	delete(state.open_files)

	free(state)
}

// Find if a file is already open, returns index or -1 if not found
find_open_file :: proc(state: ^BufferManagerState, path: string) -> int {
	for entry, i in state.open_files {
		if entry.path == path {
			return i
		}
	}
	return -1
}

// Open a file (creates tab if not already open, or focuses existing tab)
open_file :: proc(state: ^BufferManagerState, path: string) {
	if state == nil || state.ctx == nil do return

	// Check if file is already open
	existing_idx := find_open_file(state, path)
	if existing_idx >= 0 {
		// File is already open, focus the tab
		fmt.printf(
			"[buffer_manager] File already open, selecting tab %d: %s\n",
			existing_idx,
			path,
		)
		api.tab_container_select_tab(state.ctx, state.tab_container_id, existing_idx)
		return
	}

	// File is not open, create a new tab
	// Generate unique container ID for this tab's content
	container_id := fmt.aprintf(
		"buffer_content_%d",
		state.next_tab_id,
		allocator = state.allocator,
	)
	state.next_tab_id += 1

	// Get filename for tab title
	filename := filepath.base(path)

	// Create tab info
	tab_info := api.TabInfo {
		title                = filename,
		content_container_id = container_id,
	}

	// Add tab to container
	if !api.tab_container_add_tab(state.ctx, state.tab_container_id, tab_info) {
		fmt.eprintf("[buffer_manager] Failed to add tab for: %s\n", path)
		delete(container_id)
		return
	}

	// Track the open file
	entry := OpenFileEntry {
		path         = strings.clone(path, state.allocator),
		tab_index    = len(state.open_files),
		container_id = container_id,
	}
	append(&state.open_files, entry)

	// Select the new tab
	api.tab_container_select_tab(state.ctx, state.tab_container_id, entry.tab_index)

	fmt.printf("[buffer_manager] Opened file in new tab %d: %s\n", entry.tab_index, path)

	// Emit Request_Editor_Attach event for editor plugins to handle
	attach_payload := api.EventPayload_EditorAttach {
		path         = path,
		container_id = container_id,
	}
	// Note: emit_event returns (event, handled) - we only care about getting a valid event
	event, _ := api.emit_event(state.ctx, .Request_Editor_Attach, attach_payload)
	if event != nil {
		api.dispatch_event(state.ctx, event)
	}
}

// Handle events
buffer_manager_on_event :: proc(ctx: ^api.PluginContext, event: ^api.Event) -> bool {
	if event == nil do return false

	state := cast(^BufferManagerState)ctx.user_data
	if state == nil do return false

	#partial switch event.type {
	case .Layout_Container_Ready:
		// Check if this event is for us
		#partial switch payload in event.payload {
		case api.EventPayload_Layout:
			if payload.target_plugin != "builtin:buffer_manager" {
				return false
			}

			// Only attach once
			if state.attached {
				fmt.println("[buffer_manager] Already attached, ignoring")
				return false
			}

			fmt.printf(
				"[buffer_manager] Received Layout_Container_Ready for container: %s\n",
				payload.container_id,
			)

			// Create empty tab container (tabs will be added when files are opened)
			tabs: []api.TabInfo = {}
			tab_component_id := api.create_tab_container(
				ctx,
				api.ElementID(payload.container_id),
				tabs,
			)
			if tab_component_id != api.INVALID_COMPONENT_ID {
				state.tab_container_id = tab_component_id
				state.attached = true
				fmt.printf(
					"[buffer_manager] Created tab container with ID %d\n",
					u64(tab_component_id),
				)
			} else {
				fmt.eprintln("[buffer_manager] Failed to create tab container")
			}

			return false // Don't consume, let others see it
		}
		return false

	case .Request_Open_File:
		// Handle file open requests from file tree
		#partial switch payload in event.payload {
		case api.EventPayload_OpenFile:
			fmt.printf("[buffer_manager] Received Request_Open_File: %s\n", payload.path)

			// Only process if we have a tab container
			if state.tab_container_id == api.INVALID_COMPONENT_ID {
				fmt.eprintln("[buffer_manager] No tab container available, cannot open file")
				return false
			}

			open_file(state, payload.path)
			return true // Consume the event
		}
		return false

	case .Working_Directory_Changed:
		// Close all open buffers when changing to a new directory
		fmt.println("[buffer_manager] Working directory changed, closing all buffers")

		// Notify editor plugins to detach and clean up (iterate in reverse to avoid index shifting)
		for i := len(state.open_files) - 1; i >= 0; i -= 1 {
			entry := state.open_files[i]

			// Emit Request_Editor_Detach so editor plugins can clean up their resources
			detach_payload := api.EventPayload_EditorDetach {
				container_id = entry.container_id,
			}
			detach_event, _ := api.emit_event(state.ctx, .Request_Editor_Detach, detach_payload)
			if detach_event != nil {
				api.dispatch_event(state.ctx, detach_event)
			}

			// Remove the tab from the UI
			api.tab_container_remove_tab(state.ctx, state.tab_container_id, i)
		}

		// Clean up the open_files tracking array
		for entry in state.open_files {
			delete(entry.path)
			delete(entry.container_id)
		}
		clear(&state.open_files)

		// Reset the tab ID counter
		state.next_tab_id = 0

		fmt.println("[buffer_manager] All buffers closed")
		return false // Don't consume, let others handle it too
	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> api.PluginVTable {
	return api.PluginVTable {
		init = buffer_manager_init,
		update = buffer_manager_update,
		shutdown = buffer_manager_shutdown,
		on_event = buffer_manager_on_event,
	}
}
