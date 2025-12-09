package ui

import api "../api"

// UIPluginAPI - Internal API for UI manipulation
// This is used by the VesslAPI implementation to provide UI functions to plugins
UIPluginAPI :: struct {
	renderer_ctx: ^RendererContext,
	root_node:    ^api.UINode,
}

// Initialize UI Plugin API
init_ui_api :: proc(renderer_ctx: ^RendererContext) -> ^UIPluginAPI {
	if renderer_ctx == nil do return nil

	api := new(UIPluginAPI)
	api.renderer_ctx = renderer_ctx
	api.root_node = renderer_ctx.root_node

	return api
}

// Destroy UI Plugin API
destroy_ui_api :: proc(uiapi: ^UIPluginAPI) {
	if uiapi == nil do return
	free(uiapi)
}

// Find a node by ID
find_node_by_id :: proc(uiapi: ^UIPluginAPI, id: api.ElementID) -> ^api.UINode {
	if uiapi == nil || uiapi.root_node == nil do return nil

	return api.find_node_by_id_recursive(uiapi.root_node, id)
}

// Attach a node to a container by container ID
attach_to_container :: proc(uiapi: ^UIPluginAPI, container_id: string, node: ^api.UINode) -> bool {
	if uiapi == nil || node == nil do return false

	// Convert string to ElementID
	container_element_id := api.ElementID(container_id)

	// Find the container
	container := find_node_by_id(uiapi, container_element_id)
	if container == nil {
		return false
	}

	// Verify it's a container
	if container.type != .Container {
		return false
	}

	// Add the node as a child
	api.add_child(container, node)

	return true
}

// Create a container node
create_container :: proc(
	uiapi: ^UIPluginAPI,
	id: api.ElementID,
	style: api.Style,
	allocator := context.allocator,
) -> ^api.UINode {
	if uiapi == nil do return nil

	node := api.create_node(id, .Container, allocator)
	node.style = style

	return node
}

// Get the root node
get_root_node :: proc(uiapi: ^UIPluginAPI) -> ^api.UINode {
	if uiapi == nil do return nil
	return uiapi.root_node
}

// Set the root node (used by main plugin)
set_root_node_api :: proc(uiapi: ^UIPluginAPI, root: ^api.UINode) {
	if uiapi == nil || uiapi.renderer_ctx == nil do return

	uiapi.renderer_ctx.root_node = root
	uiapi.root_node = root
}

// Measure text dimensions using the current font
// Returns width and height in pixels
measure_text :: proc(uiapi: ^UIPluginAPI, text: string) -> (width: f32, height: f32) {
	if uiapi == nil || uiapi.renderer_ctx == nil do return 0, 0
	return measure_text_dimensions(uiapi.renderer_ctx, text)
}

// Get scroll position for a scrollable container
// Returns (0, 0) if not found or not scrollable
get_scroll_position :: proc(uiapi: ^UIPluginAPI, element_id: api.ElementID) -> (x: f32, y: f32) {
	if uiapi == nil || uiapi.renderer_ctx == nil do return 0, 0
	return get_element_scroll_position(uiapi.renderer_ctx, element_id)
}

// Set scroll position for a scrollable container
// Directly modifies Clay's internal scroll position for auto-scrolling
// Use negative values to scroll (e.g., negative y = scrolled down)
set_scroll_position :: proc(uiapi: ^UIPluginAPI, element_id: api.ElementID, x: f32, y: f32) {
	if uiapi == nil || uiapi.renderer_ctx == nil do return
	set_element_scroll_position(uiapi.renderer_ctx, element_id, x, y)
}

// Get the rendered bounding box of an element
// Returns the bounds from the last rendered frame
get_element_bounds_ui :: proc(
	uiapi: ^UIPluginAPI,
	element_id: api.ElementID,
) -> (
	x: f32,
	y: f32,
	width: f32,
	height: f32,
	found: bool,
) {
	if uiapi == nil || uiapi.renderer_ctx == nil do return 0, 0, 0, 0, false
	return get_element_bounds(uiapi.renderer_ctx, element_id)
}
