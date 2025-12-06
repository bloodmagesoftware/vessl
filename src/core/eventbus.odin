package core

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

// Event Types
EventType :: enum {
	App_Startup,
	App_Shutdown,
	Window_Resize,
	Window_File_Drop,

	// UI Layout Events
	Layout_Container_Ready, // Sent by Main Config to signal a slot is ready

	// Editor Events
	Buffer_Open,
	Buffer_Save,
	Cursor_Move,

	// Custom/String based for loose coupling
	Custom_Signal,
}

// Event Payloads
EventPayload_Layout :: struct {
	container_id:  string, // The ID of the container ready to receive children
	target_plugin: string, // "builtin:filetree", "builtin:terminal", etc.
}

EventPayload_Buffer :: struct {
	file_path: string,
	buffer_id: string,
}

EventPayload_File :: struct {
	path: string,
}

EventPayload_Custom :: struct {
	name: string,
	data: rawptr,
}

// Event struct
Event :: struct {
	type:    EventType,
	handled: bool, // If true, propagation stops
	payload: union {
		EventPayload_Layout,
		EventPayload_Buffer,
		EventPayload_File,
		EventPayload_Custom,
	},
}

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
emit_event_typed :: proc(bus: ^EventBus, type: EventType, payload: union {
		EventPayload_Layout,
		EventPayload_Buffer,
		EventPayload_File,
		EventPayload_Custom,
	}) -> (^Event, bool) {
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
