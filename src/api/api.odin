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
// Note: ctx can be nil during initial UI construction (before first render)
add_child :: proc(ctx: ^PluginContext, parent: ^UINode, child: ^UINode) {
	if parent == nil || child == nil do return
	append(&parent.children, child)
	child.parent = parent
	request_render(ctx)
}

// Remove a child node from a parent
remove_child :: proc(ctx: ^PluginContext, parent: ^UINode, child: ^UINode) {
	if parent == nil || child == nil do return
	for child_node, i in parent.children {
		if child_node == child {
			ordered_remove(&parent.children, i)
			child.parent = nil
			request_render(ctx)
			return
		}
	}
}

// Clear all children except the first N (useful for keeping text nodes)
clear_children_except :: proc(ctx: ^PluginContext, node: ^UINode, keep_count: int = 0) {
	if node == nil do return

	// Remove children from the end, keeping the first keep_count
	for len(node.children) > keep_count {
		last_idx := len(node.children) - 1
		child := node.children[last_idx]
		child.parent = nil
		ordered_remove(&node.children, last_idx)
	}
	request_render(ctx)
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

// Request a render to occur within 10ms (for batching UI changes)
request_render :: proc(ctx: ^PluginContext) {
	if ctx == nil || ctx.api == nil || ctx.api.request_render == nil do return
	ctx.api.request_render(ctx)
}

// =============================================================================
// UINode Setter Functions
// All setters automatically call request_render to schedule a UI update
// =============================================================================

// Style setters

// Set the width of a node
node_set_width :: proc(ctx: ^PluginContext, node: ^UINode, width: Sizing) {
	if node == nil do return
	node.style.width = width
	request_render(ctx)
}

// Set the height of a node
node_set_height :: proc(ctx: ^PluginContext, node: ^UINode, height: Sizing) {
	if node == nil do return
	node.style.height = height
	request_render(ctx)
}

// Set the background color of a node (RGBA, 0.0-1.0)
node_set_color :: proc(ctx: ^PluginContext, node: ^UINode, color: [4]f32) {
	if node == nil do return
	node.style.color = color
	request_render(ctx)
}

// Set the padding of a node (left, right, top, bottom)
node_set_padding :: proc(ctx: ^PluginContext, node: ^UINode, padding: [4]u16) {
	if node == nil do return
	node.style.padding = padding
	request_render(ctx)
}

// Set the gap between children
node_set_gap :: proc(ctx: ^PluginContext, node: ^UINode, gap: u16) {
	if node == nil do return
	node.style.gap = gap
	request_render(ctx)
}

// Set the layout direction (TopDown or LeftRight)
node_set_layout_dir :: proc(ctx: ^PluginContext, node: ^UINode, dir: LayoutDirection) {
	if node == nil do return
	node.style.layout_dir = dir
	request_render(ctx)
}

// Set clipping behavior for vertical and horizontal overflow
node_set_clip :: proc(ctx: ^PluginContext, node: ^UINode, vertical: bool, horizontal: bool) {
	if node == nil do return
	node.style.clip_vertical = vertical
	node.style.clip_horizontal = horizontal
	request_render(ctx)
}

// Set whether the node is hidden
node_set_hidden :: proc(ctx: ^PluginContext, node: ^UINode, hidden: bool) {
	if node == nil do return
	node.style.hidden = hidden
	request_render(ctx)
}

// Set the entire style at once (for bulk updates)
node_set_style :: proc(ctx: ^PluginContext, node: ^UINode, style: Style) {
	if node == nil do return
	node.style = style
	request_render(ctx)
}

// Content setters

// Set the text content of a text node
node_set_text :: proc(ctx: ^PluginContext, node: ^UINode, text: string) {
	if node == nil do return
	node.text_content = text
	request_render(ctx)
}

// Set the image path of an image node
node_set_image_path :: proc(ctx: ^PluginContext, node: ^UINode, path: string) {
	if node == nil do return
	node.image_path = path
	request_render(ctx)
}

// Behavior setters

// Set the click handler and callback context
node_set_on_click :: proc(
	ctx: ^PluginContext,
	node: ^UINode,
	callback: proc(ctx: rawptr),
	callback_ctx: rawptr,
) {
	if node == nil do return
	node.on_click = callback
	node.callback_ctx = callback_ctx
	// No render needed - behavior change only
}

// Set the cursor type when hovering
node_set_cursor :: proc(ctx: ^PluginContext, node: ^UINode, cursor: CursorType) {
	if node == nil do return
	node.cursor = cursor
	// No render needed - cursor is handled separately
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
