package filetree

import core "../../core"
import ui "../../ui"
import ui_api "../../ui"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Plugin state
FiletreeState :: struct {
	root_path:    string,
	root_node:    ^ui.UINode,
	expanded:     map[string]bool,
	file_entries: map[string]string, // Maps UI node ID to file path
	attached:     bool, // Whether we've attached to a container
	eventbus:     ^core.EventBus, // Store eventbus for emitting events
	allocator:    mem.Allocator,
}

// Initialize the plugin
filetree_init :: proc(ctx: ^core.PluginContext) -> bool {
	fmt.println("[filetree] Initializing...")

	state := new(FiletreeState, ctx.allocator)
	state.allocator = ctx.allocator
	state.expanded = {}
	state.file_entries = {}
	state.attached = false
	state.eventbus = ctx.eventbus

	// Get current working directory as default root
	cwd := os.get_current_directory()
	state.root_path = strings.clone(cwd, ctx.allocator)

	ctx.user_data = state

	fmt.printf("[filetree] Root path: %s\n", state.root_path)
	return true
}

// Update the plugin
filetree_update :: proc(ctx: ^core.PluginContext, dt: f32) {
	// No-op for now
}

// Shutdown the plugin
filetree_shutdown :: proc(ctx: ^core.PluginContext) {
	fmt.println("[filetree] Shutting down...")

	state := cast(^FiletreeState)ctx.user_data
	if state == nil do return

	// Cleanup maps
	delete(state.expanded)
	delete(state.file_entries)

	// Free root path string
	delete(state.root_path)

	// Note: UI nodes will be cleaned up by the renderer
	// We don't need to manually free them here

	free(state)
}

// Build filetree UI recursively
// MAX_DEPTH prevents infinite recursion from symlinks or circular references
MAX_DEPTH :: 10

