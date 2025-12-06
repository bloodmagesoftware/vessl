package core

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

// Plugin Handle
PluginHandle :: distinct u64

// Plugin VTable - Every plugin must implement these procedures
PluginVTable :: struct {
	// Lifecycle
	init:     proc(ctx: ^PluginContext) -> bool,
	update:   proc(ctx: ^PluginContext, dt: f32),
	shutdown: proc(ctx: ^PluginContext),

	// Event Handling (Return true to consume event)
	on_event: proc(ctx: ^PluginContext, event: ^Event) -> bool,
}

// Plugin Context - Passed to all plugin procedures
// Note: ui_api is rawptr to avoid circular dependency with ui package
PluginContext :: struct {
	eventbus:        ^EventBus,
	plugin_id:       string,
	user_data:       rawptr,
	allocator:       mem.Allocator,
	ui_api:          rawptr, // ^UIPluginAPI from ui package (cast when needed)
	plugin_registry: rawptr, // ^PluginRegistry (cast when needed) - allows plugins to dispatch events
	ctx:             rawptr, // Reserved field (context is a keyword)
}

// Plugin struct
Plugin :: struct {
	id:         string,
	vtable:     PluginVTable,
	user_data:  rawptr,
	handle:     PluginHandle,
	plugin_ctx: PluginContext, // Renamed from 'context' because 'context' is a keyword
}

// Plugin Registry
PluginRegistry :: struct {
	plugins:     map[string]^Plugin, // Map from plugin ID to Plugin
	next_handle: u64,
	mutex:       sync.Mutex,
	allocator:   mem.Allocator,
}

// Initialize Plugin Registry
init_plugin_registry :: proc(allocator := context.allocator) -> ^PluginRegistry {
	registry := new(PluginRegistry, allocator)
	registry.plugins = {}
	registry.next_handle = 1
	registry.mutex = {}
	registry.allocator = allocator

	return registry
}

// Destroy Plugin Registry
destroy_plugin_registry :: proc(registry: ^PluginRegistry) {
	if registry == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Shutdown all plugins first
	for _, plugin in registry.plugins {
		if plugin.vtable.shutdown != nil {
			plugin.vtable.shutdown(&plugin.plugin_ctx)
		}

		// Free plugin ID string
		delete(plugin.id)

		// Free plugin itself
		free(plugin)
	}

	// Clear map
	delete(registry.plugins)

	free(registry)
}

// Register a plugin
register_plugin :: proc(registry: ^PluginRegistry, plugin: ^Plugin) -> PluginHandle {
	if registry == nil || plugin == nil do return 0

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Assign handle
	plugin.handle = PluginHandle(registry.next_handle)
	registry.next_handle += 1

	// Clone plugin ID
	plugin.id = strings.clone(plugin.id, registry.allocator)

	// Store in map
	registry.plugins[plugin.id] = plugin

	return plugin.handle
}

// Get plugin by ID
get_plugin :: proc(registry: ^PluginRegistry, id: string) -> ^Plugin {
	if registry == nil do return nil

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	return registry.plugins[id]
}

// Update all plugins
update_plugins :: proc(registry: ^PluginRegistry, dt: f32) {
	if registry == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Update all plugins
	for _, plugin in registry.plugins {
		if plugin.vtable.update != nil {
			plugin.vtable.update(&plugin.plugin_ctx, dt)
		}
	}
}

// Initialize a plugin (call after registration)
// ui_api_ptr is rawptr to avoid circular dependency
init_plugin :: proc(
	registry: ^PluginRegistry,
	plugin_id: string,
	eventbus: ^EventBus,
	ui_api_ptr: rawptr,
) -> bool {
	if registry == nil do return false

	plugin := get_plugin(registry, plugin_id)
	if plugin == nil {
		fmt.eprintf("Plugin '%s' not found in registry\n", plugin_id)
		return false
	}

	// Set up plugin context
	plugin.plugin_ctx.eventbus = eventbus
	plugin.plugin_ctx.plugin_id = plugin_id
	plugin.plugin_ctx.allocator = registry.allocator
	plugin.plugin_ctx.ui_api = ui_api_ptr
	plugin.plugin_ctx.plugin_registry = cast(rawptr)registry

	// Call init
	if plugin.vtable.init != nil {
		return plugin.vtable.init(&plugin.plugin_ctx)
	}

	return true
}

// Dispatch event to all plugins
// This is an alternative to the eventbus subscription system
// that avoids closure capture issues
// NOTE: We copy the plugin list to avoid deadlock if a plugin's event handler
// tries to dispatch another event (which would try to lock the same mutex)
dispatch_event_to_plugins :: proc(registry: ^PluginRegistry, event: ^Event) -> bool {
	if registry == nil || event == nil do return false

	// Lock mutex to copy plugin list
	sync.mutex_lock(&registry.mutex)

	// Copy plugin list to avoid holding lock during handler execution
	plugins_copy: [dynamic]^Plugin
	plugins_copy = {}
	for plugin_id, plugin in registry.plugins {
		append(&plugins_copy, plugin)
	}

	sync.mutex_unlock(&registry.mutex)
	defer delete(plugins_copy)

	// Dispatch to all plugins (without holding the lock)
	for plugin in plugins_copy {
		if plugin.vtable.on_event != nil {
			// Call the plugin's event handler (mutex is unlocked, so no deadlock)
			if plugin.vtable.on_event(&plugin.plugin_ctx, event) {
				event.handled = true
				return true
			}
		}

		// If event was marked as handled, stop propagation
		if event.handled {
			return true
		}
	}

	return false
}
