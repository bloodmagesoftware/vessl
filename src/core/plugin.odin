package core

import api "../api"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

// Re-export types from api for internal use
PluginHandle :: api.PluginHandle
PluginVTable :: api.PluginVTable
PluginContext :: api.PluginContext

// Plugin struct - Internal representation of a plugin
Plugin :: struct {
	id:         string,
	vtable:     PluginVTable,
	priority:   int, // Higher value = earlier execution in event dispatch
	user_data:  rawptr,
	handle:     PluginHandle,
	plugin_ctx: PluginContext, // The context passed to plugin procedures
}

// Plugin Registry
PluginRegistry :: struct {
	plugins:     [dynamic]^Plugin, // Sorted by priority (descending: high to low)
	next_handle: u64,
	mutex:       sync.Mutex,
	allocator:   mem.Allocator,
}

// Initialize Plugin Registry
init_plugin_registry :: proc(allocator := context.allocator) -> ^PluginRegistry {
	registry := new(PluginRegistry, allocator)
	registry.plugins = make([dynamic]^Plugin, 0, 16, allocator) // Pre-allocate for ~16 plugins
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
	for plugin in registry.plugins {
		if plugin.vtable.shutdown != nil {
			plugin.vtable.shutdown(&plugin.plugin_ctx)
		}

		// Free plugin ID string
		delete(plugin.id)

		// Free plugin itself
		free(plugin)
	}

	// Clear array
	delete(registry.plugins)

	free(registry)
}

// Register a plugin with priority-based insertion
// Higher priority plugins are placed earlier in the array for faster event dispatch
register_plugin :: proc(registry: ^PluginRegistry, plugin: ^Plugin) -> PluginHandle {
	if registry == nil || plugin == nil do return 0

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Check for duplicate plugin ID
	for existing in registry.plugins {
		if existing.id == plugin.id {
			fmt.eprintf("Plugin '%s' is already registered\n", plugin.id)
			return 0
		}
	}

	// Assign handle
	plugin.handle = PluginHandle(registry.next_handle)
	registry.next_handle += 1

	// Clone plugin ID
	plugin.id = strings.clone(plugin.id, registry.allocator)

	// Find insertion index to maintain descending priority order (high to low)
	insert_idx := len(registry.plugins) // Default: append at end
	for p, i in registry.plugins {
		if plugin.priority > p.priority {
			insert_idx = i
			break
		}
	}

	// Insert at the correct position
	inject_at(&registry.plugins, insert_idx, plugin)

	return plugin.handle
}

// Get plugin by ID (linear search - acceptable for initialization/rare lookups)
get_plugin :: proc(registry: ^PluginRegistry, id: string) -> ^Plugin {
	if registry == nil do return nil

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	for plugin in registry.plugins {
		if plugin.id == id {
			return plugin
		}
	}
	return nil
}

// Update all plugins
update_plugins :: proc(registry: ^PluginRegistry, dt: f32) {
	if registry == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Update all plugins (in priority order)
	for plugin in registry.plugins {
		if plugin.vtable.update != nil {
			plugin.vtable.update(&plugin.plugin_ctx, dt)
		}
	}
}

// Initialize a plugin (call after registration)
// vessl_api is the VesslAPI pointer that will be passed to the plugin
init_plugin :: proc(
	registry: ^PluginRegistry,
	plugin_id: string,
	vessl_api: ^api.VesslAPI,
) -> bool {
	if registry == nil do return false

	plugin := get_plugin(registry, plugin_id)
	if plugin == nil {
		fmt.eprintf("Plugin '%s' not found in registry\n", plugin_id)
		return false
	}

	// Set up plugin context
	plugin.plugin_ctx.plugin_id = plugin_id
	plugin.plugin_ctx.allocator = registry.allocator
	plugin.plugin_ctx.api = vessl_api

	// Call init
	if plugin.vtable.init != nil {
		return plugin.vtable.init(&plugin.plugin_ctx)
	}

	return true
}

// Dispatch event to all plugins in priority order (high to low)
// NOTE: We copy the plugin list to avoid deadlock if a plugin's event handler
// tries to dispatch another event (which would try to lock the same mutex)
dispatch_event_to_plugins :: proc(registry: ^PluginRegistry, event: ^Event) -> bool {
	if registry == nil || event == nil do return false

	// Lock mutex to copy plugin list
	sync.mutex_lock(&registry.mutex)

	// Copy plugin list to avoid holding lock during handler execution
	// The array is already sorted by priority (descending)
	plugins_copy: [dynamic]^Plugin
	plugins_copy = {}
	for plugin in registry.plugins {
		append(&plugins_copy, plugin)
	}

	sync.mutex_unlock(&registry.mutex)
	defer delete(plugins_copy)

	// Dispatch to all plugins in priority order (without holding the lock)
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
