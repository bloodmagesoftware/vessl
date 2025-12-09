package terminal

import vterm "../../../vendor/libvterm"
import api "../../api"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Terminal dimensions
TERMINAL_DEFAULT_ROWS :: 24
TERMINAL_DEFAULT_COLS :: 80
// Default cell dimensions (will be overridden by actual font measurement)
DEFAULT_CELL_WIDTH :: 19
DEFAULT_CELL_HEIGHT :: 38

// Cursor blink timing constants
CURSOR_BLINK_INTERVAL :: 0.53 // Time in seconds for each blink phase (on/off)
CURSOR_TYPING_TIMEOUT :: 0.5 // Time in seconds after last input before cursor starts blinking

// Terminal state
TerminalState :: struct {
	ctx:                ^api.PluginContext,
	allocator:          mem.Allocator,

	// VTerm state
	vt:                 ^vterm.VTerm,
	vt_screen:          ^vterm.VTermScreen,
	vt_state:           ^vterm.VTermState,

	// Terminal dimensions
	rows:               int,
	cols:               int,

	// Cell dimensions (measured from actual font)
	cell_width:         f32,
	cell_height:        f32,

	// PTY handle
	pty:                PTYHandle,
	pty_initialized:    bool,

	// UI nodes
	container_id:       string,
	terminal_root_id:   api.ElementID, // ID of the terminal root container (for scroll queries)
	row_nodes:          [dynamic]^api.UINode, // One text node per row
	dirty_rows:         [dynamic]bool, // Track which rows need redrawing

	// Cursor state
	cursor_row:         int, // Current cursor row position
	cursor_col:         int, // Current cursor column position
	cursor_node:        ^api.UINode, // UI node for the cursor rectangle
	cursor_blink_phase: bool, // Current blink phase (true = visible, false = hidden)
	last_input_time:    f32, // Total time when last input occurred
	total_time:         f32, // Total accumulated time since init
	blink_timer:        f32, // Accumulator for blink timing

	// Focus state
	has_focus:          bool,

	// Container dimensions for resize detection
	last_width:         f32,
	last_height:        f32,
}

// Screen callbacks for libvterm
vterm_callbacks: vterm.VTermScreenCallbacks

// Damage callback - marks rows as dirty
damage_callback :: proc "c" (rect: vterm.VTermRect, user: rawptr) -> c.int {
	context = runtime.default_context()
	state := cast(^TerminalState)user
	if state == nil do return 0

	// Mark affected rows as dirty
	for row in rect.start_row ..< rect.end_row {
		if int(row) < len(state.dirty_rows) {
			state.dirty_rows[int(row)] = true
		}
	}

	return 0
}

// Move cursor callback
movecursor_callback :: proc "c" (
	pos: vterm.VTermPos,
	oldpos: vterm.VTermPos,
	visible: c.int,
	user: rawptr,
) -> c.int {
	context = runtime.default_context()
	// Mark both old and new cursor rows as dirty
	state := cast(^TerminalState)user
	if state == nil do return 0

	if int(oldpos.row) < len(state.dirty_rows) {
		state.dirty_rows[int(oldpos.row)] = true
	}
	if int(pos.row) < len(state.dirty_rows) {
		state.dirty_rows[int(pos.row)] = true
	}

	// Update cursor position (visual update happens in update_cursor_position)
	state.cursor_row = int(pos.row)
	state.cursor_col = int(pos.col)

	return 0
}

