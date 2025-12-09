package libvterm

// Libvterm Odin bindings
// libvterm is a terminal emulator library that handles ANSI escape sequences
// and maintains the terminal state (screen buffer, cursor, colors, etc.)

import "core:c"

// Platform-specific library linking
when ODIN_OS == .Windows {
	foreign import vterm "windows-amd64/vterm.lib"
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .arm64 {
		foreign import vterm "macos-arm64/libvterm.a"
	} else {
		foreign import vterm "macos-amd64/libvterm.a"
	}
} else when ODIN_OS == .Linux {
	when ODIN_ARCH == .arm64 {
		foreign import vterm "linux-arm64/libvterm.a"
	} else {
		foreign import vterm "linux-amd64/libvterm.a"
	}
}

// =============================================================================
// Core Types
// =============================================================================

VTerm :: struct {}
VTermScreen :: struct {}
VTermState :: struct {}

// Position in the terminal (row, col)
VTermPos :: struct {
	row: c.int,
	col: c.int,
}

// Rectangle in the terminal
VTermRect :: struct {
	start_row: c.int,
	end_row:   c.int,
	start_col: c.int,
	end_col:   c.int,
}

// Color representation - must match C struct layout exactly
// C struct: { uint8_t type; union { uint8_t idx; struct { uint8_t r,g,b; } rgb; }; }
VTermColor :: struct #packed {
	type:  u8, // VTERM_COLOR_* constants
	// Union for different color types
	// For indexed: index is in red field
	// For RGB: red, green, blue fields
	red:   u8,
	green: u8,
	blue:  u8,
}

// Color type constants
VTERM_COLOR_INDEXED :: 1
VTERM_COLOR_RGB :: 2
VTERM_COLOR_DEFAULT_FG :: 4
VTERM_COLOR_DEFAULT_BG :: 8

// Check if color is indexed
color_is_indexed :: proc(col: ^VTermColor) -> bool {
	return (col.type & VTERM_COLOR_INDEXED) != 0
}

// Check if color is RGB
color_is_rgb :: proc(col: ^VTermColor) -> bool {
	return (col.type & VTERM_COLOR_RGB) != 0
}

// Check if color is default foreground
color_is_default_fg :: proc(col: ^VTermColor) -> bool {
	return (col.type & VTERM_COLOR_DEFAULT_FG) != 0
}

// Check if color is default background
color_is_default_bg :: proc(col: ^VTermColor) -> bool {
	return (col.type & VTERM_COLOR_DEFAULT_BG) != 0
}

// Get color index (for indexed colors)
color_get_index :: proc(col: ^VTermColor) -> u8 {
	return col.red
}

// Screen cell attributes - C bitfield struct packed into a single u32
// C layout: bold:1, underline:2, italic:1, blink:1, reverse:1, conceal:1, strike:1, font:4, dwl:1, dhl:2, small:1, baseline:2
// Total: 18 bits, stored in a u32
VTermScreenCellAttrs :: struct #packed {
	_bits: u32, // All attribute bits packed together
}

// Attribute accessors (if needed)
attrs_get_bold :: proc(attrs: VTermScreenCellAttrs) -> bool {
	return (attrs._bits & 0x1) != 0
}

attrs_get_underline :: proc(attrs: VTermScreenCellAttrs) -> u8 {
	return u8((attrs._bits >> 1) & 0x3)
}

attrs_get_italic :: proc(attrs: VTermScreenCellAttrs) -> bool {
	return (attrs._bits & (1 << 3)) != 0
}

attrs_get_reverse :: proc(attrs: VTermScreenCellAttrs) -> bool {
	return (attrs._bits & (1 << 5)) != 0
}

// Screen cell - represents a single character cell
// Must match C struct layout exactly for FFI
VTERM_MAX_CHARS_PER_CELL :: 6

VTermScreenCell :: struct {
	chars: [VTERM_MAX_CHARS_PER_CELL]u32, // Unicode codepoints (0-terminated) - 24 bytes
	width: c.char, // Width in cells (1 or 2 for wide chars) - 1 byte
	_pad1: [3]u8, // Padding to align attrs to 4-byte boundary
	attrs: VTermScreenCellAttrs, // Attributes bitfield - 4 bytes
	fg:    VTermColor, // Foreground color - 4 bytes
	bg:    VTermColor, // Background color - 4 bytes
}

