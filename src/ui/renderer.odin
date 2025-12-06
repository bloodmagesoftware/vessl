package ui

import clay "../../vendor/clay-odin"
import win "../core"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Cache entry for text objects
TextCacheEntry :: struct {
	node_id:      ElementID,
	text_content: string,
	text_obj:     ^ttf.Text,
	color:        [4]f32,
}

RendererContext :: struct {
	clay_ctx:      ^clay.Context,
	clay_arena:    clay.Arena,
	clay_memory:   []u8,
	root_node:     ^UINode,
	window_width:  f32,
	window_height: f32,
	window_ctx:    ^win.WindowContext, // SDL renderer for initial testing
	default_font:  ^ttf.Font, // TTF_Font*
	text_engine:   ^ttf.TextEngine, // SDL3 Text Engine
	font_size:     f32,
	font_loaded:   bool,
	text_cache:    [dynamic]TextCacheEntry, // Cache text objects to avoid recreating every frame
}

// Clay text measurement function (required by Clay)
measure_text_callback :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	ctx := cast(^RendererContext)userData
	if ctx == nil || ctx.default_font == nil {
		// Fallback: estimate based on character count
		return {
			width  = f32(text.length) * f32(config.fontSize) * 0.6, // Approximate character width
			height = f32(config.fontSize),
		}
	}

	// Convert StringSlice to Odin string for measurement
	text_str := string(text.chars[:text.length])

	// Use SDL3 Text Engine to measure text
	if ctx.text_engine != nil {
		context = runtime.default_context()
		text_cstr := strings.clone_to_cstring(text_str)
		defer delete(text_cstr)

		// Create temporary text object to measure
		temp_text := ttf.CreateText(ctx.text_engine, ctx.default_font, text_cstr, 0)
		if temp_text != nil {
			w, h: i32
			ttf.GetTextSize(temp_text, &w, &h)
			ttf.DestroyText(temp_text)
			return {width = f32(w), height = f32(h)}
		}
	}

	// Fallback estimation
	return {width = f32(text.length) * f32(config.fontSize) * 0.6, height = f32(config.fontSize)}
}

// Clay error handler
clay_error_handler :: proc "c" (errorData: clay.ErrorData) {
	context = runtime.default_context()
	fmt.eprintf("Clay Error: %v\n", errorData.errorType)
}

// Initialize renderer with official Clay API
init_renderer :: proc(
	window_ctx: ^win.WindowContext,
	width: f32,
	height: f32,
	allocator := context.allocator,
) -> ^RendererContext {
	ctx := new(RendererContext, allocator)
	ctx.window_width = width
	ctx.window_height = height
	ctx.root_node = nil
	ctx.window_ctx = window_ctx
	ctx.font_loaded = false
	ctx.font_size = 32.0 // Default font size (larger for readability)
	ctx.text_cache = {}

	// Initialize SDL_ttf
	if !ttf.Init() {
		fmt.eprintf("TTF_Init failed: %s\n", sdl.GetError())
		init_bitmap_font()
		fmt.eprintln("Using bitmap font fallback")
	} else {
		// Create Text Engine (SDL3 way)
		ctx.text_engine = ttf.CreateRendererTextEngine(window_ctx.renderer)
		if ctx.text_engine == nil {
			fmt.eprintf("Failed to create text engine: %s\n", sdl.GetError())
			init_bitmap_font()
			fmt.eprintln("Using bitmap font fallback")
		} else {
			// Try to load TTF font
			font, ok := load_default_font()
			if ok {
				ctx.default_font = font
				ctx.font_loaded = true
			} else {
				// Fallback to bitmap font if TTF loading fails
				init_bitmap_font()
				fmt.eprintln("Using bitmap font fallback")
			}
		}
	}

	// Initialize Clay
	min_memory_size := clay.MinMemorySize()
	ctx.clay_memory = make([]u8, min_memory_size, allocator)
	ctx.clay_arena = clay.CreateArenaWithCapacityAndMemory(
		c.size_t(min_memory_size),
		raw_data(ctx.clay_memory),
	)

	error_handler := clay.ErrorHandler {
		handler  = clay_error_handler,
		userData = nil,
	}

	ctx.clay_ctx = clay.Initialize(ctx.clay_arena, {width = width, height = height}, error_handler)
	if ctx.clay_ctx == nil {
		fmt.eprintln("Failed to initialize Clay context")
		return ctx
	}

	// Set current context
	clay.SetCurrentContext(ctx.clay_ctx)

	// Set text measurement function
	clay.SetMeasureTextFunction(measure_text_callback, ctx)

	return ctx
}

