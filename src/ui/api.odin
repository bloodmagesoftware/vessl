package ui

import "core:mem"
import "core:strings"

// UIPluginAPI - Provides functions for plugins to manipulate the UI DOM
UIPluginAPI :: struct {
	renderer_ctx: ^RendererContext,
	root_node:    ^UINode,
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
destroy_ui_api :: proc(api: ^UIPluginAPI) {
	if api == nil do return
	free(api)
}

// Recursive helper to find a node by ID
find_node_by_id_recursive :: proc(node: ^UINode, id: ElementID) -> ^UINode {
	if node == nil do return nil

	if node.id == id {
		return node
	}

	// Search children
	for child in node.children {
		if result := find_node_by_id_recursive(child, id); result != nil {
			return result
		}
	}

	return nil
}

// Find a node by ID
find_node_by_id :: proc(api: ^UIPluginAPI, id: ElementID) -> ^UINode {
	if api == nil || api.root_node == nil do return nil

	return find_node_by_id_recursive(api.root_node, id)
}

// Attach a node to a container by container ID
attach_to_container :: proc(api: ^UIPluginAPI, container_id: string, node: ^UINode) -> bool {
	if api == nil || node == nil do return false

	// Convert string to ElementID
	container_element_id := ElementID(container_id)

	// Find the container
	container := find_node_by_id(api, container_element_id)
	if container == nil {
		return false
	}

	// Verify it's a container
	if container.type != .Container {
		return false
	}

	// Add the node as a child
	add_child(container, node)

	return true
}

// Create a container node
create_container :: proc(
	api: ^UIPluginAPI,
	id: ElementID,
	style: Style,
	allocator := context.allocator,
) -> ^UINode {
	if api == nil do return nil

	node := create_node(id, .Container, allocator)
	node.style = style

	return node
}

// Get the root node
get_root_node :: proc(api: ^UIPluginAPI) -> ^UINode {
	if api == nil do return nil
	return api.root_node
}

// Set the root node (used by main plugin)
set_root_node_api :: proc(api: ^UIPluginAPI, root: ^UINode) {
	if api == nil || api.renderer_ctx == nil do return

	api.renderer_ctx.root_node = root
	api.root_node = root
}
