package ui

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

// PlatformAPI - Provides platform-level functionality for plugins
// Plugins should use this API instead of directly accessing SDL
PlatformAPI :: struct {
	window:    ^sdl.Window,
	allocator: mem.Allocator,
	// Callback context for async dialog operations
	dialog_ctx: ^DialogCallbackContext,
	mutex:     sync.Mutex,
}

// Context passed to dialog callbacks
DialogCallbackContext :: struct {
	eventbus:        rawptr, // ^core.EventBus - rawptr to avoid circular dependency
	plugin_registry: rawptr, // ^core.PluginRegistry - rawptr to avoid circular dependency
	allocator:       mem.Allocator,
}

// Callback type for folder dialog results
// path is nil if the user cancelled, otherwise contains the selected folder path
FolderDialogCallback :: proc(path: string, user_data: rawptr)

// Initialize Platform API
init_platform_api :: proc(
	window: ^sdl.Window,
	eventbus: rawptr,
	plugin_registry: rawptr,
	allocator := context.allocator,
) -> ^PlatformAPI {
	if window == nil do return nil

	api := new(PlatformAPI, allocator)
	api.window = window
	api.allocator = allocator
	api.mutex = {}

	// Create dialog callback context
	api.dialog_ctx = new(DialogCallbackContext, allocator)
	api.dialog_ctx.eventbus = eventbus
	api.dialog_ctx.plugin_registry = plugin_registry
	api.dialog_ctx.allocator = allocator

	return api
}

// Destroy Platform API
destroy_platform_api :: proc(api: ^PlatformAPI) {
	if api == nil do return

	if api.dialog_ctx != nil {
		free(api.dialog_ctx)
	}

	free(api)
}

// Internal SDL callback for folder dialog
// This is called by SDL when the user selects a folder or cancels
@(private)
folder_dialog_sdl_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	// Set up proper Odin context for C callback (needed for allocators, fmt, etc.)
	context = runtime.default_context()
	
	dialog_ctx := cast(^DialogCallbackContext)userdata
	if dialog_ctx == nil {
		return
	}

	// Check if user cancelled (filelist is nil or first entry is nil)
	if filelist == nil || filelist[0] == nil {
		fmt.println("[platform] Folder dialog cancelled by user")
		return
	}

	// Get the selected folder path
	selected_path := string(filelist[0])
	fmt.printf("[platform] Folder selected: %s\n", selected_path)

	// We need to emit a Working_Directory_Changed event
	// Since we can't import core package here (circular dependency),
	// we'll use a different approach - store the path and let main loop process it
	// For now, we'll use a global to communicate back
	// This is set and then the main loop will check it
	
	sync.mutex_lock(&g_pending_folder_mutex)
	defer sync.mutex_unlock(&g_pending_folder_mutex)
	
	// Clone the path since SDL will free the filelist after callback returns
	if g_pending_folder_path != "" {
		delete(g_pending_folder_path)
	}
	g_pending_folder_path = strings.clone(selected_path)
	g_pending_folder_changed = true
}

// Global state for pending folder selection (SDL callback runs on main thread but outside our control)
@(private)
g_pending_folder_path: string
@(private)
g_pending_folder_changed: bool
@(private)
g_pending_folder_mutex: sync.Mutex

// Show native folder selection dialog
// This is asynchronous - the dialog result will be delivered via Working_Directory_Changed event
show_folder_dialog :: proc(api: ^PlatformAPI, default_location: string = "") {
	if api == nil do return

	fmt.println("[platform] Opening folder selection dialog...")

	// Convert default_location to cstring if provided
	default_loc_cstr: cstring = nil
	if len(default_location) > 0 {
		default_loc_cstr = strings.clone_to_cstring(default_location, api.allocator)
	}

	// Call SDL's folder dialog
	// Parameters:
	// - callback: Called when user selects a folder or cancels
	// - userdata: Passed to callback
	// - window: Parent window (for modal behavior)
	// - default_location: Starting directory (can be nil)
	// - allow_many: Whether to allow selecting multiple folders
	sdl.ShowOpenFolderDialog(
		folder_dialog_sdl_callback,
		api.dialog_ctx,
		api.window,
		default_loc_cstr,
		false, // Don't allow selecting multiple folders
	)
}

// Check if there's a pending folder selection and return it
// Returns: (path, has_pending) - path is valid only if has_pending is true
// Caller must free the returned path string
check_pending_folder_selection :: proc() -> (string, bool) {
	sync.mutex_lock(&g_pending_folder_mutex)
	defer sync.mutex_unlock(&g_pending_folder_mutex)

	if g_pending_folder_changed {
		g_pending_folder_changed = false
		path := g_pending_folder_path
		g_pending_folder_path = ""
		return path, true
	}

	return "", false
}