build_filetree_ui :: proc(
	state: ^FiletreeState,
	parent_node: ^ui.UINode,
	dir_path: string,
	depth: int,
) {
	if state == nil || parent_node == nil do return

	// Prevent infinite recursion
	if depth > MAX_DEPTH {
		fmt.eprintf("[filetree] Max depth reached for: %s\n", dir_path)
		return
	}

	// Read directory
	dir, err := os.open(dir_path)
	if err != os.ERROR_NONE {
		fmt.eprintf("[filetree] Failed to open directory: %s\n", dir_path)
		return
	}
	defer os.close(dir)

	entries, read_err := os.read_dir(dir, 0, state.allocator)
	if read_err != os.ERROR_NONE {
		fmt.eprintf("[filetree] Failed to read directory: %s\n", dir_path)
		return
	}
	defer delete(entries)

	// Limit number of entries to prevent UI overload
	MAX_ENTRIES :: 100
	if len(entries) > MAX_ENTRIES {
		fmt.printf(
			"[filetree] Limiting entries in %s (has %d, showing first %d)\n",
			dir_path,
			len(entries),
			MAX_ENTRIES,
		)
	}

	// Sort entries: directories first, then files
	// Simple approach: create two lists and combine
	dirs: [dynamic]os.File_Info
	files: [dynamic]os.File_Info

	entry_count := 0
	for entry in entries {
		// Limit total entries to prevent UI overload
		if entry_count >= MAX_ENTRIES do break
		entry_count += 1

		// Skip hidden files/directories (starting with .)
		if len(entry.name) > 0 && entry.name[0] == '.' {
			continue
		}

		full_path := filepath.join({dir_path, entry.name}, state.allocator)
		defer delete(full_path)

		// Skip if we can't determine if it's a directory (might be a symlink issue)
		if !os.exists(full_path) {
			continue
		}

		if os.is_dir(full_path) {
			append(&dirs, entry)
		} else {
			append(&files, entry)
		}
	}

	// Add directories first
	for entry in dirs {
		full_path := filepath.join({dir_path, entry.name}, state.allocator)
		defer delete(full_path)

		// Create entry node (container for directory)
		// This will contain the text node and (when expanded) the children
		entry_id := ui.ElementID(fmt.tprintf("filetree_entry_%s_%d", full_path, depth))
		entry_node := ui.create_node(entry_id, .Container, state.allocator)
		entry_node.style.width = ui.SIZE_FULL
		entry_node.style.height = ui.sizing_fit() // Auto-size to content
		entry_node.style.color = {0.2, 0.2, 0.2, 1.0}
		entry_node.style.layout_dir = .TopDown // Vertical layout: text on top, children below
		entry_node.style.padding = {0, 0, 0, 0} // No padding on entry node itself

		// Create a row container for the directory name (for horizontal layout: indentation + text)
		row_id := ui.ElementID(fmt.tprintf("filetree_row_%s", full_path))
		row_node := ui.create_node(row_id, .Container, state.allocator)
		row_node.style.width = ui.SIZE_FULL
		row_node.style.height = ui.sizing_fit()
		row_node.style.color = {0.2, 0.2, 0.2, 1.0} // Default background (will change on hover)
		row_node.style.layout_dir = .LeftRight // Horizontal: indentation + text
		row_node.style.padding = {u16(depth * 16), 4, 4, 4} // Indentation left, padding for better click target

		// Set click callback for directory (toggle expansion)
		// Store full_path in a cloned string for the callback
		dir_path_clone := strings.clone(full_path, state.allocator)
		// Create a context struct to pass both state, path, entry node, and depth
		dir_callback_ctx := new(struct {
				state:      ^FiletreeState,
				path:       string,
				entry_node: ^ui.UINode,
				depth:      int,
			}, state.allocator)
		dir_callback_ctx.state = state
		dir_callback_ctx.path = dir_path_clone
		dir_callback_ctx.entry_node = entry_node
		dir_callback_ctx.depth = depth

		click_callback := proc(ctx: rawptr) {
			callback_ctx := cast(^struct {
				state:      ^FiletreeState,
				path:       string,
				entry_node: ^ui.UINode,
				depth:      int,
			})ctx
			if callback_ctx == nil || callback_ctx.state == nil || callback_ctx.entry_node == nil do return

			// Toggle expansion
			is_expanded := callback_ctx.state.expanded[callback_ctx.path] or_else false
			new_expanded := !is_expanded
			callback_ctx.state.expanded[callback_ctx.path] = new_expanded

			fmt.printf(
				"[filetree] Toggled directory: %s (expanded: %v)\n",
				callback_ctx.path,
				new_expanded,
			)

			// Rebuild UI for this directory
			if new_expanded {
				// Expand: add children to the entry node
				// First, clear any existing children except the row_node (first child, contains text)
				ui.clear_children_except(callback_ctx.entry_node, 1)
				// Then add directory contents (these will appear below the row_node)
				build_filetree_ui(
					callback_ctx.state,
					callback_ctx.entry_node,
					callback_ctx.path,
					callback_ctx.depth + 1,
				)
			} else {
				// Collapse: remove all children except the row_node (first child, contains text)
				ui.clear_children_except(callback_ctx.entry_node, 1)
			}
		}

		// Set callback on row node (the clickable area)
		row_node.on_click = click_callback
		row_node.callback_ctx = dir_callback_ctx
		row_node.cursor = .Hand // Set hand cursor for clickable directory items

		// Create text node for directory name
		text_id := ui.ElementID(fmt.tprintf("filetree_text_%s", full_path))
		text_node := ui.create_node(text_id, .Text, state.allocator)
		text_node.style.width = ui.sizing_grow()
		text_node.style.height = ui.sizing_fit() // Auto-size to text content
		text_node.style.padding = {0, 0, 0, 0} // No padding on text node itself
		text_node.text_content = strings.clone(entry.name, state.allocator)
		text_node.style.color = {0.8, 0.8, 0.8, 1.0} // Light gray text

		// Set click callback on text node so clicking directly on text works
		text_node.on_click = click_callback
		text_node.callback_ctx = dir_callback_ctx
		text_node.cursor = .Hand // Set hand cursor for clickable directory text

		// Build hierarchy: entry_node -> row_node -> text_node
		// When expanded, children will be added directly to entry_node (below row_node)
		ui.add_child(row_node, text_node)
		ui.add_child(entry_node, row_node)
		ui.add_child(parent_node, entry_node)

		// If expanded, recursively add children
		if state.expanded[full_path] or_else false {
			build_filetree_ui(state, entry_node, full_path, depth + 1)
		}
	}

	// Add files
	for entry in files {
		full_path := filepath.join({dir_path, entry.name}, state.allocator)
		defer delete(full_path)

		// Create entry node (container for file)
		// Files are simpler - just a row with indentation + text
		entry_id := ui.ElementID(fmt.tprintf("filetree_entry_%s_%d", full_path, depth))
		entry_node := ui.create_node(entry_id, .Container, state.allocator)
		entry_node.style.width = ui.SIZE_FULL
		entry_node.style.height = ui.sizing_fit() // Auto-size to content
		entry_node.style.color = {0.2, 0.2, 0.2, 1.0} // Default background (will change on hover)
		entry_node.style.layout_dir = .LeftRight // Horizontal: indentation + text
		entry_node.style.padding = {u16(depth * 16), 4, 4, 4} // Indentation left, padding for better click target

		// Store file path for click handling
		file_path_clone := strings.clone(full_path, state.allocator)
		state.file_entries[string(entry_id)] = file_path_clone

		// Set click callback for file (emit Buffer_Open event)
		// Create a context struct to pass both state and path
		file_callback_ctx := new(struct {
				state: ^FiletreeState,
				path:  string,
			}, state.allocator)
		file_callback_ctx.state = state
		file_callback_ctx.path = file_path_clone

		file_click_callback := proc(ctx: rawptr) {
			callback_ctx := cast(^struct {
				state: ^FiletreeState,
				path:  string,
			})ctx
			if callback_ctx == nil || callback_ctx.state == nil do return

			fmt.printf("[filetree] File clicked: %s\n", callback_ctx.path)

			// Emit Buffer_Open event
			buffer_payload := core.EventPayload_Buffer {
				file_path = callback_ctx.path,
				buffer_id = fmt.tprintf("buffer_%s", callback_ctx.path),
			}
			core.emit_event_typed(callback_ctx.state.eventbus, .Buffer_Open, buffer_payload)
		}

		// Set callback on entry node
		entry_node.on_click = file_click_callback
		entry_node.callback_ctx = file_callback_ctx
		entry_node.cursor = .Hand // Set hand cursor for clickable file items

		// Create text node for file name
		text_id := ui.ElementID(fmt.tprintf("filetree_text_%s", full_path))
		text_node := ui.create_node(text_id, .Text, state.allocator)
		text_node.style.width = ui.sizing_grow()
		text_node.style.height = ui.sizing_fit() // Auto-size to text content
		text_node.style.padding = {0, 0, 0, 0} // No padding on text node itself
		text_node.text_content = strings.clone(entry.name, state.allocator)
		text_node.style.color = {0.7, 0.7, 0.9, 1.0} // Slightly blue for files

		// Set click callback on text node so clicking directly on text works
		text_node.on_click = file_click_callback
		text_node.callback_ctx = file_callback_ctx
		text_node.cursor = .Hand // Set hand cursor for clickable file text

		ui.add_child(entry_node, text_node)
		ui.add_child(parent_node, entry_node)
	}
}

