package ui

import clay "../../vendor/clay-odin"
import api "../api"
import win "../core"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"
import ttf "vendor:sdl3/ttf"

// Cache entry for text objects
TextCacheEntry :: struct {
	node_id:      api.ElementID,
	text_content: string,
	text_obj:     ^ttf.Text,
	color:        [4]f32,
}

// Cache entry for images (maps file path to SDL texture)
ImageCacheEntry :: struct {
	path:    string,
	texture: ^sdl.Texture,
	width:   i32,
	height:  i32,
}

RendererContext :: struct {
	clay_ctx:       ^clay.Context,
	clay_arena:     clay.Arena,
	clay_memory:    []u8,
	root_node:      ^api.UINode,
	window_width:   f32,
	window_height:  f32,
	window_ctx:     ^win.WindowContext, // SDL renderer for initial testing
	default_font:   ^ttf.Font, // TTF_Font*
	text_engine:    ^ttf.TextEngine, // SDL3 Text Engine
	font_size:      f32,
	font_loaded:    bool,
	text_cache:     [dynamic]TextCacheEntry, // Cache text objects to avoid recreating every frame
	image_cache:    map[string]ImageCacheEntry, // Cache loaded image textures
	// Scroll state - accumulated between frames, consumed in render_frame
	scroll_delta_x: f32,
	scroll_delta_y: f32,
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
	ctx.image_cache = {}

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

// Load TTF font from memory (embedded data)
load_font_from_memory :: proc(data: []u8, size: f32) -> (font: ^ttf.Font, ok: bool) {
	if len(data) == 0 {
		fmt.eprintln("Error: Empty font data")
		return nil, false
	}

	// Create an IOStream from memory
	io_stream := sdl.IOFromConstMem(raw_data(data), c.size_t(len(data)))
	if io_stream == nil {
		fmt.eprintf("Failed to create IOStream from font data: %s\n", sdl.GetError())
		return nil, false
	}

	// Load font from IOStream
	// closeio = true means SDL will close the stream when the font is closed
	font = ttf.OpenFontIO(io_stream, true, size)
	if font == nil {
		fmt.eprintf("Failed to load font from memory: %s\n", sdl.GetError())
		// If font loading failed, we need to close the stream manually
		sdl.CloseIO(io_stream)
		return nil, false
	}

	fmt.printf("Successfully loaded embedded font at size %.0f\n", size)
	return font, true
}

// Load TTF font from file path (fallback for external fonts)
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

// Try to load a font from embedded data (primary) or filesystem (fallback)
load_default_font :: proc() -> (font: ^ttf.Font, ok: bool) {
	// Default font size (32 points for better readability)
	default_size: f32 = 32.0

	fmt.printf("Attempting to load embedded TTF font...\n")

	// Try embedded fonts in order of preference
	EmbeddedFont :: struct {
		name: string,
		data: []u8,
	}

	embedded_fonts := []EmbeddedFont {
		{"JetBrains Mono", FONT_JETBRAINS_MONO[:]},
		{"Roboto", FONT_ROBOTO[:]},
		{"JetBrains Mono Italic", FONT_JETBRAINS_MONO_ITALIC[:]},
		{"Roboto Italic", FONT_ROBOTO_ITALIC[:]},
	}

	for ef in embedded_fonts {
		fmt.printf("Trying embedded font: %s\n", ef.name)
		font, ok := load_font_from_memory(ef.data, default_size)
		if ok {
			fmt.printf("Successfully loaded embedded font: %s\n", ef.name)
			return font, true
		} else {
			fmt.eprintf("Failed to load embedded font: %s\n", ef.name)
		}
	}

	fmt.eprintln("Warning: No embedded font could be loaded, text rendering may not work")
	return nil, false
}

// Set the root UI node
set_root_node :: proc(ctx: ^RendererContext, root: ^api.UINode) {
	ctx.root_node = root
}

// Load an image from file path into a texture (cached)
// Returns the cached entry or loads the image if not cached
load_image_texture :: proc(
	ctx: ^RendererContext,
	path: string,
) -> (
	entry: ImageCacheEntry,
	ok: bool,
) {
	if ctx == nil || ctx.window_ctx == nil || ctx.window_ctx.renderer == nil {
		return {}, false
	}

	// Check cache first
	if cached, found := ctx.image_cache[path]; found {
		return cached, true
	}

	// Load image using SDL_image (supports PNG, JPEG, BMP, GIF, etc.)
	path_cstr := strings.clone_to_cstring(path)
	defer delete(path_cstr)

	// Load the surface from file using SDL_image
	surface := img.Load(path_cstr)
	if surface == nil {
		fmt.eprintf("[renderer] Failed to load image '%s': %s\n", path, sdl.GetError())
		return {}, false
	}
	defer sdl.DestroySurface(surface)

	// Get image dimensions
	img_width := surface.w
	img_height := surface.h

	// Create texture from surface
	texture := sdl.CreateTextureFromSurface(ctx.window_ctx.renderer, surface)
	if texture == nil {
		fmt.eprintf("[renderer] Failed to create texture for '%s': %s\n", path, sdl.GetError())
		return {}, false
	}

	// Cache the entry
	cache_entry := ImageCacheEntry {
		path    = strings.clone(path),
		texture = texture,
		width   = img_width,
		height  = img_height,
	}
	ctx.image_cache[path] = cache_entry

	fmt.printf("[renderer] Loaded image '%s' (%dx%d)\n", path, img_width, img_height)
	return cache_entry, true
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

// Accumulate scroll delta (call when mouse wheel event occurs)
// The delta will be consumed in render_frame before BeginLayout
accumulate_scroll_delta :: proc(ctx: ^RendererContext, scroll_delta_x: f32, scroll_delta_y: f32) {
	if ctx == nil do return
	ctx.scroll_delta_x += scroll_delta_x
	ctx.scroll_delta_y += scroll_delta_y
}

// Find clicked node using Clay's PointerOver API (call after layout)
find_clicked_node_clay :: proc(ctx: ^RendererContext, root: ^api.UINode) -> ^api.UINode {
	if ctx == nil || root == nil || ctx.clay_ctx == nil do return nil

	clay.SetCurrentContext(ctx.clay_ctx)

	// Recursively check all nodes
	return find_clicked_node_recursive(ctx, root)
}

// Recursive helper to find clicked node
// Prioritizes nodes with click callbacks, and prefers children over parents
find_clicked_node_recursive :: proc(ctx: ^RendererContext, node: ^api.UINode) -> ^api.UINode {
	if node == nil do return nil

	// Skip hidden nodes
	if node.style.hidden do return nil

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
// dt: delta time in seconds for scroll momentum
// Returns: (hovered_cursor: api.CursorType) - the cursor type of the currently hovered node
render_frame :: proc(
	ctx: ^RendererContext,
	check_click: bool = false,
	dt: f32 = 0.016,
) -> (
	hovered_cursor: api.CursorType,
) {
	if ctx.root_node == nil do return .Default
	if ctx.window_ctx == nil do return .Default
	if ctx.clay_ctx == nil do return .Default

	// Set current Clay context
	clay.SetCurrentContext(ctx.clay_ctx)

	// Update scroll containers BEFORE BeginLayout (required for Clay scrolling)
	// Clay tracks scroll positions internally and handles momentum/inertia
	clay.UpdateScrollContainers(true, {ctx.scroll_delta_x, ctx.scroll_delta_y}, dt)
	ctx.scroll_delta_x = 0
	ctx.scroll_delta_y = 0

	clay.SetLayoutDimensions({width = ctx.window_width, height = ctx.window_height})

	// Begin Clay layout
	clay.BeginLayout()

	// Convert UINode tree to Clay UI() calls with hover checking
	build_clay_ui(ctx, ctx.root_node, check_hover = true)

	// End layout and get render commands
	render_commands_temp := clay.EndLayout()
	render_commands := &render_commands_temp

	// Find the cursor type of the hovered node (after layout is complete)
	hovered_cursor = find_hovered_cursor(ctx, ctx.root_node)

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
check_hovered_clickable :: proc(ctx: ^RendererContext, node: ^api.UINode) -> bool {
	if node == nil do return false

	// Skip hidden nodes
	if node.style.hidden do return false

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
find_hovered_cursor :: proc(ctx: ^RendererContext, node: ^api.UINode) -> api.CursorType {
	if node == nil || ctx == nil || ctx.clay_ctx == nil do return .Default

	// Skip hidden nodes
	if node.style.hidden do return .Default

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

// Find the hovered element ID
// Returns the ElementID of the topmost hovered node (prefers children over parents)
// Returns empty ElementID if no element is hovered
find_hovered_element_id :: proc(ctx: ^RendererContext) -> api.ElementID {
	if ctx == nil || ctx.clay_ctx == nil || ctx.root_node == nil do return api.ElementID("")

	clay.SetCurrentContext(ctx.clay_ctx)
	return find_hovered_element_id_recursive(ctx, ctx.root_node)
}

// Recursive helper to find hovered element ID
find_hovered_element_id_recursive :: proc(
	ctx: ^RendererContext,
	node: ^api.UINode,
) -> api.ElementID {
	if node == nil do return api.ElementID("")

	// Skip hidden nodes
	if node.style.hidden do return api.ElementID("")

	// Check children first (they're on top)
	for child in node.children {
		if id := find_hovered_element_id_recursive(ctx, child); id != api.ElementID("") {
			return id
		}
	}

	// Check if this node is hovered
	node_id_str := string(node.id)
	clay_id := clay.GetElementId(clay.MakeString(node_id_str))
	if clay.PointerOver(clay_id) {
		return node.id
	}

	return api.ElementID("")
}

// Convert UINode Sizing to Clay Sizing
convert_sizing :: proc(sizing: api.Sizing) -> clay.SizingAxis {
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
build_clay_ui :: proc(ctx: ^RendererContext, node: ^api.UINode, check_hover: bool = false) {
	if node == nil do return

	// Skip hidden nodes and their children
	if node.style.hidden do return

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
		node_id_str := string(node.id)
		clay_id := clay.ID(node_id_str)

		// Get scroll offset from Clay if this is a scrollable container
		// Clay tracks scroll position internally; we apply it via childOffset
		child_offset := clay.Vector2{0, 0}
		if node.style.clip_vertical || node.style.clip_horizontal {
			scroll_data := clay.GetScrollContainerData(clay_id)
			if scroll_data.found && scroll_data.scrollPosition != nil {
				child_offset = scroll_data.scrollPosition^
			}
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
			clip = {
				horizontal = node.style.clip_horizontal,
				vertical = node.style.clip_vertical,
				childOffset = child_offset,
			},
		}

		if clay.UI(clay_id)(element_config) {
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

	case .Image:
		// Create image element
		// Pass the image path pointer as imageData for the render command to use
		image_config := clay.ElementDeclaration {
			layout = {
				sizing = {width = width_sizing, height = height_sizing},
				padding = padding,
				layoutDirection = layout_dir,
			},
			backgroundColor = bg_color,
			image = {
				imageData = rawptr(&node.image_path), // Pass pointer to image path
			},
		}

		node_id_str := string(node.id)
		if clay.UI(clay.ID(node_id_str))(image_config) {
			// Images have no children
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

		case .Image:
			// Render image using cached texture
			box := cmd.boundingBox
			image_data := cmd.renderData.image

			// imageData contains a pointer to the image path string
			if image_data.imageData != nil {
				path_ptr := cast(^string)image_data.imageData
				if path_ptr != nil && len(path_ptr^) > 0 {
					// Load or get cached texture
					if entry, ok := load_image_texture(ctx, path_ptr^); ok {
						// Calculate destination rect (fit image in bounding box while preserving aspect ratio)
						src_aspect := f32(entry.width) / f32(entry.height)
						dst_aspect := box.width / box.height

						dst_rect: sdl.FRect
						if src_aspect > dst_aspect {
							// Image is wider than box, fit to width
							dst_rect.w = box.width
							dst_rect.h = box.width / src_aspect
							dst_rect.x = box.x
							dst_rect.y = box.y + (box.height - dst_rect.h) / 2
						} else {
							// Image is taller than box, fit to height
							dst_rect.h = box.height
							dst_rect.w = box.height * src_aspect
							dst_rect.x = box.x + (box.width - dst_rect.w) / 2
							dst_rect.y = box.y
						}

						// Render the texture
						sdl.RenderTexture(ctx.window_ctx.renderer, entry.texture, nil, &dst_rect)
					}
				}
			}

		case .ScissorStart:
			// Set SDL clipping rectangle for scroll containers
			box := cmd.boundingBox
			clip_rect := sdl.Rect {
				x = i32(box.x),
				y = i32(box.y),
				w = i32(box.width),
				h = i32(box.height),
			}
			sdl.SetRenderClipRect(ctx.window_ctx.renderer, &clip_rect)

		case .ScissorEnd:
			// Reset clipping rectangle
			sdl.SetRenderClipRect(ctx.window_ctx.renderer, nil)

		case .None, .Custom:
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
	node: ^api.UINode,
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

	// Cleanup image cache
	for path, entry in ctx.image_cache {
		if entry.texture != nil {
			sdl.DestroyTexture(entry.texture)
		}
		delete(entry.path)
	}
	delete(ctx.image_cache)

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
