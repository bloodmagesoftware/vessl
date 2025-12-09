package api

import "core:mem"

// =============================================================================
// Event System Types
// =============================================================================

// Event Types - All events that can be emitted in the system
EventType :: enum {
	App_Startup,
	App_Shutdown,
	Window_Resize,
	Window_File_Drop,

	// UI Layout Events
	Layout_Container_Ready, // Sent by Main Config to signal a slot is ready

	// Workspace Events
	Working_Directory_Changed, // Emitted when user selects a new working directory

	// Editor Events
	Request_Open_File, // Request to open a file (emitted by file tree, handled by buffer manager)
	Request_Editor_Attach, // Request for an editor plugin to attach to a container
	Request_Editor_Detach, // Request for an editor plugin to detach/cleanup (buffer closing)
	Buffer_Save,
	Cursor_Move,

	// Mouse Events
	Mouse_Down, // Mouse button pressed (provides element under mouse)
	Mouse_Up, // Mouse button released (provides element under mouse)
	Mouse_Move, // Mouse moved (provides movement delta)

	// Keyboard Events
	Key_Down, // Key pressed (provides key code and modifiers)
	Text_Input, // Text input (provides UTF-8 text)

	// Component Events
	Component_Tab_Changed, // Emitted when a tab is selected in a TabContainer

	// Custom/String based for loose coupling
	Custom_Signal,
}

// Event Payloads
EventPayload_Layout :: struct {
	container_id:  string, // The ID of the container ready to receive children
	target_plugin: string, // "builtin:filetree", "builtin:terminal", etc.
}

EventPayload_OpenFile :: struct {
	path: string, // The file path to open
}

EventPayload_EditorAttach :: struct {
	path:         string, // The file path being opened
	container_id: string, // The container ID where the editor should attach
}

EventPayload_EditorDetach :: struct {
	container_id: string, // The container ID of the editor being closed
}

EventPayload_File :: struct {
	path: string,
}

EventPayload_Custom :: struct {
	name: string,
	data: rawptr,
}

EventPayload_WorkingDirectory :: struct {
	path: string, // The new working directory path
}

// Mouse button enum for mouse events
MouseButton :: enum {
	Left,
	Middle,
	Right,
	X1, // Extra button 1
	X2, // Extra button 2
}

EventPayload_MouseDown :: struct {
	element_id: ElementID, // The element under the mouse (empty if none)
	button:     MouseButton, // Which button was pressed
	x:          f32, // Mouse x position in window coordinates
	y:          f32, // Mouse y position in window coordinates
}

EventPayload_MouseUp :: struct {
	element_id: ElementID, // The element under the mouse (empty if none)
	button:     MouseButton, // Which button was released
	x:          f32, // Mouse x position in window coordinates
	y:          f32, // Mouse y position in window coordinates
}

EventPayload_MouseMove :: struct {
	delta_x: f32, // Movement delta in x direction
	delta_y: f32, // Movement delta in y direction
	x:       f32, // Current mouse x position in window coordinates
	y:       f32, // Current mouse y position in window coordinates
}

EventPayload_WindowResize :: struct {
	width:  i32, // New window width in renderer/physical pixels (accounts for DPI)
	height: i32, // New window height in renderer/physical pixels (accounts for DPI)
}

EventPayload_KeyDown :: struct {
	key:       i32, // SDL keycode
	scancode:  i32, // SDL scancode
	modifiers: KeyModifier, // Modifier keys held
	repeat:    bool, // True if this is a key repeat event
}

EventPayload_TextInput :: struct {
	text: string, // UTF-8 encoded text input
}

// Event Payload Union - All possible payloads
EventPayload :: union {
	EventPayload_Layout,
	EventPayload_OpenFile,
	EventPayload_EditorAttach,
	EventPayload_EditorDetach,
	EventPayload_File,
	EventPayload_Custom,
	EventPayload_WorkingDirectory,
	EventPayload_TabChanged,
	EventPayload_MouseDown,
	EventPayload_MouseUp,
	EventPayload_MouseMove,
	EventPayload_WindowResize,
	EventPayload_KeyDown,
	EventPayload_TextInput,
}

// Event struct - Represents an event in the system
Event :: struct {
	type:    EventType,
	handled: bool, // If true, propagation stops
	payload: EventPayload,
}

// =============================================================================
// UI System Types
// =============================================================================

ElementID :: distinct string

ElementType :: enum {
	Container,
	Text,
	Image,
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
	hidden:          bool, // If true, this element and its children are not rendered
	// Position offset - allows shifting an element from its normal flow position
	// Useful for overlay elements like cursors that need precise pixel positioning
	offset_x:        f32, // Horizontal offset in pixels from normal position
	offset_y:        f32, // Vertical offset in pixels from normal position
}

// UINode - Represents a node in the UI DOM tree
UINode :: struct {
	id:           ElementID,
	type:         ElementType,
	parent:       ^UINode,
	children:     [dynamic]^UINode,
	style:        Style,

	// Content
	text_content: string, // If Type == Text
	image_path:   string, // If Type == Image (file path to image)

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
	TabContainer,
}

// =============================================================================
// High-Level Component Types
// =============================================================================

// ComponentID - Unique identifier for high-level components
// This is separate from ElementID (Clay/UINode IDs) and is auto-generated
ComponentID :: distinct u64

// Invalid component ID constant
INVALID_COMPONENT_ID :: ComponentID(0)