// Load TTF font from assets/fonts/ directory
load_font :: proc(font_path: string, size: f32) -> (font: ^ttf.Font, ok: bool) {
	// Try to load the font
	font_cstr := strings.clone_to_cstring(font_path)
	defer delete(font_cstr)

	font = ttf.OpenFont(font_cstr, size)

	if font == nil {
		fmt.eprintf("Failed to load font '%s': %s\n", font_path, sdl.GetError())
		return nil, false
	}

	fmt.printf("Successfully loaded font '%s' at size %.0f\n", font_path, size)
	return font, true
}

// Try to load a font from assets/fonts/
load_default_font :: proc() -> (font: ^ttf.Font, ok: bool) {
	// Try fonts in order of preference
	font_paths := []string {
		"assets/fonts/JetBrainsMono[wght].ttf",
		"assets/fonts/Roboto-VariableFont_wdth,wght.ttf",
		"assets/fonts/JetBrainsMono-Italic[wght].ttf",
		"assets/fonts/Roboto-Italic-VariableFont_wdth,wght.ttf",
	}

	// Default font size (32 points for better readability)
	default_size: f32 = 32.0

	fmt.printf("Attempting to load TTF font...\n")

	for path in font_paths {
		// Check if file exists
		if os.exists(path) {
			fmt.printf("Found font file: %s\n", path)
			font, ok := load_font(path, default_size)
			if ok {
				fmt.printf("Successfully loaded font: %s\n", path)
				return font, true
			} else {
				fmt.eprintf("Failed to load font: %s\n", path)
			}
		} else {
			fmt.eprintf("Font file not found: %s\n", path)
		}
	}

	fmt.eprintln("Warning: No font found in assets/fonts/, text rendering may not work")
	fmt.eprintln("Current working directory:", os.get_current_directory())
	return nil, false
}

// Set the root UI node
set_root_node :: proc(ctx: ^RendererContext, root: ^UINode) {
	ctx.root_node = root
}

// Update renderer size (call this when window is resized)
update_renderer_size :: proc(ctx: ^RendererContext, width: f32, height: f32) {
	if ctx == nil do return
	ctx.window_width = width
	ctx.window_height = height
	// Update Clay layout dimensions
	if ctx.clay_ctx != nil {
		clay.SetCurrentContext(ctx.clay_ctx)
		clay.SetLayoutDimensions({width = width, height = height})
	}
}

// Update Clay pointer state (call this before BeginLayout for hit testing)
update_pointer_state :: proc(ctx: ^RendererContext, x: f32, y: f32, pointer_down: bool) {
	if ctx == nil || ctx.clay_ctx == nil do return

	clay.SetCurrentContext(ctx.clay_ctx)
	clay.SetPointerState({x, y}, pointer_down)
}

// Find clicked node using Clay's PointerOver API (call after layout)
find_clicked_node_clay :: proc(ctx: ^RendererContext, root: ^UINode) -> ^UINode {
	if ctx == nil || root == nil || ctx.clay_ctx == nil do return nil

	clay.SetCurrentContext(ctx.clay_ctx)

	// Recursively check all nodes
	return find_clicked_node_recursive(ctx, root)
}

