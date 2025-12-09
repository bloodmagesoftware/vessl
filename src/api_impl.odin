package main

import api "api"
import "core"
import "core:mem"
import "core:sync"
import "ui"

// Internal context for VesslAPI implementation
// This holds references to all internal systems needed by the API
APIInternalContext :: struct {
	eventbus:              ^core.EventBus,
	plugin_registry:       ^core.PluginRegistry,
	shortcut_registry:     ^core.ShortcutRegistry,
	ui_api:                ^ui.UIPluginAPI,
	platform_api:          ^ui.PlatformAPI,
	component_registry:    ^ui.ComponentRegistry,
	window_ctx:            ^core.WindowContext,
	allocator:             mem.Allocator,
	// Render state for request_redraw (thread-safe access)
	render_required:       ^bool,
	render_required_mutex: ^sync.Mutex,
}

// Global API instance (single instance for the application)
@(private)
g_api_internal: ^APIInternalContext = nil

@(private)
g_vessl_api: api.VesslAPI

// Initialize the VesslAPI instance
// This should be called once during application startup
init_vessl_api :: proc(
	eventbus: ^core.EventBus,
	plugin_registry: ^core.PluginRegistry,
	shortcut_registry: ^core.ShortcutRegistry,
	ui_api: ^ui.UIPluginAPI,
	platform_api: ^ui.PlatformAPI,
	component_registry: ^ui.ComponentRegistry,
	window_ctx: ^core.WindowContext,
	render_required: ^bool,
	render_required_mutex: ^sync.Mutex,
	allocator := context.allocator,
) -> ^api.VesslAPI {
	// Create internal context
	g_api_internal = new(APIInternalContext, allocator)
	g_api_internal.eventbus = eventbus
	g_api_internal.plugin_registry = plugin_registry
	g_api_internal.shortcut_registry = shortcut_registry
	g_api_internal.ui_api = ui_api
	g_api_internal.platform_api = platform_api
	g_api_internal.component_registry = component_registry
	g_api_internal.window_ctx = window_ctx
	g_api_internal.render_required = render_required
	g_api_internal.render_required_mutex = render_required_mutex
	g_api_internal.allocator = allocator

	// Set up the VTable
	g_vessl_api = api.VesslAPI {
		// Event System
		emit_event               = api_emit_event,
		dispatch_event           = api_dispatch_event,

		// UI System
		set_root_node            = api_set_root_node,
		find_node_by_id          = api_find_node_by_id,
		attach_to_container      = api_attach_to_container,
		request_redraw           = api_request_redraw,

		// High-Level Components - Tab Container
		create_tab_container     = api_create_tab_container,
		tab_container_select_tab = api_tab_container_select_tab,
		tab_container_add_tab    = api_tab_container_add_tab,
		tab_container_remove_tab = api_tab_container_remove_tab,
		tab_container_get_active = api_tab_container_get_active,

		// Keyboard Shortcuts
		register_shortcut        = api_register_shortcut,
		unregister_shortcuts     = api_unregister_shortcuts,

		// Platform Features
		show_folder_dialog       = api_show_folder_dialog,

		// Window Information
		get_window_size          = api_get_window_size,

		// Text Measurement
		measure_text             = api_measure_text,

		// Scroll Position
		get_scroll_position      = api_get_scroll_position,

		// Internal pointer
		_internal                = g_api_internal,
	}

	return &g_vessl_api
}

// Destroy the VesslAPI instance
destroy_vessl_api :: proc() {
	if g_api_internal != nil {
		free(g_api_internal)
		g_api_internal = nil
	}
}

// =============================================================================
// API Implementation Functions
// =============================================================================

// Emit an event
api_emit_event :: proc(
	ctx: ^api.PluginContext,
	type: api.EventType,
	payload: api.EventPayload,
) -> (
	^api.Event,
	bool,
) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.eventbus == nil do return nil, false

	return core.emit_event_typed(internal.eventbus, type, payload)
}

// Dispatch an event to all plugins
api_dispatch_event :: proc(ctx: ^api.PluginContext, event: ^api.Event) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.plugin_registry == nil do return false

	return core.dispatch_event_to_plugins(internal.plugin_registry, event)
}