// Modifier keys
VTermModifier :: enum c.int {
	NONE  = 0,
	SHIFT = 1 << 0,
	ALT   = 1 << 1,
	CTRL  = 1 << 2,
}

// Special keys
VTermKey :: enum c.int {
	NONE        = 0,
	ENTER       = 1,
	TAB         = 2,
	BACKSPACE   = 3,
	ESCAPE      = 4,
	UP          = 5,
	DOWN        = 6,
	LEFT        = 7,
	RIGHT       = 8,
	INS         = 9,
	DEL         = 10,
	HOME        = 11,
	END         = 12,
	PAGEUP      = 13,
	PAGEDOWN    = 14,
	FUNCTION_0  = 256,
	FUNCTION_1  = 257,
	FUNCTION_2  = 258,
	FUNCTION_3  = 259,
	FUNCTION_4  = 260,
	FUNCTION_5  = 261,
	FUNCTION_6  = 262,
	FUNCTION_7  = 263,
	FUNCTION_8  = 264,
	FUNCTION_9  = 265,
	FUNCTION_10 = 266,
	FUNCTION_11 = 267,
	FUNCTION_12 = 268,
	KP_0        = 512,
	KP_1        = 513,
	KP_2        = 514,
	KP_3        = 515,
	KP_4        = 516,
	KP_5        = 517,
	KP_6        = 518,
	KP_7        = 519,
	KP_8        = 520,
	KP_9        = 521,
	KP_MULT     = 522,
	KP_PLUS     = 523,
	KP_COMMA    = 524,
	KP_MINUS    = 525,
	KP_PERIOD   = 526,
	KP_DIVIDE   = 527,
	KP_ENTER    = 528,
	KP_EQUAL    = 529,
	MAX         = 530,
}

// Damage information for screen updates
VTermDamage :: enum c.int {
	SCROLL = 0, // Damage represents a scroll operation
	CELL   = 1, // Damage represents individual cell changes
}

// =============================================================================
// Screen Callbacks
// =============================================================================

// Callback function types for screen events
VTermScreenCallbacks :: struct {
	damage:      proc "c" (rect: VTermRect, user: rawptr) -> c.int,
	moverect:    proc "c" (dest: VTermRect, src: VTermRect, user: rawptr) -> c.int,
	movecursor:  proc "c" (pos: VTermPos, oldpos: VTermPos, visible: c.int, user: rawptr) -> c.int,
	settermprop: proc "c" (prop: c.int, val: ^VTermValue, user: rawptr) -> c.int,
	bell:        proc "c" (user: rawptr) -> c.int,
	resize:      proc "c" (rows: c.int, cols: c.int, user: rawptr) -> c.int,
	sb_pushline: proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int,
	sb_popline:  proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int,
	sb_clear:    proc "c" (user: rawptr) -> c.int,
}

// Value union for terminal properties
VTermValue :: struct #raw_union {
	boolean: c.int,
	number:  c.int,
	string:  cstring,
	color:   VTermColor,
}

// Output callback - called when terminal generates output
VTermOutputCallback :: proc "c" (s: [^]u8, len: c.size_t, user: rawptr)

// =============================================================================
// Core Functions
// =============================================================================