// Recursive helper to find clicked node
// Prioritizes nodes with click callbacks, and prefers children over parents
find_clicked_node_recursive :: proc(ctx: ^RendererContext, node: ^UINode) -> ^UINode {
	if node == nil do return nil

	// Convert node ID to Clay ElementId
	node_id_str := string(node.id)
	clay_id := clay.GetElementId(clay.MakeString(node_id_str))

	// Check if pointer is over this element
	if clay.PointerOver(clay_id) {
		// Check children first (they're on top and more specific)
		for child in node.children {
			if result := find_clicked_node_recursive(ctx, child); result != nil {
				// Prefer child if it has a click callback
				if result.on_click != nil {
					return result
				}
			}
		}

		// If this node has a click callback, return it
		if node.on_click != nil {
			return node
		}

		// Otherwise, check if any child was clicked (even without callback)
		// This allows clicking on text to trigger parent callbacks
		for child in node.children {
			if result := find_clicked_node_recursive(ctx, child); result != nil {
				return result
			}
		}
	}

	// Check children even if pointer not over this node (for nested elements)
	for child in node.children {
		if result := find_clicked_node_recursive(ctx, child); result != nil {
			return result
		}
	}

	return nil
}

// Render the UI tree using Clay's declarative API
// check_click: if true, check for clicked nodes and trigger callbacks
// Returns: (hovered_cursor: CursorType) - the cursor type of the currently hovered node
render_frame :: proc(
	ctx: ^RendererContext,
	check_click: bool = false,
) -> (
	hovered_cursor: CursorType,
) {
	if ctx.root_node == nil do return .Default
	if ctx.window_ctx == nil do return .Default
	if ctx.clay_ctx == nil do return .Default

	// Set current Clay context
	clay.SetCurrentContext(ctx.clay_ctx)
	clay.SetLayoutDimensions({width = ctx.window_width, height = ctx.window_height})

	// Begin Clay layout
	clay.BeginLayout()

	// Convert UINode tree to Clay UI() calls (first pass - layout)
	build_clay_ui(ctx, ctx.root_node, check_hover = false)

	// End layout and get render commands
	render_commands_temp := clay.EndLayout()
	render_commands := &render_commands_temp

	// Find the cursor type of the hovered node (after layout is complete)
	hovered_cursor = find_hovered_cursor(ctx, ctx.root_node)

	// Rebuild UI with hover colors (second pass)
	// This is a bit inefficient but ensures hover colors are correct
	clay.BeginLayout()
	build_clay_ui(ctx, ctx.root_node, check_hover = true)
	render_commands_temp_hover := clay.EndLayout()
	render_commands = &render_commands_temp_hover

	// Check for clicked node after layout (only if requested)
	// Pointer state should be set before BeginLayout with pointer_down=true
	// We check for clicks when check_click is true (button was just pressed)
	if check_click {
		clicked_node := find_clicked_node_clay(ctx, ctx.root_node)
		if clicked_node != nil && clicked_node.on_click != nil {
			clicked_node.on_click(clicked_node.callback_ctx)
		}
	}

	// Process render commands and draw with SDL
	process_render_commands(ctx, render_commands)

	return hovered_cursor
}

// Check if any clickable node is currently hovered (for cursor management)
check_hovered_clickable :: proc(ctx: ^RendererContext, node: ^UINode) -> bool {
	if node == nil do return false

	// Check if this node is clickable and hovered
	if node.on_click != nil {
		node_id_str := string(node.id)
		clay_id := clay.GetElementId(clay.MakeString(node_id_str))
		if clay.PointerOver(clay_id) {
			return true
		}
	}

	// Check children
	for child in node.children {
		if check_hovered_clickable(ctx, child) {
			return true
		}
	}

	return false
}

// Find the hovered node and return its cursor type
// Returns the cursor type of the topmost hovered node (prefers children over parents)
find_hovered_cursor :: proc(ctx: ^RendererContext, node: ^UINode) -> CursorType {
	if node == nil || ctx == nil || ctx.clay_ctx == nil do return .Default

	clay.SetCurrentContext(ctx.clay_ctx)

	// Check children first (they're on top)
	for child in node.children {
		if cursor := find_hovered_cursor(ctx, child); cursor != .Default {
			return cursor
		}
	}

	// Check if this node is hovered
	node_id_str := string(node.id)
	clay_id := clay.GetElementId(clay.MakeString(node_id_str))
	if clay.PointerOver(clay_id) {
		// Return this node's cursor type
		return node.cursor
	}

	return .Default
}