// Set the root node for rendering
api_set_root_node :: proc(ctx: ^api.PluginContext, root: ^api.UINode) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.ui_api == nil do return

	ui.set_root_node_api(internal.ui_api, root)
}

// Find a node by ID
api_find_node_by_id :: proc(ctx: ^api.PluginContext, id: api.ElementID) -> ^api.UINode {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.ui_api == nil do return nil

	return ui.find_node_by_id(internal.ui_api, id)
}

// Attach a node to a container
api_attach_to_container :: proc(
	ctx: ^api.PluginContext,
	container_id: string,
	node: ^api.UINode,
) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.ui_api == nil do return false

	return ui.attach_to_container(internal.ui_api, container_id, node)
}

// Request a UI redraw on the next frame
// This is thread-safe and can be called from any thread
api_request_redraw :: proc(ctx: ^api.PluginContext) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil do return
	if internal.render_required == nil || internal.render_required_mutex == nil do return

	sync.mutex_lock(internal.render_required_mutex)
	internal.render_required^ = true
	sync.mutex_unlock(internal.render_required_mutex)
}

// Register a keyboard shortcut
api_register_shortcut :: proc(
	ctx: ^api.PluginContext,
	key: i32,
	modifiers: api.KeyModifier,
	event_name: string,
) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.shortcut_registry == nil do return false

	return core.register_shortcut(
		internal.shortcut_registry,
		key,
		modifiers,
		event_name,
		ctx.plugin_id,
	)
}

// Unregister all shortcuts for this plugin
api_unregister_shortcuts :: proc(ctx: ^api.PluginContext) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.shortcut_registry == nil do return

	core.unregister_shortcuts(internal.shortcut_registry, ctx.plugin_id)
}

// Show folder dialog
api_show_folder_dialog :: proc(ctx: ^api.PluginContext, default_location: string) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.platform_api == nil do return

	ui.show_folder_dialog(internal.platform_api, default_location)
}

// Get window size in renderer/physical pixels (accounts for DPI scaling)
// This matches the UI coordinate system used by Clay and mouse events
api_get_window_size :: proc(ctx: ^api.PluginContext) -> (width: i32, height: i32) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.window_ctx == nil do return 0, 0

	return core.get_renderer_output_size(internal.window_ctx)
}

// Measure text dimensions using the current font
api_measure_text :: proc(ctx: ^api.PluginContext, text: string) -> (width: f32, height: f32) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.ui_api == nil do return 0, 0

	return ui.measure_text(internal.ui_api, text)
}

// Get scroll position for a scrollable container
api_get_scroll_position :: proc(
	ctx: ^api.PluginContext,
	element_id: api.ElementID,
) -> (
	x: f32,
	y: f32,
) {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.ui_api == nil do return 0, 0

	return ui.get_scroll_position(internal.ui_api, element_id)
}

// =============================================================================
// High-Level Component API Implementation
// =============================================================================

// Create a tab container
api_create_tab_container :: proc(
	ctx: ^api.PluginContext,
	parent_id: api.ElementID,
	tabs: []api.TabInfo,
) -> api.ComponentID {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.component_registry == nil do return api.INVALID_COMPONENT_ID

	return ui.create_tab_container(internal.component_registry, ctx, parent_id, tabs)
}

// Select a tab in a tab container
api_tab_container_select_tab :: proc(
	ctx: ^api.PluginContext,
	id: api.ComponentID,
	index: int,
) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.component_registry == nil do return false

	return ui.tab_container_select_tab(internal.component_registry, id, index)
}

// Add a tab to a tab container
api_tab_container_add_tab :: proc(
	ctx: ^api.PluginContext,
	id: api.ComponentID,
	tab: api.TabInfo,
) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.component_registry == nil do return false

	return ui.tab_container_add_tab(internal.component_registry, id, tab)
}

// Remove a tab from a tab container
api_tab_container_remove_tab :: proc(
	ctx: ^api.PluginContext,
	id: api.ComponentID,
	index: int,
) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.component_registry == nil do return false

	return ui.tab_container_remove_tab(internal.component_registry, id, index)
}

// Get the active tab index
api_tab_container_get_active :: proc(ctx: ^api.PluginContext, id: api.ComponentID) -> int {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.component_registry == nil do return -1

	return ui.tab_container_get_active(internal.component_registry, id)
}