// Initialize the plugin
terminal_init :: proc(ctx: ^api.PluginContext) -> bool {
	fmt.println("[terminal] Initializing...")

	state := new(TerminalState, ctx.allocator)
	state.ctx = ctx
	state.allocator = ctx.allocator
	state.rows = TERMINAL_DEFAULT_ROWS
	state.cols = TERMINAL_DEFAULT_COLS
	state.has_focus = false
	state.pty_initialized = false

	// Initialize cell dimensions with defaults (will be measured later)
	state.cell_width = DEFAULT_CELL_WIDTH
	state.cell_height = DEFAULT_CELL_HEIGHT

	// Initialize cursor state
	state.cursor_row = 0
	state.cursor_col = 0
	state.cursor_node = nil
	state.cursor_blink_phase = true // Start visible
	state.last_input_time = 0
	state.total_time = 0
	state.blink_timer = 0

	ctx.user_data = state

	// Initialize vterm callbacks
	vterm_callbacks = vterm.VTermScreenCallbacks {
		damage     = damage_callback,
		movecursor = movecursor_callback,
	}

	fmt.println("[terminal] Initialized successfully")
	return true
}

// Initialize VTerm with given dimensions
init_vterm :: proc(state: ^TerminalState, rows, cols: int) -> bool {
	if state.vt != nil {
		// Destroy existing vterm
		vterm.destroy(state.vt)
	}

	state.rows = rows
	state.cols = cols

	// Create new vterm
	state.vt = vterm.create(rows, cols)
	if state.vt == nil {
		fmt.eprintln("[terminal] Failed to create VTerm")
		return false
	}

	// Enable UTF-8 mode for proper Unicode handling
	vterm.enable_utf8(state.vt)

	// Get screen and state interfaces
	state.vt_screen = vterm.obtain_screen(state.vt)
	state.vt_state = vterm.obtain_state(state.vt)

	if state.vt_screen == nil || state.vt_state == nil {
		fmt.eprintln("[terminal] Failed to obtain VTerm screen/state")
		vterm.destroy(state.vt)
		state.vt = nil
		return false
	}

	// Set up screen callbacks
	vterm.set_callbacks(state.vt_screen, &vterm_callbacks, state)

	// Enable screen features
	vterm.enable_altscreen(state.vt_screen, 1)

	// Reset the screen
	vterm.reset(state.vt_screen, 1)

	// Initialize dirty rows tracking
	if state.dirty_rows != nil {
		delete(state.dirty_rows)
	}
	state.dirty_rows = make([dynamic]bool, rows, state.allocator)
	for i in 0 ..< rows {
		state.dirty_rows[i] = true // Mark all rows dirty initially
	}

	fmt.printf("[terminal] VTerm initialized with %dx%d\n", cols, rows)
	return true
}

// Spawn the shell process
spawn_shell :: proc(state: ^TerminalState) -> bool {
	if state.pty_initialized {
		return true // Already initialized
	}

	// Get shell path
	shell := get_default_shell()
	fmt.printf("[terminal] Spawning shell: %s\n", shell)

	// Spawn PTY
	pty, ok := spawn_pty(shell, state.rows, state.cols)
	if !ok {
		fmt.eprintln("[terminal] Failed to spawn PTY")
		return false
	}

	state.pty = pty
	state.pty_initialized = true

	fmt.println("[terminal] Shell spawned successfully")
	return true
}

