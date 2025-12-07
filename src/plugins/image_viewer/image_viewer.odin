package image_viewer

import api "../../api"
import "core:fmt"
import "core:mem"
import "core:strings"

// Supported image extensions
IMAGE_EXTENSIONS :: []string {
	".bmp",
	".gif",
	".jpg",
	".jpeg",
	".lbm",
	".pcx",
	".png",
	".pnm",
	".ppm",
	".pgm",
	".pbm",
	".qoi",
	".tga",
	".tga",
	".xcf",
	".xpm",
	".svg",
	".avif",
	".jxl",
	".tiff",
	".webp",
}

// Open image entry - tracks images that are displayed
OpenImageEntry :: struct {
	path:         string, // Full file path
	container_id: string, // Container ID where image is displayed
	image_node:   ^api.UINode, // The image UINode
}

// Plugin state
ImageViewerState :: struct {
	open_images: [dynamic]OpenImageEntry, // List of open images
	ctx:         ^api.PluginContext, // Store plugin context for API calls
	allocator:   mem.Allocator,
}

// Check if a file path is an image based on extension
is_image_file :: proc(path: string) -> bool {
	lower_path := strings.to_lower(path)
	defer delete(lower_path)

	for ext in IMAGE_EXTENSIONS {
		if strings.has_suffix(lower_path, ext) {
			return true
		}
	}
	return false
}

// Initialize the plugin
image_viewer_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[image_viewer] Initializing...")

	state := new(ImageViewerState, ctx.allocator)
	state.allocator = ctx.allocator
	state.open_images = {}
	state.ctx = ctx

	ctx.user_data = state

	fmt.println("[image_viewer] Initialized successfully")
	return true
}

// Update the plugin
image_viewer_update :: proc(ctx: ^api.PluginContext, dt: f32) {
	// No-op for now
}

// Shutdown the plugin
image_viewer_shutdown :: proc(ctx: ^api.PluginContext) {
	fmt.println("[image_viewer] Shutting down...")

	state := cast(^ImageViewerState)ctx.user_data
	if state == nil do return

	// Cleanup open images list
	for entry in state.open_images {
		delete(entry.path)
		delete(entry.container_id)
		// Note: UINodes are cleaned up by the renderer
	}
	delete(state.open_images)

	free(state)
}

// Create image viewer UI for a file
create_image_ui :: proc(state: ^ImageViewerState, path: string, container_id: string) -> bool {
	if state == nil || state.ctx == nil do return false

	// Create a container to hold the image (for centering/padding)
	container_node_id := api.ElementID(fmt.tprintf("image_container_%s", container_id))
	container_node := api.create_node(container_node_id, .Container, state.allocator)
	container_node.style.width = api.SIZE_FULL
	container_node.style.height = api.sizing_grow()
	container_node.style.color = {0.1, 0.1, 0.1, 1.0} // Dark background
	container_node.style.layout_dir = .TopDown
	container_node.style.padding = {16, 16, 16, 16}

	// Create the image node
	image_node_id := api.ElementID(fmt.tprintf("image_%s", container_id))
	image_node := api.create_node(image_node_id, .Image, state.allocator)
	image_node.style.width = api.SIZE_FULL
	image_node.style.height = api.sizing_grow()
	image_node.style.color = {0, 0, 0, 0} // Transparent background
	image_node.image_path = strings.clone(path, state.allocator)

	api.add_child(container_node, image_node)

	// Attach to the container
	if !api.attach_to_container(state.ctx, container_id, container_node) {
		fmt.eprintf("[image_viewer] Failed to attach image to container: %s\n", container_id)
		return false
	}

	// Track the open image
	entry := OpenImageEntry {
		path         = strings.clone(path, state.allocator),
		container_id = strings.clone(container_id, state.allocator),
		image_node   = image_node,
	}
	append(&state.open_images, entry)

	fmt.printf(
		"[image_viewer] Created image viewer for: %s in container: %s\n",
		path,
		container_id,
	)
	return true
}

// Handle events
image_viewer_on_event :: proc(ctx: ^api.PluginContext, event: ^api.Event) -> bool {
	if event == nil do return false

	state := cast(^ImageViewerState)ctx.user_data
	if state == nil do return false

	#partial switch event.type {
	case .Request_Editor_Attach:
		// Check if this is an image file we should handle
		#partial switch payload in event.payload {
		case api.EventPayload_EditorAttach:
			// Check if this is an image file
			if !is_image_file(payload.path) {
				// Not an image, let other plugins handle it
				return false
			}

			fmt.printf(
				"[image_viewer] Handling Request_Editor_Attach for image: %s\n",
				payload.path,
			)

			// Create the image viewer UI
			if create_image_ui(state, payload.path, payload.container_id) {
				return true // Consume the event - we handled it
			}

			return false // Failed to create UI, let others try
		}
		return false
	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> api.PluginVTable {
	return api.PluginVTable {
		init = image_viewer_init,
		update = image_viewer_update,
		shutdown = image_viewer_shutdown,
		on_event = image_viewer_on_event,
	}
}