// Handle events
filetree_on_event :: proc(ctx: ^core.PluginContext, event: ^core.Event) -> bool {
	if event == nil do return false

	state := cast(^FiletreeState)ctx.user_data
	if state == nil {
		fmt.eprintln("[filetree] on_event: state is nil")
		return false
	}

	// Only log non-App_Startup events to reduce noise
	if event.type != .App_Startup {
		fmt.printf("[filetree] Received event type: %v\n", event.type)
	}

	#partial switch event.type {
	case .Layout_Container_Ready:
		fmt.println("[filetree] Processing Layout_Container_Ready event")
		// Check if this event is for us - use type switch for safe casting
		#partial switch payload in event.payload {
		case core.EventPayload_Layout:
			fmt.printf("[filetree] Event target_plugin: %s\n", payload.target_plugin)
			if payload.target_plugin != "builtin:filetree" {
				fmt.printf(
					"[filetree] Event not for us (target: %s), ignoring\n",
					payload.target_plugin,
				)
				return false
			}

			// Only attach once
			if state.attached {
				fmt.println("[filetree] Already attached, ignoring")
				return false
			}

			fmt.printf(
				"[filetree] Received Layout_Container_Ready for container: %s\n",
				payload.container_id,
			)

			// Build filetree UI
			if state.root_node == nil {
				// Create root container for filetree (scrollable)
				root_id := ui.ElementID("filetree_root")
				state.root_node = ui.create_node(root_id, .Container, ctx.allocator)
				state.root_node.style.width = ui.SIZE_FULL
				state.root_node.style.height = ui.SIZE_FULL
				state.root_node.style.color = {0.2, 0.2, 0.2, 1.0}
				state.root_node.style.layout_dir = .TopDown
				state.root_node.style.padding = {8, 8, 8, 8} // Padding around filetree
				state.root_node.style.clip_vertical = true // Enable vertical scrolling
				state.root_node.style.clip_horizontal = false

				// Build the filetree (only top level, don't expand subdirectories by default)
				fmt.printf("[filetree] Building filetree UI for: %s\n", state.root_path)
				build_filetree_ui(state, state.root_node, state.root_path, 0)
				fmt.printf("[filetree] Finished building filetree UI\n")
			}

			// Attach to the container
			if ctx.ui_api != nil {
				ui_api_ptr := cast(^ui_api.UIPluginAPI)ctx.ui_api
				if ui_api.attach_to_container(ui_api_ptr, payload.container_id, state.root_node) {
					state.attached = true
					fmt.println("[filetree] Successfully attached to container")
					return true // Consume the event
				} else {
					fmt.eprintln("[filetree] Failed to attach to container")
				}
			}

			return false
		case:
			fmt.eprintln("[filetree] Event payload is not EventPayload_Layout")
			return false
		}

	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> core.PluginVTable {
	return core.PluginVTable {
		init = filetree_init,
		update = filetree_update,
		shutdown = filetree_shutdown,
		on_event = filetree_on_event,
	}
}
