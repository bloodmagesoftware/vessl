package api

import "core:mem"

// =============================================================================
// Sizing Helper Functions
// =============================================================================

// Create a pixel-based sizing value
sizing_px :: proc(pixels: int) -> Sizing {
	return Sizing{unit = .Pixels, value = f32(pixels)}
}

// Create a percentage-based sizing value (0.0-1.0)
sizing_pct :: proc(percent: f32) -> Sizing {
	return Sizing{unit = .Percent, value = percent}
}

// Create a grow sizing value (fills available space)
sizing_grow :: proc() -> Sizing {
	return Sizing{unit = .Grow, value = 0.0}
}

// Create a fit sizing value (fits to content)
sizing_fit :: proc() -> Sizing {
	return Sizing{unit = .Fit, value = 0.0}
}

// =============================================================================
// UINode Helper Functions
// =============================================================================

// Create a new UINode with default styling
create_node :: proc(id: ElementID, type: ElementType, allocator := context.allocator) -> ^UINode {
	node := new(UINode, allocator)
	node.id = id
	node.type = type
	node.children = {}
	node.style = {
		width           = SIZE_FULL, // 100% default
		height          = SIZE_FULL, // 100% default
		color           = {1.0, 1.0, 1.0, 1.0}, // White default
		padding         = {0, 0, 0, 0},
		gap             = 0,
		layout_dir      = .TopDown,
		clip_vertical   = false,
		clip_horizontal = false,
		hidden          = false, // Visible by default
	}
	node.cursor = .Default // Default cursor
	return node
}

// Add a child node to a parent
add_child :: proc(parent: ^UINode, child: ^UINode) {
	if parent == nil || child == nil do return
	append(&parent.children, child)
	child.parent = parent
}

// Remove a child node from a parent
remove_child :: proc(parent: ^UINode, child: ^UINode) {
	if parent == nil || child == nil do return
	for child_node, i in parent.children {
		if child_node == child {
			ordered_remove(&parent.children, i)
			child.parent = nil
			return
		}
	}
}

// Clear all children except the first N (useful for keeping text nodes)
clear_children_except :: proc(node: ^UINode, keep_count: int = 0) {
	if node == nil do return

	// Remove children from the end, keeping the first keep_count
	for len(node.children) > keep_count {
		last_idx := len(node.children) - 1
		child := node.children[last_idx]
		child.parent = nil
		ordered_remove(&node.children, last_idx)
	}
}

// Recursive helper to find a node by ID in a tree
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

// =============================================================================
// API Convenience Wrappers
// These make it easier to call API functions from plugins
// =============================================================================

// Emit an event through the API
emit_event :: proc(ctx: ^PluginContext, type: EventType, payload: EventPayload) -> (^Event, bool) {
	if ctx == nil || ctx.api == nil || ctx.api.emit_event == nil do return nil, false
	return ctx.api.emit_event(ctx, type, payload)
}

// Dispatch an event to all plugins
dispatch_event :: proc(ctx: ^PluginContext, event: ^Event) -> bool {
	if ctx == nil || ctx.api == nil || ctx.api.dispatch_event == nil do return false
	return ctx.api.dispatch_event(ctx, event)
}

// Set the root node for rendering
set_root_node :: proc(ctx: ^PluginContext, root: ^UINode) {
	if ctx == nil || ctx.api == nil || ctx.api.set_root_node == nil do return
	ctx.api.set_root_node(ctx, root)
}

// Find a node by ID in the UI tree
find_node_by_id :: proc(ctx: ^PluginContext, id: ElementID) -> ^UINode {
	if ctx == nil || ctx.api == nil || ctx.api.find_node_by_id == nil do return nil
	return ctx.api.find_node_by_id(ctx, id)
}

// Attach a node to a container by ID
attach_to_container :: proc(ctx: ^PluginContext, container_id: string, node: ^UINode) -> bool {
	if ctx == nil || ctx.api == nil || ctx.api.attach_to_container == nil do return false
	return ctx.api.attach_to_container(ctx, container_id, node)
}

// Request a UI redraw on the next frame
// Call this when you've made UI changes that need to be rendered
// This is thread-safe and can be called from any thread
request_redraw :: proc(ctx: ^PluginContext) {
	if ctx == nil || ctx.api == nil || ctx.api.request_redraw == nil do return
	ctx.api.request_redraw(ctx)
}

// Register a keyboard shortcut
register_shortcut :: proc(
	ctx: ^PluginContext,
	key: i32,
	modifiers: KeyModifier,
	event_name: string,
) -> bool {
	if ctx == nil || ctx.api == nil || ctx.api.register_shortcut == nil do return false
	return ctx.api.register_shortcut(ctx, key, modifiers, event_name)
}

