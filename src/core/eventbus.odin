package core

import api "../api"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

// Re-export types from api for internal use
// This allows internal code to use core.Event, core.EventType, etc.
Event :: api.Event
EventType :: api.EventType
EventPayload :: api.EventPayload
EventPayload_Layout :: api.EventPayload_Layout
EventPayload_Buffer :: api.EventPayload_Buffer
EventPayload_File :: api.EventPayload_File
EventPayload_Custom :: api.EventPayload_Custom
EventPayload_WorkingDirectory :: api.EventPayload_WorkingDirectory

// Event subscriber callback
// Returns true if the event was handled (stops propagation)
EventSubscriber :: proc(event: ^Event) -> bool

// Subscriber entry
SubscriberEntry :: struct {
	plugin_id: string,
	handler:   EventSubscriber,
}

// EventBus - The nervous system of the IDE
EventBus :: struct {
	subscribers:   [dynamic]SubscriberEntry,
	mutex:         sync.Mutex, // Thread safety for subscription/unsubscription
	arena:         mem.Arena, // Arena allocator for events (short-lived)
	arena_backing: []u8, // Backing memory for arena
}

// Initialize EventBus
init_eventbus :: proc(allocator := context.allocator) -> ^EventBus {
	bus := new(EventBus, allocator)
	bus.subscribers = {}
	bus.mutex = {}

	// Initialize arena with 64KB for event allocations
	arena_size := 64 * 1024
	bus.arena_backing = make([]u8, arena_size, allocator)
	mem.arena_init(&bus.arena, bus.arena_backing)

	return bus
}

// Destroy EventBus
destroy_eventbus :: proc(bus: ^EventBus) {
	if bus == nil do return

	// Cleanup subscribers
	delete(bus.subscribers)

	// Cleanup arena backing
	delete(bus.arena_backing)

	free(bus)
}

// Subscribe to events
subscribe :: proc(
	bus: ^EventBus,
	plugin_id: string,
	handler: EventSubscriber,
	allocator := context.allocator,
) {
	if bus == nil do return

	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)

	// Clone plugin_id string to ensure it persists
	plugin_id_clone := strings.clone(plugin_id, allocator)

	entry := SubscriberEntry {
		plugin_id = plugin_id_clone,
		handler   = handler,
	}

	append(&bus.subscribers, entry)
}

// Unsubscribe from events
unsubscribe :: proc(bus: ^EventBus, plugin_id: string) {
	if bus == nil do return

	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)

	// Find and remove subscriber
	for entry, i in bus.subscribers {
		if entry.plugin_id == plugin_id {
			// Free the cloned string
			delete(entry.plugin_id)
			ordered_remove(&bus.subscribers, i)
			return
		}
	}
}

// Emit an event to all subscribers
// Returns true if the event was handled by any subscriber
emit_event :: proc(bus: ^EventBus, event: ^Event) -> bool {
	if bus == nil || event == nil do return false

	// Reset handled flag
	event.handled = false

	// Lock for reading subscribers list
	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)

	// Propagate to all subscribers until handled
	for entry in bus.subscribers {
		if entry.handler(event) {
			event.handled = true
			return true
		}

		// If event was marked as handled, stop propagation
		if event.handled {
			return true
		}
	}

	return false
}

// Helper to create and emit an event (uses arena allocator)
emit_event_typed :: proc(
	bus: ^EventBus,
	type: EventType,
	payload: EventPayload,
) -> (
	^Event,
	bool,
) {
	if bus == nil do return nil, false

	// Allocate event from arena
	arena_allocator := mem.arena_allocator(&bus.arena)
	event := new(Event, arena_allocator)
	if event == nil do return nil, false

	event.type = type
	event.handled = false
	event.payload = payload

	handled := emit_event(bus, event)
	return event, handled
}

// =============================================================================
// Keyboard Shortcut Registry
// =============================================================================

// Re-export keyboard types from api
KeyModifierFlag :: api.KeyModifierFlag
KeyModifier :: api.KeyModifier

// A registered keyboard shortcut
KeyboardShortcut :: struct {
	key:        i32, // SDL keycode (e.g., sdl.K_O for 'O')
	modifiers:  KeyModifier, // Required modifier keys
	event_name: string, // Event to trigger when shortcut is pressed
	plugin_id:  string, // Plugin that registered this shortcut (for debugging/conflicts)
}

// Registry for keyboard shortcuts
ShortcutRegistry :: struct {
	shortcuts: [dynamic]KeyboardShortcut,
	mutex:     sync.Mutex,
	allocator: mem.Allocator,
}

