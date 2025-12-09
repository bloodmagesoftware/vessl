package text_editor

import api "../../api"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Open file entry - tracks files that are displayed
OpenFileEntry :: struct {
	path:         string, // Full file path
	container_id: string, // Container ID where editor is displayed
	content_node: ^api.UINode, // The text content UINode
}

// Plugin state
TextEditorState :: struct {
	open_files: [dynamic]OpenFileEntry, // List of open files
	ctx:        ^api.PluginContext, // Store plugin context for API calls
	allocator:  mem.Allocator,
}

// Initialize the plugin
text_editor_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[text_editor] Initializing...")

	state := new(TextEditorState, ctx.allocator)
	state.allocator = ctx.allocator
	state.open_files = {}
	state.ctx = ctx

	ctx.user_data = state

	fmt.println("[text_editor] Initialized successfully")
	return true
}

// Update the plugin
text_editor_update :: proc(ctx: ^api.PluginContext, dt: f32) {
	// No-op for now
}

// Shutdown the plugin
text_editor_shutdown :: proc(ctx: ^api.PluginContext) {
	fmt.println("[text_editor] Shutting down...")

	state := cast(^TextEditorState)ctx.user_data
	if state == nil do return

	// Cleanup open files list
	for entry in state.open_files {
		delete(entry.path)
		delete(entry.container_id)
		// Note: UINodes are cleaned up by the renderer
	}
	delete(state.open_files)

	free(state)
}

// Read file contents (limited for display)
read_file_contents :: proc(path: string, allocator: mem.Allocator) -> (content: string, ok: bool) {
	data, read_ok := os.read_entire_file(path, allocator)
	if !read_ok {
		fmt.eprintf("[text_editor] Failed to read file: %s\n", path)
		return "", false
	}

	// Convert to string
	content = string(data)

	// Limit content length for display (prevent very large files from crashing)
	MAX_DISPLAY_LENGTH :: 10000
	if len(content) > MAX_DISPLAY_LENGTH {
		// Truncate and add indicator
		truncated := strings.clone(content[:MAX_DISPLAY_LENGTH], allocator)
		delete(data)
		return fmt.aprintf(
				"%s\n\n... (file truncated, %d more bytes)",
				truncated,
				len(content) - MAX_DISPLAY_LENGTH,
				allocator = allocator,
			),
			true
	}

	return content, true
}

// Create text editor UI for a file
create_editor_ui :: proc(state: ^TextEditorState, path: string, container_id: string) -> bool {
	if state == nil || state.ctx == nil do return false

	// Read file contents
	content, read_ok := read_file_contents(path, state.allocator)
	if !read_ok {
		content = fmt.aprintf("Error: Could not read file: %s", path, allocator = state.allocator)
	}

	// Create a scrollable container for the text
	container_node_id := api.ElementID(fmt.tprintf("editor_container_%s", container_id))
	container_node := api.create_node(container_node_id, .Container, state.allocator)
	api.node_set_width(state.ctx, container_node, api.SIZE_FULL)
	api.node_set_height(state.ctx, container_node, api.sizing_grow())
	api.node_set_color(state.ctx, container_node, {0.12, 0.12, 0.12, 1.0}) // Dark editor background
	api.node_set_layout_dir(state.ctx, container_node, .TopDown)
	api.node_set_padding(state.ctx, container_node, {16, 16, 16, 16})
	api.node_set_clip(state.ctx, container_node, true, true) // Enable vertical and horizontal scrolling

	// Create the text content node
	// For now, this is a simple text display - a full editor would need much more
	text_node_id := api.ElementID(fmt.tprintf("editor_text_%s", container_id))
	text_node := api.create_node(text_node_id, .Text, state.allocator)
	api.node_set_width(state.ctx, text_node, api.sizing_fit())
	api.node_set_height(state.ctx, text_node, api.sizing_fit())
	api.node_set_color(state.ctx, text_node, {0.9, 0.9, 0.9, 1.0}) // Light text color
	api.node_set_text(state.ctx, text_node, content)

	api.add_child(state.ctx, container_node, text_node)

	// Attach to the container
	if !api.attach_to_container(state.ctx, container_id, container_node) {
		fmt.eprintf("[text_editor] Failed to attach editor to container: %s\n", container_id)
		return false
	}

	// Track the open file
	entry := OpenFileEntry {
		path         = strings.clone(path, state.allocator),
		container_id = strings.clone(container_id, state.allocator),
		content_node = text_node,
	}
	append(&state.open_files, entry)

	filename := filepath.base(path)
	fmt.printf(
		"[text_editor] Created text editor for: %s in container: %s\n",
		filename,
		container_id,
	)
	return true
}

// Find and remove an open file entry by container_id
remove_open_file :: proc(state: ^TextEditorState, container_id: string) -> bool {
	for entry, i in state.open_files {
		if entry.container_id == container_id {
			fmt.printf("[text_editor] Cleaning up editor for container: %s\n", container_id)

			// Free allocated strings
			delete(entry.path)
			delete(entry.container_id)
			// Note: UINodes are cleaned up by the tab container/renderer

			// Remove from tracking array
			ordered_remove(&state.open_files, i)
			return true
		}
	}
	return false
}

// Handle events
text_editor_on_event :: proc(ctx: ^api.PluginContext, event: ^api.Event) -> bool {
	if event == nil do return false

	state := cast(^TextEditorState)ctx.user_data
	if state == nil do return false

	#partial switch event.type {
	case .Request_Editor_Attach:
		// Handle any file that hasn't been handled by other editors
		// This is the fallback/catch-all editor
		#partial switch payload in event.payload {
		case api.EventPayload_EditorAttach:
			fmt.printf("[text_editor] Handling Request_Editor_Attach for file: %s\n", payload.path)

			// Create the text editor UI
			if create_editor_ui(state, payload.path, payload.container_id) {
				return true // Consume the event - we handled it
			}

			return false // Failed to create UI
		}
		return false

	case .Request_Editor_Detach:
		// Clean up when a buffer is being closed
		#partial switch payload in event.payload {
		case api.EventPayload_EditorDetach:
			// Try to remove - returns true if we had an entry for this container
			if remove_open_file(state, payload.container_id) {
				return false // Don't consume - other editors might also need to clean up
			}
		}
		return false
	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> api.PluginVTable {
	return api.PluginVTable {
		init = text_editor_init,
		update = text_editor_update,
		shutdown = text_editor_shutdown,
		on_event = text_editor_on_event,
	}
}