// Create UI for the terminal
create_terminal_ui :: proc(state: ^TerminalState, container_id: string) -> bool {
	if state == nil || state.ctx == nil do return false

	state.container_id = strings.clone(container_id, state.allocator)

	// Measure actual font dimensions using a reference character
	// Use "M" as it's typically the widest character in monospace fonts
	char_width, char_height := api.measure_text(state.ctx, "M")
	if char_width > 0 && char_height > 0 {
		state.cell_width = char_width
		state.cell_height = char_height
		fmt.printf("[terminal] Measured cell dimensions: %.1f x %.1f\n", char_width, char_height)
	} else {
		fmt.printf(
			"[terminal] Using default cell dimensions: %.1f x %.1f\n",
			state.cell_width,
			state.cell_height,
		)
	}

	cell_width_int := int(state.cell_width)
	cell_height_int := int(state.cell_height)

	// Create the main terminal container
	terminal_root_id := api.ElementID(fmt.tprintf("terminal_root_%s", container_id))
	state.terminal_root_id = terminal_root_id // Store for scroll queries
	terminal_root := api.create_node(terminal_root_id, .Container, state.allocator)
	terminal_root.style.width = api.SIZE_FULL
	terminal_root.style.height = api.sizing_grow()
	terminal_root.style.color = {0.08, 0.08, 0.08, 1.0} // Dark terminal background
	terminal_root.style.layout_dir = .TopDown
	terminal_root.style.padding = {8, 8, 8, 8}
	terminal_root.style.clip_vertical = true

	// Create cursor rectangle node (added first so it's rendered, uses floating for positioning)
	cursor_id := api.ElementID(fmt.tprintf("terminal_cursor_%s", container_id))
	cursor_node := api.create_node(cursor_id, .Container, state.allocator)
	cursor_node.style.width = api.sizing_px(cell_width_int)
	cursor_node.style.height = api.sizing_px(cell_height_int)
	cursor_node.style.color = {0.8, 0.8, 0.8, 0.8} // Semi-transparent light cursor
	// Position at initial cursor location (0,0) + padding offset
	cursor_node.style.offset_x = 8 // Padding left
	cursor_node.style.offset_y = 8 // Padding top
	cursor_node.style.hidden = false
	api.add_child(terminal_root, cursor_node)
	state.cursor_node = cursor_node

	// Create row nodes (text nodes for each line)
	if state.row_nodes != nil {
		delete(state.row_nodes)
	}
	state.row_nodes = make([dynamic]^api.UINode, state.rows, state.allocator)

	for row in 0 ..< state.rows {
		row_id := api.ElementID(fmt.tprintf("terminal_row_%s_%d", container_id, row))
		row_node := api.create_node(row_id, .Text, state.allocator)
		row_node.style.width = api.SIZE_FULL
		row_node.style.height = api.sizing_px(cell_height_int)
		row_node.style.color = {0.9, 0.9, 0.9, 1.0} // Light text
		row_node.text_content = "" // Empty initially

		api.add_child(terminal_root, row_node)
		state.row_nodes[row] = row_node
	}

	// Make terminal clickable to gain focus
	terminal_root.on_click = proc(ctx: rawptr) {
		state := cast(^TerminalState)ctx
		if state != nil {
			state.has_focus = true
			fmt.println("[terminal] Gained focus")
		}
	}
	terminal_root.callback_ctx = state
	terminal_root.cursor = .Text

	// Attach to container
	if !api.attach_to_container(state.ctx, container_id, terminal_root) {
		fmt.eprintln("[terminal] Failed to attach to container")
		return false
	}

	fmt.printf("[terminal] Created terminal UI in container: %s\n", container_id)
	return true
}

// Update a single row's text content from vterm screen
update_row_content :: proc(state: ^TerminalState, row: int) {
	if state == nil || state.vt_screen == nil do return
	if row < 0 || row >= len(state.row_nodes) do return

	node := state.row_nodes[row]
	if node == nil do return

	// Build the row text by reading cells
	builder := strings.builder_make(state.allocator)
	defer strings.builder_destroy(&builder)

	cell: vterm.VTermScreenCell

	for col in 0 ..< state.cols {
		if vterm.get_screen_cell(state.vt_screen, row, col, &cell) {
			// Get character from cell
			char_str := vterm.cell_to_string(&cell, state.allocator)
			strings.write_string(&builder, char_str)
			delete(char_str, state.allocator)
		} else {
			strings.write_byte(&builder, ' ')
		}
	}

	// Trim trailing spaces
	row_text := strings.to_string(builder)
	trimmed := strings.trim_right_space(row_text)

	// Just set new content
	node.text_content = strings.clone(trimmed, state.allocator)
}

// Update all dirty rows
update_dirty_rows :: proc(state: ^TerminalState) {
	if state == nil do return

	for row in 0 ..< len(state.dirty_rows) {
		if state.dirty_rows[row] {
			update_row_content(state, row)
			state.dirty_rows[row] = false
		}
	}
}