// Convert UINode Sizing to Clay Sizing
convert_sizing :: proc(sizing: Sizing) -> clay.SizingAxis {
	switch sizing.unit {
	case .Pixels:
		return clay.SizingFixed(sizing.value)
	case .Percent:
		return clay.SizingPercent(sizing.value)
	case .Grow:
		return clay.SizingGrow({})
	case .Fit:
		return clay.SizingFit({})
	}
	// Default: grow to fill
	return clay.SizingGrow({})
}

// Convert UINode to Clay UI() call
// check_hover: if true, check hover state and adjust colors (must be called after layout)
build_clay_ui :: proc(ctx: ^RendererContext, node: ^UINode, check_hover: bool = false) {
	if node == nil do return

	// Convert layout direction
	layout_dir: clay.LayoutDirection = .TopToBottom
	switch node.style.layout_dir {
	case .TopDown:
		layout_dir = .TopToBottom
	case .LeftRight:
		layout_dir = .LeftToRight
	}

	// Convert padding
	padding := clay.Padding {
		left   = node.style.padding[0],
		right  = node.style.padding[2],
		top    = node.style.padding[1],
		bottom = node.style.padding[3],
	}

	// Convert sizing
	width_sizing := convert_sizing(node.style.width)
	height_sizing := convert_sizing(node.style.height)

	// Convert color (UINode uses [0,1], Clay uses [0,1] so it's compatible)
	bg_color := clay.Color {
		node.style.color[0],
		node.style.color[1],
		node.style.color[2],
		node.style.color[3],
	}

	// Check if this node is hovered (for hover effects) - only after layout
	if check_hover && node.on_click != nil && node.type == .Container {
		node_id_str := string(node.id)
		clay_id := clay.GetElementId(clay.MakeString(node_id_str))
		if clay.PointerOver(clay_id) {
			// If hovered, lighten the background color
			bg_color[0] = min(bg_color[0] + 0.05, 1.0) // Increase red
			bg_color[1] = min(bg_color[1] + 0.05, 1.0) // Increase green
			bg_color[2] = min(bg_color[2] + 0.05, 1.0) // Increase blue
		}
	}

	switch node.type {
	case .Container:
		// Create container element
		clip_config := clay.ClipElementConfig {
			horizontal  = node.style.clip_horizontal,
			vertical    = node.style.clip_vertical,
			childOffset = {0, 0}, // Scroll offset (can be updated for scrolling)
		}

		element_config := clay.ElementDeclaration {
			layout = {
				sizing = {width = width_sizing, height = height_sizing},
				padding = padding,
				childGap = node.style.gap,
				layoutDirection = layout_dir,
				childAlignment = {x = .Left, y = .Top},
			},
			backgroundColor = bg_color,
			clip = clip_config,
		}

		// Use node ID string for Clay ID
		node_id_str := string(node.id)
		if clay.UI(clay.ID(node_id_str))(element_config) {
			// Render children
			for child in node.children {
				build_clay_ui(ctx, child, check_hover)
			}
		}

	case .Text:
		// Create text element
		// Set line height to match font size for proper spacing
		line_height := u16(ctx.font_size * 1.2) // 20% extra for line spacing
		text_config := clay.TextConfig(
			{
				textColor = bg_color,
				fontSize = u16(ctx.font_size),
				lineHeight = line_height,
				wrapMode = .None,
				textAlignment = .Left,
			},
		)

		// Text elements need a container parent, so we create one
		container_config := clay.ElementDeclaration {
			layout = {
				sizing = {width = width_sizing, height = height_sizing},
				padding = padding,
				layoutDirection = .TopToBottom,
			},
			backgroundColor = {0, 0, 0, 0}, // Transparent
		}

		node_id_str := string(node.id)
		if clay.UI(clay.ID(node_id_str))(container_config) {
			// Use TextDynamic for runtime strings
			clay.TextDynamic(node.text_content, text_config)
		}
	}
}