@(default_calling_convention = "c", link_prefix = "vterm_")
foreign vterm {
	// Create/destroy terminal
	new :: proc(rows: c.int, cols: c.int) -> ^VTerm ---
	free :: proc(vt: ^VTerm) ---

	// Get/set size
	get_size :: proc(vt: ^VTerm, rowsp: ^c.int, colsp: ^c.int) ---
	set_size :: proc(vt: ^VTerm, rows: c.int, cols: c.int) ---

	// UTF-8 mode - MUST be enabled for proper Unicode handling
	set_utf8 :: proc(vt: ^VTerm, is_utf8: c.int) ---

	// Input - write data from PTY to terminal
	input_write :: proc(vt: ^VTerm, bytes: [^]u8, len: c.size_t) -> c.size_t ---

	// Output callback - terminal writes data to be sent to PTY
	output_set_callback :: proc(vt: ^VTerm, func: VTermOutputCallback, user: rawptr) ---

	// Get UTF-8 representation of output
	output_get_buffer_size :: proc(vt: ^VTerm) -> c.size_t ---
	output_get_buffer_current :: proc(vt: ^VTerm) -> c.size_t ---
	output_get_buffer_remaining :: proc(vt: ^VTerm) -> c.size_t ---
	output_read :: proc(vt: ^VTerm, buffer: [^]u8, len: c.size_t) -> c.size_t ---

	// Keyboard input
	keyboard_unichar :: proc(vt: ^VTerm, c: u32, mod: VTermModifier) ---
	keyboard_key :: proc(vt: ^VTerm, key: VTermKey, mod: VTermModifier) ---

	// Mouse input (if needed)
	mouse_move :: proc(vt: ^VTerm, row: c.int, col: c.int, mod: VTermModifier) ---
	mouse_button :: proc(vt: ^VTerm, button: c.int, pressed: c.int, mod: VTermModifier) ---

	// Obtain screen interface
	obtain_screen :: proc(vt: ^VTerm) -> ^VTermScreen ---

	// Obtain state interface
	obtain_state :: proc(vt: ^VTerm) -> ^VTermState ---
}

// =============================================================================
// Screen Functions
// =============================================================================

@(default_calling_convention = "c", link_prefix = "vterm_screen_")
foreign vterm {
	// Enable/disable screen
	enable_reflow :: proc(screen: ^VTermScreen, reflow: c.int) ---
	enable_altscreen :: proc(screen: ^VTermScreen, altscreen: c.int) ---

	// Set callbacks
	set_callbacks :: proc(screen: ^VTermScreen, callbacks: ^VTermScreenCallbacks, user: rawptr) ---

	// Reset screen
	reset :: proc(screen: ^VTermScreen, hard: c.int) ---

	// Get cell at position
	get_cell :: proc(screen: ^VTermScreen, pos: VTermPos, cell: ^VTermScreenCell) -> c.int ---

	// Check if cell position is end of line
	is_eol :: proc(screen: ^VTermScreen, pos: VTermPos) -> c.int ---

	// Get text from a region (returns UTF-8)
	get_text :: proc(screen: ^VTermScreen, str: [^]u8, len: c.size_t, rect: VTermRect) -> c.size_t ---

	// Damage control
	set_damage_merge :: proc(screen: ^VTermScreen, size: VTermDamage) ---
	flush_damage :: proc(screen: ^VTermScreen) ---

	// Get/set attributes
	get_attrs_extent :: proc(screen: ^VTermScreen, extent: ^VTermRect, pos: VTermPos, attrs: VTermScreenCellAttrs) -> c.int ---
}

// =============================================================================
// State Functions
// =============================================================================

@(default_calling_convention = "c", link_prefix = "vterm_state_")
foreign vterm {
	// Get cursor position
	get_cursorpos :: proc(state: ^VTermState, cursorpos: ^VTermPos) ---

	// Set default colors
	set_default_colors :: proc(state: ^VTermState, default_fg: ^VTermColor, default_bg: ^VTermColor) ---

	// Get palette color
	get_palette_color :: proc(state: ^VTermState, index: c.int, col: ^VTermColor) ---

	// Set palette color
	set_palette_color :: proc(state: ^VTermState, index: c.int, col: ^VTermColor) ---

	// Convert color to RGB
	convert_color_to_rgb :: proc(state: ^VTermState, col: ^VTermColor) ---
}

// =============================================================================
// Helper Functions (Odin-specific)
// =============================================================================

// Create a new terminal with given dimensions
create :: proc(rows, cols: int) -> ^VTerm {
	return new(c.int(rows), c.int(cols))
}

// Destroy a terminal
destroy :: proc(vt: ^VTerm) {
	if vt != nil {
		free(vt)
	}
}

// Get terminal size
get_terminal_size :: proc(vt: ^VTerm) -> (rows: int, cols: int) {
	r, c_val: c.int
	get_size(vt, &r, &c_val)
	return int(r), int(c_val)
}

// Set terminal size
set_terminal_size :: proc(vt: ^VTerm, rows, cols: int) {
	set_size(vt, c.int(rows), c.int(cols))
}