// Process PTY output - read from PTY and feed to vterm
process_pty_output :: proc(state: ^TerminalState) {
	if state == nil || !state.pty_initialized do return

	// Read available data from PTY (non-blocking)
	buffer: [4096]u8
	bytes_read := read_pty(state.pty, buffer[:])

	if bytes_read > 0 {
		// Feed data to vterm
		vterm.write_input(state.vt, buffer[:bytes_read])

		// Flush damage to update dirty flags
		vterm.flush_damage(state.vt_screen)

		// Auto-scroll to bottom when new content arrives
		auto_scroll_to_bottom(state)

		// Request redraw since terminal content changed
		// This is needed because PTY output isn't triggered by SDL events
		api.request_redraw(state.ctx)
	}
}

// Auto-scroll the terminal to show the bottom content
// This ensures new output is always visible
auto_scroll_to_bottom :: proc(state: ^TerminalState) {
	if state == nil || state.ctx == nil do return
	if state.terminal_root_id == api.ElementID("") do return

	// Calculate total content height
	// Content = padding_top + (rows * cell_height) + padding_bottom
	padding: f32 = 8 // Matches padding set in create_terminal_ui
	content_height := padding + f32(state.rows) * state.cell_height + padding

	// Get the container's visible height from the stored dimensions
	// We need to estimate the container height based on last known dimensions
	container_height := state.last_height
	if container_height <= 0 {
		// If we don't have container height yet, skip auto-scroll
		return
	}

	// Only scroll if content exceeds container
	if content_height > container_height {
		// Scroll position is negative to scroll down
		// To show the bottom, scroll_y = -(content_height - container_height)
		scroll_y := -(content_height - container_height)
		api.set_scroll_position(state.ctx, state.terminal_root_id, 0, scroll_y)
	}
}

// Send keyboard input to PTY via vterm
send_key_input :: proc(state: ^TerminalState, key: i32, modifiers: api.KeyModifier) {
	if state == nil || state.vt == nil do return

	// Record input time for cursor blink logic
	state.last_input_time = state.total_time
	state.cursor_blink_phase = true // Show cursor immediately on input
	state.blink_timer = 0 // Reset blink timer

	// Convert modifiers
	vt_mod: vterm.VTermModifier = .NONE
	if .Shift in modifiers {
		vt_mod = vterm.VTermModifier(int(vt_mod) | int(vterm.VTermModifier.SHIFT))
	}
	if .Ctrl in modifiers || .CtrlMac in modifiers {
		vt_mod = vterm.VTermModifier(int(vt_mod) | int(vterm.VTermModifier.CTRL))
	}
	if .Alt in modifiers || .Opt in modifiers {
		vt_mod = vterm.VTermModifier(int(vt_mod) | int(vterm.VTermModifier.ALT))
	}

	// Map SDL keycodes to vterm keys
	vt_key := sdl_key_to_vterm_key(key)

	if vt_key != .NONE {
		vterm.send_key(state.vt, vt_key, vt_mod)
	}

	// Read output and send to PTY
	flush_vterm_output(state)
}

// Send text input to PTY via vterm
send_text_input :: proc(state: ^TerminalState, text: string) {
	if state == nil || state.vt == nil do return

	// Record input time for cursor blink logic
	state.last_input_time = state.total_time
	state.cursor_blink_phase = true // Show cursor immediately on input
	state.blink_timer = 0 // Reset blink timer

	// Convert modifiers (none for text input)
	for r in text {
		vterm.send_char(state.vt, r)
	}

	// Read output and send to PTY
	flush_vterm_output(state)
}

// Flush vterm output buffer to PTY
flush_vterm_output :: proc(state: ^TerminalState) {
	if state == nil || !state.pty_initialized do return

	buffer: [4096]u8
	for {
		bytes_read := vterm.read_output(state.vt, buffer[:])
		if bytes_read <= 0 do break

		write_pty(state.pty, buffer[:bytes_read])
	}
}