// Process Clay render commands and draw with SDL
process_render_commands :: proc(
	ctx: ^RendererContext,
	commands: ^clay.ClayArray(clay.RenderCommand),
) {
	if ctx.window_ctx == nil || ctx.window_ctx.renderer == nil do return
	if commands == nil do return

	for i in 0 ..< i32(commands.length) {
		cmd := clay.RenderCommandArray_Get(commands, i)
		if cmd == nil do continue

		#partial switch cmd.commandType {
		case .Rectangle:
			// Draw rectangle
			box := cmd.boundingBox
			rect_data := cmd.renderData.rectangle

			// Convert color from [0,1] to [0,255]
			r := u8(rect_data.backgroundColor[0] * 255)
			g := u8(rect_data.backgroundColor[1] * 255)
			b := u8(rect_data.backgroundColor[2] * 255)
			a := u8(rect_data.backgroundColor[3] * 255)

			sdl.SetRenderDrawColor(ctx.window_ctx.renderer, r, g, b, a)

			// Draw rectangle (handle corner radius if needed)
			if rect_data.cornerRadius.topLeft == 0 &&
			   rect_data.cornerRadius.topRight == 0 &&
			   rect_data.cornerRadius.bottomLeft == 0 &&
			   rect_data.cornerRadius.bottomRight == 0 {
				// Simple rectangle
				sdl_rect := sdl.FRect{box.x, box.y, box.width, box.height}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &sdl_rect)
			} else {
				// TODO: Handle rounded rectangles (would need custom drawing)
				// For now, draw as regular rectangle
				sdl_rect := sdl.FRect{box.x, box.y, box.width, box.height}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &sdl_rect)
			}

		case .Text:
			// Render text using SDL3 Text Engine
			box := cmd.boundingBox
			text_data := cmd.renderData.text

			if ctx.default_font != nil && ctx.text_engine != nil {
				// Convert StringSlice to Odin string
				text_str := string(
					text_data.stringContents.chars[:text_data.stringContents.length],
				)

				// Convert color
				r := u8(text_data.textColor[0] * 255)
				g := u8(text_data.textColor[1] * 255)
				b := u8(text_data.textColor[2] * 255)
				a := u8(text_data.textColor[3] * 255)

				// Create or get cached text object
				text_cstr := strings.clone_to_cstring(text_str)
				defer delete(text_cstr)

				text_obj := ttf.CreateText(ctx.text_engine, ctx.default_font, text_cstr, 0)
				if text_obj != nil {
					ttf.SetTextColor(text_obj, r, g, b, a)
					// Position text in the bounding box (top-left for now)
					ttf.DrawRendererText(text_obj, box.x, box.y)
					ttf.DestroyText(text_obj)
				}
			} else {
				// Fallback to bitmap font
				text_str := string(
					text_data.stringContents.chars[:text_data.stringContents.length],
				)
				draw_text_bitmap(
					ctx,
					box.x,
					box.y,
					box.width,
					box.height,
					text_str,
					text_data.textColor,
				)
			}

		case .Border:
			// Draw border
			box := cmd.boundingBox
			border_data := cmd.renderData.border

			r := u8(border_data.color[0] * 255)
			g := u8(border_data.color[1] * 255)
			b := u8(border_data.color[2] * 255)
			a := u8(border_data.color[3] * 255)

			sdl.SetRenderDrawColor(ctx.window_ctx.renderer, r, g, b, a)

			// Draw border lines (simplified - draw all sides)
			if border_data.width.top > 0 {
				top_rect := sdl.FRect{box.x, box.y, box.width, f32(border_data.width.top)}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &top_rect)
			}
			if border_data.width.bottom > 0 {
				bottom_rect := sdl.FRect {
					box.x,
					box.y + box.height - f32(border_data.width.bottom),
					box.width,
					f32(border_data.width.bottom),
				}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &bottom_rect)
			}
			if border_data.width.left > 0 {
				left_rect := sdl.FRect{box.x, box.y, f32(border_data.width.left), box.height}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &left_rect)
			}
			if border_data.width.right > 0 {
				right_rect := sdl.FRect {
					box.x + box.width - f32(border_data.width.right),
					box.y,
					f32(border_data.width.right),
					box.height,
				}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &right_rect)
			}

		case .None, .Image, .ScissorStart, .ScissorEnd, .Custom:
		// Unhandled command types - skip for now
		}
	}
}