// TabInfo - Configuration for a single tab in a TabContainer
TabInfo :: struct {
	title:                string, // Display title for the tab
	content_container_id: string, // ElementID for the content container (plugins attach content here)
}

// Component event payload for tab changes
EventPayload_TabChanged :: struct {
	component_id: ComponentID, // The tab container component
	old_index:    int, // Previous active tab index (-1 if none)
	new_index:    int, // New active tab index
	tab_id:       string, // The content_container_id of the newly selected tab
}

// =============================================================================
// Plugin System Types
// =============================================================================

// Plugin Handle - Unique identifier for a plugin instance
PluginHandle :: distinct u64

// Forward declaration for PluginContext (defined in api.odin)
// We need this here because PluginVTable references it
PluginContext :: struct {
	plugin_id: string,
	user_data: rawptr,
	allocator: mem.Allocator,
	api:       ^VesslAPI, // The API VTable for calling system functions
}

// Plugin VTable - Every plugin must implement these procedures
PluginVTable :: struct {
	// Lifecycle
	init:     proc(ctx: ^PluginContext) -> bool,
	update:   proc(ctx: ^PluginContext, dt: f32),
	shutdown: proc(ctx: ^PluginContext),

	// Event Handling (Return true to consume event)
	on_event: proc(ctx: ^PluginContext, event: ^Event) -> bool,
}

// =============================================================================
// Keyboard Shortcut Types
// =============================================================================

// Keyboard modifier flags - Platform-specific for clarity
//
// Windows/Linux modifiers:
//   - Ctrl:  Control key (primary modifier for shortcuts like Ctrl+S)
//   - Alt:   Alt key
//   - Meta:  Windows key (rarely used in shortcuts)
//   - Shift: Shift key (shared across platforms)
//
// macOS modifiers:
//   - Cmd:     Command key (primary modifier for shortcuts like Cmd+S)
//   - Opt:     Option key (equivalent to Alt on other platforms)
//   - CtrlMac: Control key on Mac (rarely used, distinct from Cmd)
//   - Shift:   Shift key (shared across platforms)
KeyModifierFlag :: enum {
	// Windows/Linux modifiers
	Ctrl, // Control key on Windows/Linux
	Alt, // Alt key on Windows/Linux
	Meta, // Windows key on Windows/Linux

	// macOS modifiers
	Cmd, // Command key on macOS (⌘)
	Opt, // Option key on macOS (⌥)
	CtrlMac, // Control key on macOS (⌃)

	// Shared
	Shift, // Shift key (all platforms)
}

// Bit set of modifier flags for combining modifiers
KeyModifier :: bit_set[KeyModifierFlag]

// =============================================================================
// VesslAPI - The main API interface for plugins
// =============================================================================

// VesslAPI - VTable containing all system functions available to plugins
// Plugins receive a pointer to this struct in their PluginContext
VesslAPI :: struct {
	// Event System
	emit_event:               proc(
		ctx: ^PluginContext,
		type: EventType,
		payload: EventPayload,
	) -> (
		^Event,
		bool,
	),
	dispatch_event:           proc(ctx: ^PluginContext, event: ^Event) -> bool,

	// UI System
	set_root_node:            proc(ctx: ^PluginContext, root: ^UINode),
	find_node_by_id:          proc(ctx: ^PluginContext, id: ElementID) -> ^UINode,
	attach_to_container:      proc(
		ctx: ^PluginContext,
		container_id: string,
		node: ^UINode,
	) -> bool,
	request_redraw:           proc(ctx: ^PluginContext), // Request a UI redraw (thread-safe)

	// High-Level Components - Tab Container
	create_tab_container:     proc(
		ctx: ^PluginContext,
		parent_id: ElementID,
		tabs: []TabInfo,
	) -> ComponentID,
	tab_container_select_tab: proc(ctx: ^PluginContext, id: ComponentID, index: int) -> bool,
	tab_container_add_tab:    proc(ctx: ^PluginContext, id: ComponentID, tab: TabInfo) -> bool,
	tab_container_remove_tab: proc(ctx: ^PluginContext, id: ComponentID, index: int) -> bool,
	tab_container_get_active: proc(ctx: ^PluginContext, id: ComponentID) -> int,

	// Keyboard Shortcuts
	register_shortcut:        proc(
		ctx: ^PluginContext,
		key: i32,
		modifiers: KeyModifier,
		event_name: string,
	) -> bool,
	unregister_shortcuts:     proc(ctx: ^PluginContext),

	// Platform Features
	show_folder_dialog:       proc(ctx: ^PluginContext, default_location: string),

	// Window Information
	get_window_size:          proc(ctx: ^PluginContext) -> (width: i32, height: i32),

	// Text Measurement
	measure_text:             proc(ctx: ^PluginContext, text: string) -> (width: f32, height: f32),

	// Scroll Position
	get_scroll_position:      proc(ctx: ^PluginContext, element_id: ElementID) -> (x: f32, y: f32),
	set_scroll_position:      proc(ctx: ^PluginContext, element_id: ElementID, x: f32, y: f32),

	// Element Bounds
	get_element_bounds:       proc(
		ctx: ^PluginContext,
		element_id: ElementID,
	) -> (
		x: f32,
		y: f32,
		width: f32,
		height: f32,
		found: bool,
	),

	// Internal pointers (opaque to plugins, used by API implementation)
	_internal:                rawptr,
}