// Map SDL keycode to VTerm key
sdl_key_to_vterm_key :: proc(sdl_key: i32) -> vterm.VTermKey {
	// SDL3 keycodes - check common keys
	// These are SDL_SCANCODE values shifted
	switch sdl_key {
	case 0x0D, 0x4000_0058:
		// Return/Enter
		return .ENTER
	case 0x09, 0x4000_002B:
		// Tab
		return .TAB
	case 0x08, 0x4000_002A:
		// Backspace
		return .BACKSPACE
	case 0x1B, 0x4000_0029:
		// Escape
		return .ESCAPE
	case 0x4000_0052:
		// Up
		return .UP
	case 0x4000_0051:
		// Down
		return .DOWN
	case 0x4000_0050:
		// Left
		return .LEFT
	case 0x4000_004F:
		// Right
		return .RIGHT
	case 0x4000_0049:
		// Insert
		return .INS
	case 0x4000_004C, 0x7F:
		// Delete
		return .DEL
	case 0x4000_004A:
		// Home
		return .HOME
	case 0x4000_004D:
		// End
		return .END
	case 0x4000_004B:
		// Page Up
		return .PAGEUP
	case 0x4000_004E:
		// Page Down
		return .PAGEDOWN
	// Function keys F1-F12
	case 0x4000_003A:
		return .FUNCTION_1
	case 0x4000_003B:
		return .FUNCTION_2
	case 0x4000_003C:
		return .FUNCTION_3
	case 0x4000_003D:
		return .FUNCTION_4
	case 0x4000_003E:
		return .FUNCTION_5
	case 0x4000_003F:
		return .FUNCTION_6
	case 0x4000_0040:
		return .FUNCTION_7
	case 0x4000_0041:
		return .FUNCTION_8
	case 0x4000_0042:
		return .FUNCTION_9
	case 0x4000_0043:
		return .FUNCTION_10
	case 0x4000_0044:
		return .FUNCTION_11
	case 0x4000_0045:
		return .FUNCTION_12
	}
	return .NONE
}

// Resize terminal based on container dimensions
resize_terminal :: proc(state: ^TerminalState, width, height: f32) {
	if state == nil do return

	// Account for padding (8px on each side)
	padding: f32 = 16
	available_width := width - padding
	available_height := height - padding

	// Calculate new dimensions based on container size
	new_cols := max(int(available_width / state.cell_width), 20)
	new_rows := max(int(available_height / state.cell_height), 3)

	if new_cols == state.cols && new_rows == state.rows {
		return // No change needed
	}

	fmt.printf(
		"[terminal] Resizing to %dx%d (container: %.0fx%.0f)\n",
		new_cols,
		new_rows,
		width,
		height,
	)

	old_rows := state.rows
	state.rows = new_rows
	state.cols = new_cols

	// Update vterm size
	if state.vt != nil {
		vterm.set_terminal_size(state.vt, new_rows, new_cols)
	}

	// Update PTY size
	if state.pty_initialized {
		resize_pty(state.pty, new_rows, new_cols)
	}

	// Resize dirty tracking
	old_dirty := state.dirty_rows
	state.dirty_rows = make([dynamic]bool, new_rows, state.allocator)
	for i in 0 ..< new_rows {
		state.dirty_rows[i] = true
	}
	if old_dirty != nil {
		delete(old_dirty)
	}

	// Recreate row nodes if row count changed
	if new_rows != old_rows && state.terminal_root_id != api.ElementID("") {
		recreate_row_nodes(state, new_rows)
	}

	// Update stored dimensions
	state.last_width = width
	state.last_height = height
}