// Initialize a new shortcut registry
init_shortcut_registry :: proc(allocator := context.allocator) -> ^ShortcutRegistry {
	registry := new(ShortcutRegistry, allocator)
	registry.shortcuts = {}
	registry.mutex = {}
	registry.allocator = allocator
	return registry
}

// Destroy the shortcut registry and free all resources
destroy_shortcut_registry :: proc(registry: ^ShortcutRegistry) {
	if registry == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Free all cloned strings
	for shortcut in registry.shortcuts {
		delete(shortcut.event_name)
		delete(shortcut.plugin_id)
	}

	delete(registry.shortcuts)
	free(registry)
}

// Register a keyboard shortcut
// Parameters:
//   - registry: The shortcut registry
//   - key: SDL keycode (e.g., sdl.K_O for the 'O' key)
//   - modifiers: Modifier keys required (e.g., {.Ctrl} or {.Meta})
//   - event_name: Name of the event to emit when shortcut is triggered
//   - plugin_id: ID of the plugin registering the shortcut
// Returns: true if registration succeeded, false if shortcut already exists
register_shortcut :: proc(
	registry: ^ShortcutRegistry,
	key: i32,
	modifiers: KeyModifier,
	event_name: string,
	plugin_id: string,
) -> bool {
	if registry == nil do return false

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Check for existing shortcut with same key combination
	for shortcut in registry.shortcuts {
		if shortcut.key == key && shortcut.modifiers == modifiers {
			fmt.eprintf(
				"[ShortcutRegistry] Warning: Shortcut already registered by '%s' for event '%s'\n",
				shortcut.plugin_id,
				shortcut.event_name,
			)
			return false
		}
	}

	// Clone strings for persistence
	shortcut := KeyboardShortcut {
		key        = key,
		modifiers  = modifiers,
		event_name = strings.clone(event_name, registry.allocator),
		plugin_id  = strings.clone(plugin_id, registry.allocator),
	}

	append(&registry.shortcuts, shortcut)
	fmt.printf(
		"[ShortcutRegistry] Registered shortcut: %s -> '%s' (by %s)\n",
		format_shortcut(key, modifiers),
		event_name,
		plugin_id,
	)

	return true
}

// Unregister all shortcuts for a specific plugin
unregister_shortcuts :: proc(registry: ^ShortcutRegistry, plugin_id: string) {
	if registry == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Remove shortcuts in reverse order to avoid index issues
	for i := len(registry.shortcuts) - 1; i >= 0; i -= 1 {
		if registry.shortcuts[i].plugin_id == plugin_id {
			// Free cloned strings
			delete(registry.shortcuts[i].event_name)
			delete(registry.shortcuts[i].plugin_id)
			ordered_remove(&registry.shortcuts, i)
		}
	}
}

// Find a shortcut matching the given key and modifiers
// Returns: (event_name, found) - event_name is the event to trigger, found indicates if a match was found
find_shortcut :: proc(
	registry: ^ShortcutRegistry,
	key: i32,
	modifiers: KeyModifier,
) -> (
	string,
	bool,
) {
	if registry == nil do return "", false

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	for shortcut in registry.shortcuts {
		if shortcut.key == key && shortcut.modifiers == modifiers {
			return shortcut.event_name, true
		}
	}

	return "", false
}

// Helper to format a shortcut for display (e.g., "Ctrl+O", "Cmd+Shift+S")
format_shortcut :: proc(key: i32, modifiers: KeyModifier) -> string {
	builder := strings.builder_make()

	// Windows/Linux modifiers
	if .Ctrl in modifiers {
		strings.write_string(&builder, "Ctrl+")
	}
	if .Alt in modifiers {
		strings.write_string(&builder, "Alt+")
	}
	if .Meta in modifiers {
		strings.write_string(&builder, "Meta+")
	}

	// macOS modifiers
	if .Cmd in modifiers {
		strings.write_string(&builder, "Cmd+")
	}
	if .Opt in modifiers {
		strings.write_string(&builder, "Opt+")
	}
	if .CtrlMac in modifiers {
		strings.write_string(&builder, "CtrlMac+")
	}

	// Shared
	if .Shift in modifiers {
		strings.write_string(&builder, "Shift+")
	}

	// Convert keycode to character (simple version for printable chars)
	if key >= 'A' && key <= 'Z' {
		strings.write_byte(&builder, u8(key))
	} else if key >= 'a' && key <= 'z' {
		strings.write_byte(&builder, u8(key - 32)) // Convert to uppercase
	} else {
		strings.write_string(&builder, fmt.tprintf("0x%X", key))
	}

	return strings.to_string(builder)
}
