package main

import api "api"
import "core"
import "core:mem"
import "ui"

// Internal context for VesslAPI implementation
// This holds references to all internal systems needed by the API
APIInternalContext :: struct {
	eventbus:          ^core.EventBus,
	plugin_registry:   ^core.PluginRegistry,
	shortcut_registry: ^core.ShortcutRegistry,
	ui_api:            ^ui.UIPluginAPI,
	platform_api:      ^ui.PlatformAPI,
	allocator:         mem.Allocator,
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
	allocator := context.allocator,
) -> ^api.VesslAPI {
	// Create internal context
	g_api_internal = new(APIInternalContext, allocator)
	g_api_internal.eventbus = eventbus
	g_api_internal.plugin_registry = plugin_registry
	g_api_internal.shortcut_registry = shortcut_registry
	g_api_internal.ui_api = ui_api
	g_api_internal.platform_api = platform_api
	g_api_internal.allocator = allocator

	// Set up the VTable
	g_vessl_api = api.VesslAPI {
		// Event System
		emit_event              = api_emit_event,
		dispatch_event          = api_dispatch_event,

		// UI System
		set_root_node           = api_set_root_node,
		find_node_by_id         = api_find_node_by_id,
		attach_to_container     = api_attach_to_container,

		// Keyboard Shortcuts
		register_shortcut       = api_register_shortcut,
		unregister_shortcuts    = api_unregister_shortcuts,

		// Platform Features
		show_folder_dialog      = api_show_folder_dialog,

		// Internal pointer
		_internal               = g_api_internal,
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
api_emit_event :: proc(ctx: ^api.PluginContext, type: api.EventType, payload: api.EventPayload) -> (^api.Event, bool) {
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
api_attach_to_container :: proc(ctx: ^api.PluginContext, container_id: string, node: ^api.UINode) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.ui_api == nil do return false

	return ui.attach_to_container(internal.ui_api, container_id, node)
}

// Register a keyboard shortcut
api_register_shortcut :: proc(ctx: ^api.PluginContext, key: i32, modifiers: api.KeyModifier, event_name: string) -> bool {
	internal := cast(^APIInternalContext)ctx.api._internal
	if internal == nil || internal.shortcut_registry == nil do return false

	return core.register_shortcut(internal.shortcut_registry, key, modifiers, event_name, ctx.plugin_id)
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