// Recreate row nodes when terminal is resized
recreate_row_nodes :: proc(state: ^TerminalState, new_rows: int) {
	if state == nil || state.ctx == nil do return

	// Find terminal root node
	terminal_root := api.find_node_by_id(state.ctx, state.terminal_root_id)
	if terminal_root == nil do return

	cell_height_int := int(state.cell_height)

	// Remove old row nodes (keep cursor node which is first child)
	// Clear children except cursor (index 0)
	api.clear_children_except(terminal_root, 1)

	// Recreate row nodes array
	if state.row_nodes != nil {
		delete(state.row_nodes)
	}
	state.row_nodes = make([dynamic]^api.UINode, new_rows, state.allocator)

	// Create new row nodes
	for row in 0 ..< new_rows {
		row_id := api.ElementID(fmt.tprintf("terminal_row_%s_%d", state.container_id, row))
		row_node := api.create_node(row_id, .Text, state.allocator)
		row_node.style.width = api.SIZE_FULL
		row_node.style.height = api.sizing_px(cell_height_int)
		row_node.style.color = {0.9, 0.9, 0.9, 1.0} // Light text
		row_node.text_content = "" // Empty initially

		api.add_child(terminal_root, row_node)
		state.row_nodes[row] = row_node
	}
}

// Update the plugin
terminal_update :: proc(ctx: ^api.PluginContext, dt: f32) {
	state := cast(^TerminalState)ctx.user_data
	if state == nil do return

	// Check if container size changed and resize terminal if needed
	check_container_resize(state)

	// Process PTY output
	process_pty_output(state)

	// Update dirty rows
	update_dirty_rows(state)

	// Update cursor position (accounts for scroll)
	update_cursor_position(state)

	// Update cursor blink logic
	update_cursor_blink(state, dt)
}

// Check if terminal container has been resized and resize terminal accordingly
check_container_resize :: proc(state: ^TerminalState) {
	if state == nil || state.ctx == nil do return
	if state.terminal_root_id == api.ElementID("") do return

	// Query the actual rendered bounds of the terminal container
	_, _, width, height, found := api.get_element_bounds(state.ctx, state.terminal_root_id)
	if !found do return

	// Check if size changed significantly (avoid floating point noise)
	width_changed := abs(width - state.last_width) > 1.0
	height_changed := abs(height - state.last_height) > 1.0

	if width_changed || height_changed {
		resize_terminal(state, width, height)
	}
}

// Update cursor visual position accounting for scroll offset
update_cursor_position :: proc(state: ^TerminalState) {
	if state == nil || state.cursor_node == nil || state.ctx == nil do return

	// Get current scroll position of the terminal container
	scroll_x, scroll_y := api.get_scroll_position(state.ctx, state.terminal_root_id)

	// Calculate cursor position:
	// Base position = padding (8) + col/row * cell_size
	// Apply scroll offset (scroll_y is negative when scrolled down)
	base_x := 8 + f32(state.cursor_col) * state.cell_width
	base_y := 8 + f32(state.cursor_row) * state.cell_height

	// Apply scroll offset
	state.cursor_node.style.offset_x = base_x + scroll_x
	state.cursor_node.style.offset_y = base_y + scroll_y
}

// Update cursor blink state
update_cursor_blink :: proc(state: ^TerminalState, dt: f32) {
	if state == nil || state.cursor_node == nil do return

	// Accumulate total time
	state.total_time += dt

	// Check if we're in typing mode (recent input) or idle mode
	time_since_input := state.total_time - state.last_input_time
	is_typing := time_since_input < CURSOR_TYPING_TIMEOUT

	old_visible := state.cursor_blink_phase

	if is_typing {
		// Typing mode: cursor always visible
		state.cursor_blink_phase = true
		state.blink_timer = 0
	} else {
		// Idle mode: blink the cursor
		state.blink_timer += dt
		if state.blink_timer >= CURSOR_BLINK_INTERVAL {
			state.blink_timer -= CURSOR_BLINK_INTERVAL
			state.cursor_blink_phase = !state.cursor_blink_phase
		}
	}

	// Update cursor visibility based on blink phase and focus
	// Cursor is visible if: has_focus AND cursor_blink_phase
	should_show := state.has_focus && state.cursor_blink_phase
	state.cursor_node.style.hidden = !should_show

	// Request redraw if visibility changed
	if old_visible != state.cursor_blink_phase {
		api.request_redraw(state.ctx)
	}
}