// Simple bitmap font data for ASCII characters (8x8 pixels)
// This is a minimal font that can display basic ASCII text
bitmap_font_data: [128][8]u8

init_bitmap_font :: proc() {
	// Initialize all characters to empty (space)
	for i in 0 ..< 128 {
		bitmap_font_data[i] = {0, 0, 0, 0, 0, 0, 0, 0}
	}

	// Space (32) - already empty
	// Numbers 0-9 (48-57)
	bitmap_font_data[48] = {0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00} // 0
	bitmap_font_data[49] = {0x18, 0x18, 0x38, 0x18, 0x18, 0x18, 0x7E, 0x00} // 1
	bitmap_font_data[50] = {0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00} // 2
	bitmap_font_data[51] = {0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00} // 3
	bitmap_font_data[52] = {0x06, 0x0E, 0x1E, 0x66, 0x7F, 0x06, 0x06, 0x00} // 4
	bitmap_font_data[53] = {0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00} // 5
	bitmap_font_data[54] = {0x3C, 0x66, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00} // 6
	bitmap_font_data[55] = {0x7E, 0x66, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00} // 7
	bitmap_font_data[56] = {0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00} // 8
	bitmap_font_data[57] = {0x3C, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00} // 9
	// Letters A-Z (65-90) - simplified
	bitmap_font_data[65] = {0x18, 0x3C, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00} // A
	bitmap_font_data[66] = {0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00} // B
	bitmap_font_data[67] = {0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00} // C
	bitmap_font_data[68] = {0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00} // D
	bitmap_font_data[69] = {0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00} // E
	bitmap_font_data[72] = {0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00} // H
	bitmap_font_data[76] = {0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00} // L
	bitmap_font_data[79] = {0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00} // O
	bitmap_font_data[82] = {0x7C, 0x66, 0x66, 0x7C, 0x78, 0x6C, 0x66, 0x00} // R
	bitmap_font_data[84] = {0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00} // T
	// Common punctuation
	bitmap_font_data[33] = {0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00} // !
	bitmap_font_data[44] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30} // ,
	bitmap_font_data[46] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00} // .
	bitmap_font_data[58] = {0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00} // :
}

// Draw a single character using bitmap font
draw_char :: proc(ctx: ^RendererContext, x: f32, y: f32, char: u8, color: [4]f32) {
	if ctx.window_ctx == nil || ctx.window_ctx.renderer == nil do return

	// Convert color from [0,1] to [0,255]
	r := u8(color[0] * 255)
	g := u8(color[1] * 255)
	b := u8(color[2] * 255)
	a := u8(color[3] * 255)

	sdl.SetRenderDrawColor(ctx.window_ctx.renderer, r, g, b, a)

	// Get character bitmap (use space if not found)
	char_idx := int(char) if char < 128 else 32
	glyph := bitmap_font_data[char_idx]

	// Draw 8x8 bitmap
	for row in 0 ..< 8 {
		for col in 0 ..< 8 {
			shift_amount := u32(7 - u32(col))
			if (glyph[row] & (1 << shift_amount)) != 0 {
				pixel_x := x + f32(col)
				pixel_y := y + f32(row)
				pixel_rect := sdl.FRect{pixel_x, pixel_y, 1, 1}
				sdl.RenderFillRect(ctx.window_ctx.renderer, &pixel_rect)
			}
		}
	}
}

// Draw text using TTF font or bitmap font fallback (deprecated - use draw_text_ttf directly)
// Kept for compatibility
draw_text :: proc(
	ctx: ^RendererContext,
	x: f32,
	y: f32,
	w: f32,
	h: f32,
	text: string,
	color: [4]f32,
) {
	if ctx.window_ctx == nil || ctx.window_ctx.renderer == nil do return
	if len(text) == 0 do return

	// Use bitmap font fallback
	draw_text_bitmap(ctx, x, y, w, h, text, color)
}