// Unregister all shortcuts for this plugin
unregister_shortcuts :: proc(ctx: ^PluginContext) {
	if ctx == nil || ctx.api == nil || ctx.api.unregister_shortcuts == nil do return
	ctx.api.unregister_shortcuts(ctx)
}

// Show a native folder selection dialog
show_folder_dialog :: proc(ctx: ^PluginContext, default_location: string = "") {
	if ctx == nil || ctx.api == nil || ctx.api.show_folder_dialog == nil do return
	ctx.api.show_folder_dialog(ctx, default_location)
}

// Get the current window size in renderer/physical pixels (accounts for DPI)
// This matches the UI coordinate system used by Clay and mouse events
get_window_size :: proc(ctx: ^PluginContext) -> (width: i32, height: i32) {
	if ctx == nil || ctx.api == nil || ctx.api.get_window_size == nil do return 0, 0
	return ctx.api.get_window_size(ctx)
}

// Measure text dimensions using the current font
// Returns the width and height in pixels that the text would occupy when rendered
measure_text :: proc(ctx: ^PluginContext, text: string) -> (width: f32, height: f32) {
	if ctx == nil || ctx.api == nil || ctx.api.measure_text == nil do return 0, 0
	return ctx.api.measure_text(ctx, text)
}

// Get the scroll position of a scrollable container
// Returns (0, 0) if the element is not found or not scrollable
// Note: scroll position is typically negative (e.g., scrolled down = negative y)
get_scroll_position :: proc(ctx: ^PluginContext, element_id: ElementID) -> (x: f32, y: f32) {
	if ctx == nil || ctx.api == nil || ctx.api.get_scroll_position == nil do return 0, 0
	return ctx.api.get_scroll_position(ctx, element_id)
}

// Set the scroll position of a scrollable container
// Use negative values to scroll (e.g., negative y = scrolled down)
// This directly modifies Clay's internal scroll position for auto-scrolling
set_scroll_position :: proc(ctx: ^PluginContext, element_id: ElementID, x: f32, y: f32) {
	if ctx == nil || ctx.api == nil || ctx.api.set_scroll_position == nil do return
	ctx.api.set_scroll_position(ctx, element_id, x, y)
}

// Get the rendered bounding box of an element
// Returns (0, 0, 0, 0, false) if the element is not found
// Note: This returns the bounds from the last rendered frame
get_element_bounds :: proc(
	ctx: ^PluginContext,
	element_id: ElementID,
) -> (
	x: f32,
	y: f32,
	width: f32,
	height: f32,
	found: bool,
) {
	if ctx == nil || ctx.api == nil || ctx.api.get_element_bounds == nil do return 0, 0, 0, 0, false
	return ctx.api.get_element_bounds(ctx, element_id)
}

// =============================================================================
// High-Level Component API Wrappers
// =============================================================================

// Create a tab container component
// parent_id: The ElementID of the parent container to attach to
// tabs: Array of TabInfo describing each tab (title and content container ID)
// Returns: ComponentID for interacting with the component, or INVALID_COMPONENT_ID on failure
create_tab_container :: proc(
	ctx: ^PluginContext,
	parent_id: ElementID,
	tabs: []TabInfo,
) -> ComponentID {
	if ctx == nil || ctx.api == nil || ctx.api.create_tab_container == nil do return INVALID_COMPONENT_ID
	return ctx.api.create_tab_container(ctx, parent_id, tabs)
}

// Select a tab in a tab container by index
// Returns true if successful, false if component not found or index out of range
tab_container_select_tab :: proc(ctx: ^PluginContext, id: ComponentID, index: int) -> bool {
	if ctx == nil || ctx.api == nil || ctx.api.tab_container_select_tab == nil do return false
	return ctx.api.tab_container_select_tab(ctx, id, index)
}

// Add a new tab to a tab container
// Returns true if successful
tab_container_add_tab :: proc(ctx: ^PluginContext, id: ComponentID, tab: TabInfo) -> bool {
	if ctx == nil || ctx.api == nil || ctx.api.tab_container_add_tab == nil do return false
	return ctx.api.tab_container_add_tab(ctx, id, tab)
}

// Remove a tab from a tab container by index
// Returns true if successful
tab_container_remove_tab :: proc(ctx: ^PluginContext, id: ComponentID, index: int) -> bool {
	if ctx == nil || ctx.api == nil || ctx.api.tab_container_remove_tab == nil do return false
	return ctx.api.tab_container_remove_tab(ctx, id, index)
}

// Get the currently active tab index
// Returns -1 if component not found or no active tab
tab_container_get_active :: proc(ctx: ^PluginContext, id: ComponentID) -> int {
	if ctx == nil || ctx.api == nil || ctx.api.tab_container_get_active == nil do return -1
	return ctx.api.tab_container_get_active(ctx, id)
}