// Shutdown the plugin
terminal_shutdown :: proc(ctx: ^api.PluginContext) {
	fmt.println("[terminal] Shutting down...")

	state := cast(^TerminalState)ctx.user_data
	if state == nil do return

	// Close PTY
	if state.pty_initialized {
		close_pty(state.pty)
		state.pty_initialized = false
	}

	// Destroy vterm
	if state.vt != nil {
		vterm.destroy(state.vt)
		state.vt = nil
	}

	// Cleanup arrays
	if state.row_nodes != nil {
		delete(state.row_nodes)
	}
	if state.dirty_rows != nil {
		delete(state.dirty_rows)
	}
	if len(state.container_id) > 0 {
		delete(state.container_id)
	}

	free(state)
	fmt.println("[terminal] Shutdown complete")
}

// Handle events
terminal_on_event :: proc(ctx: ^api.PluginContext, event: ^api.Event) -> bool {
	if event == nil do return false

	state := cast(^TerminalState)ctx.user_data
	if state == nil do return false

	#partial switch event.type {
	case .Layout_Container_Ready:
		#partial switch payload in event.payload {
		case api.EventPayload_Layout:
			if payload.target_plugin != "builtin:terminal" do return false

			fmt.printf("[terminal] Received Layout_Container_Ready for %s\n", payload.container_id)

			// Initialize vterm
			if !init_vterm(state, TERMINAL_DEFAULT_ROWS, TERMINAL_DEFAULT_COLS) {
				fmt.eprintln("[terminal] Failed to initialize VTerm")
				return false
			}

			// Create UI
			if !create_terminal_ui(state, payload.container_id) {
				fmt.eprintln("[terminal] Failed to create terminal UI")
				return false
			}

			// Spawn shell
			if !spawn_shell(state) {
				fmt.eprintln("[terminal] Failed to spawn shell")
				// Continue anyway - terminal will show but be non-functional
			}

			return true
		}
		return false

	case .Key_Down:
		fmt.printf("[terminal] Key_Down event, has_focus=%v\n", state.has_focus)
		if !state.has_focus do return false

		#partial switch payload in event.payload {
		case api.EventPayload_KeyDown:
			fmt.printf("[terminal] Processing Key_Down: key=%d\n", payload.key)
			send_key_input(state, payload.key, payload.modifiers)
			return true // Consume if we have focus
		}
		return false

	case .Text_Input:
		fmt.printf("[terminal] Text_Input event, has_focus=%v\n", state.has_focus)
		if !state.has_focus do return false

		#partial switch payload in event.payload {
		case api.EventPayload_TextInput:
			fmt.printf("[terminal] Processing Text_Input: '%s'\n", payload.text)
			send_text_input(state, payload.text)
			return true // Consume if we have focus
		}
		return false

	case .Mouse_Down:
		// Check if click is in terminal area to gain focus
		#partial switch payload in event.payload {
		case api.EventPayload_MouseDown:
			// Check if element is in our terminal UI
			element_str := string(payload.element_id)
			fmt.printf("[terminal] Mouse_Down on element: '%s'\n", element_str)
			if strings.has_prefix(element_str, "terminal_") {
				if !state.has_focus {
					state.has_focus = true
					fmt.println("[terminal] Gained focus")
				}
				return false // Don't consume - let UI handle it
			} else {
				// Click outside terminal - lose focus
				if state.has_focus {
					state.has_focus = false
					fmt.println("[terminal] Lost focus")
				}
			}
		}
		return false

	}

	return false
}

// Get the plugin VTable
get_vtable :: proc() -> api.PluginVTable {
	return api.PluginVTable {
		init = terminal_init,
		update = terminal_update,
		shutdown = terminal_shutdown,
		on_event = terminal_on_event,
	}
}
