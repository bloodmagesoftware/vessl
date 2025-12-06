package ui

import "core:math/linalg"

ElementID :: distinct string

ElementType :: enum {
	Container,
	Text,
}

LayoutDirection :: enum {
	TopDown,
	LeftRight,
}

// Cursor types for UI elements
CursorType :: enum {
	Default, // Default arrow cursor
	Hand, // Hand/pointer cursor (for clickable items)
	Text, // Text selection cursor (I-beam)
	Resize, // Resize cursor
}

// Sizing with explicit units
SizingUnit :: enum {
	Pixels, // Fixed pixel value
	Percent, // Percentage (0.0-1.0 range, where 1.0 = 100%)
	Grow, // Grow to fill available space
	Fit, // Fit to content size
}

Sizing :: struct {
	unit:  SizingUnit,
	value: f32, // Only used for Pixels and Percent
}

// Helper functions for creating sizing values
sizing_px :: proc(pixels: int) -> Sizing {
	return Sizing{unit = .Pixels, value = f32(pixels)}
}

sizing_pct :: proc(percent: f32) -> Sizing {
	return Sizing{unit = .Percent, value = percent}
}

sizing_grow :: proc() -> Sizing {
	return Sizing{unit = .Grow, value = 0.0}
}

sizing_fit :: proc() -> Sizing {
	return Sizing{unit = .Fit, value = 0.0}
}

// Convenience constants
SIZE_FULL :: Sizing {
	unit  = .Percent,
	value = 1.0,
} // 100%

Style :: struct {
	width:           Sizing,
	height:          Sizing,
	color:           [4]f32,
	padding:         [4]u16,
	gap:             u16,
	layout_dir:      LayoutDirection,
	clip_vertical:   bool, // Enable vertical clipping (for scrollable containers)
	clip_horizontal: bool, // Enable horizontal clipping
}

UINode :: struct {
	id:           ElementID,
	type:         ElementType,
	parent:       ^UINode,
	children:     [dynamic]^UINode,
	style:        Style,

	// Content
	text_content: string, // If Type == Text

	// Behavior (Callbacks)
	on_click:     proc(ctx: rawptr),
	callback_ctx: rawptr, // Context to pass to on_click callback

	// Cursor
	cursor:       CursorType, // Cursor type when hovering over this element
}

// Component Registry ensures consistency
ComponentType :: enum {
	Button,
	Checkbox,
	Input,
	Label,
}

// Helper to create a new UINode
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
	}
	node.cursor = .Default // Default cursor
	return node
}

// Helper to add a child node
add_child :: proc(parent: ^UINode, child: ^UINode) {
	append(&parent.children, child)
	child.parent = parent
}

// Helper to remove a child node
remove_child :: proc(parent: ^UINode, child: ^UINode) {
	for child_node, i in parent.children {
		if child_node == child {
			ordered_remove(&parent.children, i)
			child.parent = nil
			return
		}
	}
}

// Helper to clear all children except the first N (useful for keeping text nodes)
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