// Enable UTF-8 mode (required for proper Unicode handling)
enable_utf8 :: proc(vt: ^VTerm) {
	set_utf8(vt, 1)
}

// Write input data to terminal (data from PTY)
write_input :: proc(vt: ^VTerm, data: []u8) -> int {
	if len(data) == 0 do return 0
	return int(input_write(vt, raw_data(data), c.size_t(len(data))))
}

// Read output data from terminal (data to send to PTY)
read_output :: proc(vt: ^VTerm, buffer: []u8) -> int {
	if len(buffer) == 0 do return 0
	return int(output_read(vt, raw_data(buffer), c.size_t(len(buffer))))
}

// Send a Unicode character as keyboard input
send_char :: proc(vt: ^VTerm, char: rune, mod: VTermModifier = .NONE) {
	keyboard_unichar(vt, u32(char), mod)
}

// Send a special key
send_key :: proc(vt: ^VTerm, key: VTermKey, mod: VTermModifier = .NONE) {
	keyboard_key(vt, key, mod)
}

// Get a cell from the screen
get_screen_cell :: proc(screen: ^VTermScreen, row, col: int, cell: ^VTermScreenCell) -> bool {
	pos := VTermPos {
		row = c.int(row),
		col = c.int(col),
	}
	return get_cell(screen, pos, cell) != 0
}

// Get the character(s) from a cell as a string
// IMPORTANT: The returned string is always allocated and must be freed by the caller
cell_to_string :: proc(cell: ^VTermScreenCell, allocator := context.allocator) -> string {
	// Find the end of the character sequence
	buf: [32]u8
	idx := 0

	for i in 0 ..< VTERM_MAX_CHARS_PER_CELL {
		cp := cell.chars[i]
		if cp == 0 do break

		// Encode UTF-8
		if cp < 0x80 {
			if idx < len(buf) {
				buf[idx] = u8(cp)
				idx += 1
			}
		} else if cp < 0x800 {
			if idx + 1 < len(buf) {
				buf[idx] = u8(0xC0 | (cp >> 6))
				buf[idx + 1] = u8(0x80 | (cp & 0x3F))
				idx += 2
			}
		} else if cp < 0x10000 {
			if idx + 2 < len(buf) {
				buf[idx] = u8(0xE0 | (cp >> 12))
				buf[idx + 1] = u8(0x80 | ((cp >> 6) & 0x3F))
				buf[idx + 2] = u8(0x80 | (cp & 0x3F))
				idx += 3
			}
		} else {
			if idx + 3 < len(buf) {
				buf[idx] = u8(0xF0 | (cp >> 18))
				buf[idx + 1] = u8(0x80 | ((cp >> 12) & 0x3F))
				buf[idx + 2] = u8(0x80 | ((cp >> 6) & 0x3F))
				buf[idx + 3] = u8(0x80 | (cp & 0x3F))
				idx += 4
			}
		}
	}

	if idx == 0 {
		// Empty cell = space - must allocate since caller will free
		result := make([]u8, 1, allocator)
		result[0] = ' '
		return string(result)
	}

	result := make([]u8, idx, allocator)
	copy(result, buf[:idx])
	return string(result)
}

// Convert VTermColor to RGBA (0-1 range)
color_to_rgba :: proc(col: ^VTermColor, state: ^VTermState) -> [4]f32 {
	// If it's an indexed color, convert to RGB first
	if color_is_indexed(col) {
		rgb_col := col^
		convert_color_to_rgb(state, &rgb_col)
		return {
			f32(rgb_col.red) / 255.0,
			f32(rgb_col.green) / 255.0,
			f32(rgb_col.blue) / 255.0,
			1.0,
		}
	}

	if color_is_rgb(col) {
		return {f32(col.red) / 255.0, f32(col.green) / 255.0, f32(col.blue) / 255.0, 1.0}
	}

	// Default colors
	if color_is_default_fg(col) {
		return {0.9, 0.9, 0.9, 1.0} // Light gray
	}
	if color_is_default_bg(col) {
		return {0.1, 0.1, 0.1, 1.0} // Dark background
	}

	return {1.0, 1.0, 1.0, 1.0} // White fallback
}