// Draw text using TTF font (SDL3 Text Engine API)
// Uses caching to avoid recreating text objects every frame
draw_text_ttf :: proc(
	ctx: ^RendererContext,
	node: ^UINode,
	x: f32,
	y: f32,
	w: f32,
	h: f32,
	text: string,
	color: [4]f32,
) {
	if ctx.default_font == nil do return
	if ctx.text_engine == nil do return
	if ctx.window_ctx == nil || ctx.window_ctx.renderer == nil do return
	if len(text) == 0 do return
	if node == nil do return

	// Convert color from [0,1] to [0,255]
	r := u8(color[0] * 255)
	g := u8(color[1] * 255)
	b := u8(color[2] * 255)
	a := u8(color[3] * 255)

	// Check cache for existing text object
	text_obj: ^ttf.Text = nil
	cache_idx := -1

	// Check cache for existing text object
	// Compare by node ID and string content (not pointer)
	for entry, i in ctx.text_cache {
		if entry.node_id == node.id {
			// Compare string content, not pointers
			if entry.text_content == text {
				// Check if color changed
				if entry.color == color {
					text_obj = entry.text_obj
					cache_idx = i
					break
				} else {
					// Color changed, destroy old object and remove from cache
					ttf.DestroyText(entry.text_obj)
					ordered_remove(&ctx.text_cache, i)
					break
				}
			} else {
				// Text content changed for this node, destroy old object
				ttf.DestroyText(entry.text_obj)
				delete(entry.text_content) // Free the old cached string
				ordered_remove(&ctx.text_cache, i)
				break
			}
		}
	}

	// Create new text object if not cached
	if text_obj == nil {
		text_cstr := strings.clone_to_cstring(text)
		defer delete(text_cstr)

		text_obj = ttf.CreateText(ctx.text_engine, ctx.default_font, text_cstr, 0)
		if text_obj == nil {
			fmt.eprintf("Failed to create text object: %s\n", sdl.GetError())
			return
		}

		// Add to cache - clone the text string to ensure it has its own memory
		entry := TextCacheEntry {
			node_id      = node.id,
			text_content = strings.clone(text), // Clone to ensure persistent memory
			text_obj     = text_obj,
			color        = color,
		}
		append(&ctx.text_cache, entry)
	}

	// Set text color (in case it changed)
	ttf.SetTextColor(text_obj, r, g, b, a)

	// Calculate position (centered vertically)
	render_x := x
	render_y := y + (h - ctx.font_size) / 2

	// Draw the text directly using SDL3 Text Engine
	ttf.DrawRendererText(text_obj, render_x, render_y)
}

// Draw text using bitmap font (fallback)
draw_text_bitmap :: proc(
	ctx: ^RendererContext,
	x: f32,
	y: f32,
	w: f32,
	h: f32,
	text: string,
	color: [4]f32,
) {
	// Character size (8x8 pixels)
	char_w := f32(8)
	char_h := f32(8)

	// Calculate starting position (centered vertically)
	start_y := y + (h - char_h) / 2

	// Draw each character
	for i in 0 ..< len(text) {
		char_x := x + char_w * f32(i)
		if char_x + char_w > x + w do break

		// Convert rune to byte (simple ASCII handling)
		char := u8(text[i])
		draw_char(ctx, char_x, start_y, char, color)
	}
}

// Cleanup renderer
destroy_renderer :: proc(ctx: ^RendererContext) {
	if ctx == nil do return

	// Cleanup text cache
	for entry in ctx.text_cache {
		if entry.text_obj != nil {
			ttf.DestroyText(entry.text_obj)
		}
		// Free the cloned string
		delete(entry.text_content)
	}
	delete(ctx.text_cache)

	// Cleanup Text Engine
	if ctx.text_engine != nil {
		ttf.DestroyRendererTextEngine(ctx.text_engine)
		ctx.text_engine = nil
	}

	// Cleanup TTF font
	if ctx.default_font != nil {
		ttf.CloseFont(ctx.default_font)
	}

	// Cleanup Clay memory
	if ctx.clay_memory != nil {
		delete(ctx.clay_memory)
	}

	// Clay context doesn't need explicit cleanup (it's just a pointer to arena data)
	ctx.clay_ctx = nil

	free(ctx)
}
