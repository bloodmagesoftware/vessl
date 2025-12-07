package ui

import api "../api"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

// =============================================================================
// Component Registry
// =============================================================================

// ComponentRegistry manages all high-level components
// Thread-safe via mutex for concurrent access
ComponentRegistry :: struct {
	components: map[api.ComponentID]^Component,
	next_id:    u64, // Atomic counter for generating unique IDs
	mutex:      sync.Mutex,
	allocator:  mem.Allocator,
	ui_api:     ^UIPluginAPI, // Reference to UI API for node manipulation
}

// Component types
ComponentKind :: enum {
	TabContainer,
	// Future: Checkbox, TextBox, TextArea, etc.
}

// Base component structure
Component :: struct {
	id:        api.ComponentID,
	kind:      ComponentKind,
	parent_id: api.ElementID, // The parent container this component is attached to
	root_node: ^api.UINode, // The root UINode of this component
	state:     rawptr, // Type-specific state (cast based on kind)
}

// =============================================================================
// Tab Container State
// =============================================================================

// TabState holds information about a single tab
TabState :: struct {
	title:             string,
	content_id:        string, // The content container ID (for plugins to attach to)
	tab_button_node:   ^api.UINode, // The clickable tab button
	content_container: ^api.UINode, // The content container
}

// TabContainerState holds the state for a tab container component
TabContainerState :: struct {
	tabs:         [dynamic]TabState,
	active_index: int, // Currently active tab index (-1 for none)
	tab_bar:      ^api.UINode, // The horizontal tab bar container
	content_area: ^api.UINode, // Container holding all content containers
	registry:     ^ComponentRegistry, // Back-reference for callbacks
	component_id: api.ComponentID, // Self-reference for event emission
	plugin_ctx:   ^api.PluginContext, // Plugin context for emitting events
	allocator:    mem.Allocator,
}

// Callback context for tab clicks
TabClickContext :: struct {
	state:     ^TabContainerState,
	tab_index: int,
}

// =============================================================================
// Component Registry Functions
// =============================================================================

// Initialize a new component registry
init_component_registry :: proc(
	ui_api: ^UIPluginAPI,
	allocator := context.allocator,
) -> ^ComponentRegistry {
	registry := new(ComponentRegistry, allocator)
	registry.components = make(map[api.ComponentID]^Component, allocator = allocator)
	registry.next_id = 1 // Start at 1, 0 is INVALID_COMPONENT_ID
	registry.allocator = allocator
	registry.ui_api = ui_api
	return registry
}

// Destroy the component registry and all components
destroy_component_registry :: proc(registry: ^ComponentRegistry) {
	if registry == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	// Clean up all components
	for id, component in registry.components {
		destroy_component(component, registry.allocator)
	}
	delete(registry.components)

	free(registry, registry.allocator)
}

// Generate a new unique component ID (thread-safe)
generate_component_id :: proc(registry: ^ComponentRegistry) -> api.ComponentID {
	if registry == nil do return api.INVALID_COMPONENT_ID

	// Use atomic add for thread-safe ID generation
	new_id := sync.atomic_add(&registry.next_id, 1)
	return api.ComponentID(new_id)
}

// Get a component by ID (thread-safe)
get_component :: proc(registry: ^ComponentRegistry, id: api.ComponentID) -> ^Component {
	if registry == nil || id == api.INVALID_COMPONENT_ID do return nil

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	return registry.components[id]
}

// Register a component (thread-safe)
register_component :: proc(registry: ^ComponentRegistry, component: ^Component) {
	if registry == nil || component == nil do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	registry.components[component.id] = component
}

// Unregister and destroy a component (thread-safe)
unregister_component :: proc(registry: ^ComponentRegistry, id: api.ComponentID) {
	if registry == nil || id == api.INVALID_COMPONENT_ID do return

	sync.mutex_lock(&registry.mutex)
	defer sync.mutex_unlock(&registry.mutex)

	if component, ok := registry.components[id]; ok {
		destroy_component(component, registry.allocator)
		delete_key(&registry.components, id)
	}
}

// Destroy a component and free its resources
destroy_component :: proc(component: ^Component, allocator: mem.Allocator) {
	if component == nil do return

	switch component.kind {
	case .TabContainer:
		destroy_tab_container_state(cast(^TabContainerState)component.state, allocator)
	}

	free(component, allocator)
}

// =============================================================================
// Tab Container Implementation
// =============================================================================

// Create a tab container component
// Returns the ComponentID for the new component, or INVALID_COMPONENT_ID on failure
// Note: tabs can be empty, tabs will be added later via tab_container_add_tab
create_tab_container :: proc(
	registry: ^ComponentRegistry,
	plugin_ctx: ^api.PluginContext,
	parent_id: api.ElementID,
	tabs: []api.TabInfo,
) -> api.ComponentID {
	if registry == nil || registry.ui_api == nil do return api.INVALID_COMPONENT_ID

	allocator := registry.allocator

	// Generate unique component ID
	component_id := generate_component_id(registry)
	if component_id == api.INVALID_COMPONENT_ID do return api.INVALID_COMPONENT_ID

	// Create unique IDs for internal nodes
	root_id := fmt.aprintf("tab_container_%d", u64(component_id), allocator = allocator)
	tab_bar_id := fmt.aprintf("tab_bar_%d", u64(component_id), allocator = allocator)
	content_area_id := fmt.aprintf("tab_content_area_%d", u64(component_id), allocator = allocator)

	// Create root container (vertical stack: tab bar + content area)
	root_node := api.create_node(api.ElementID(root_id), .Container, allocator)
	root_node.style.width = api.SIZE_FULL
	root_node.style.height = api.sizing_grow()
	root_node.style.color = {0.0, 0.0, 0.0, 0.0} // Transparent
	root_node.style.layout_dir = .TopDown
	root_node.style.gap = 0

	// Create tab bar (horizontal layout)
	tab_bar := api.create_node(api.ElementID(tab_bar_id), .Container, allocator)
	tab_bar.style.width = api.SIZE_FULL
	tab_bar.style.height = api.sizing_fit()
	tab_bar.style.color = {0.18, 0.18, 0.18, 1.0} // Dark tab bar background
	tab_bar.style.layout_dir = .LeftRight
	tab_bar.style.padding = {4, 0, 4, 0} // Small horizontal padding
	tab_bar.style.gap = 2 // Small gap between tabs
	api.add_child(root_node, tab_bar)

	// Create content area (holds all tab content containers, stacked)
	content_area := api.create_node(api.ElementID(content_area_id), .Container, allocator)
	content_area.style.width = api.SIZE_FULL
	content_area.style.height = api.sizing_grow()
	content_area.style.color = {0.0, 0.0, 0.0, 0.0} // Transparent
	content_area.style.layout_dir = .TopDown
	api.add_child(root_node, content_area)

	// Create tab container state
	state := new(TabContainerState, allocator)
	state.tabs = make([dynamic]TabState, allocator = allocator)
	state.active_index = -1
	state.tab_bar = tab_bar
	state.content_area = content_area
	state.registry = registry
	state.component_id = component_id
	state.plugin_ctx = plugin_ctx
	state.allocator = allocator

	// Create tabs
	for tab_info, i in tabs {
		add_tab_to_state(state, tab_info, i, allocator)
	}

	// Create component wrapper
	component := new(Component, allocator)
	component.id = component_id
	component.kind = .TabContainer
	component.parent_id = parent_id
	component.root_node = root_node
	component.state = state

	// Register the component
	register_component(registry, component)

	// Attach to parent container
	if !attach_to_container(registry.ui_api, string(parent_id), root_node) {
		fmt.eprintln("[components] Failed to attach tab container to parent:", parent_id)
		unregister_component(registry, component_id)
		return api.INVALID_COMPONENT_ID
	}

	// Select the first tab by default
	if len(tabs) > 0 {
		tab_container_select_tab_impl(state, 0)
	}

	fmt.printf(
		"[components] Created tab container %d with %d tabs\n",
		u64(component_id),
		len(tabs),
	)
	return component_id
}

// Add a tab to the state (internal helper)
add_tab_to_state :: proc(
	state: ^TabContainerState,
	tab_info: api.TabInfo,
	index: int,
	allocator: mem.Allocator,
) {
	// Create tab button
	tab_btn_id := fmt.aprintf(
		"tab_btn_%d_%d",
		u64(state.component_id),
		index,
		allocator = allocator,
	)
	tab_btn := api.create_node(api.ElementID(tab_btn_id), .Container, allocator)
	tab_btn.style.width = api.sizing_fit()
	tab_btn.style.height = api.sizing_fit()
	tab_btn.style.color = {0.25, 0.25, 0.25, 1.0} // Inactive tab color
	tab_btn.style.layout_dir = .LeftRight
	tab_btn.style.padding = {12, 8, 12, 8}
	tab_btn.cursor = .Hand

	// Create tab title text
	tab_title_id := fmt.aprintf(
		"tab_title_%d_%d",
		u64(state.component_id),
		index,
		allocator = allocator,
	)
	tab_title := api.create_node(api.ElementID(tab_title_id), .Text, allocator)
	tab_title.text_content = strings.clone(tab_info.title, allocator)
	tab_title.style.color = {0.8, 0.8, 0.8, 1.0} // Light gray text
	tab_title.style.width = api.sizing_fit()
	tab_title.style.height = api.sizing_fit()
	api.add_child(tab_btn, tab_title)

	// Create click callback context
	click_ctx := new(TabClickContext, allocator)
	click_ctx.state = state
	click_ctx.tab_index = index

	// Set click handler
	tab_btn.on_click = tab_click_handler
	tab_btn.callback_ctx = click_ctx

	// Add tab button to tab bar
	api.add_child(state.tab_bar, tab_btn)

	// Create content container for this tab
	content_id := strings.clone(tab_info.content_container_id, allocator)
	content_container := api.create_node(api.ElementID(content_id), .Container, allocator)
	content_container.style.width = api.SIZE_FULL
	content_container.style.height = api.sizing_grow()
	content_container.style.color = {0.0, 0.0, 0.0, 0.0} // Transparent
	content_container.style.layout_dir = .TopDown
	content_container.style.hidden = true // Hidden by default

	// Add content container to content area
	api.add_child(state.content_area, content_container)

	// Store tab state
	tab_state := TabState {
		title             = strings.clone(tab_info.title, allocator),
		content_id        = content_id,
		tab_button_node   = tab_btn,
		content_container = content_container,
	}
	append(&state.tabs, tab_state)
}

// Tab click handler
tab_click_handler :: proc(ctx: rawptr) {
	click_ctx := cast(^TabClickContext)ctx
	if click_ctx == nil || click_ctx.state == nil do return

	tab_container_select_tab_impl(click_ctx.state, click_ctx.tab_index)
}

// Select a tab by index (implementation)
tab_container_select_tab_impl :: proc(state: ^TabContainerState, index: int) -> bool {
	if state == nil do return false
	if index < 0 || index >= len(state.tabs) do return false
	if index == state.active_index do return true // Already selected

	old_index := state.active_index

	// Deactivate old tab
	if old_index >= 0 && old_index < len(state.tabs) {
		old_tab := &state.tabs[old_index]
		old_tab.tab_button_node.style.color = {0.25, 0.25, 0.25, 1.0} // Inactive color
		old_tab.content_container.style.hidden = true
	}

	// Activate new tab
	new_tab := &state.tabs[index]
	new_tab.tab_button_node.style.color = {0.35, 0.35, 0.35, 1.0} // Active color
	new_tab.content_container.style.hidden = false

	state.active_index = index

	// Emit tab changed event if we have a plugin context
	if state.plugin_ctx != nil && state.plugin_ctx.api != nil {
		payload := api.EventPayload_TabChanged {
			component_id = state.component_id,
			old_index    = old_index,
			new_index    = index,
			tab_id       = new_tab.content_id,
		}
		event, ok := api.emit_event(state.plugin_ctx, .Component_Tab_Changed, payload)
		if ok && event != nil {
			api.dispatch_event(state.plugin_ctx, event)
		}
	}

	fmt.printf(
		"[components] Tab container %d: selected tab %d (%s)\n",
		u64(state.component_id),
		index,
		new_tab.title,
	)
	return true
}

// Select a tab by index (public API)
tab_container_select_tab :: proc(
	registry: ^ComponentRegistry,
	id: api.ComponentID,
	index: int,
) -> bool {
	component := get_component(registry, id)
	if component == nil || component.kind != .TabContainer do return false

	state := cast(^TabContainerState)component.state
	return tab_container_select_tab_impl(state, index)
}

// Get the active tab index
tab_container_get_active :: proc(registry: ^ComponentRegistry, id: api.ComponentID) -> int {
	component := get_component(registry, id)
	if component == nil || component.kind != .TabContainer do return -1

	state := cast(^TabContainerState)component.state
	if state == nil do return -1

	return state.active_index
}

// Add a tab to an existing tab container
tab_container_add_tab :: proc(
	registry: ^ComponentRegistry,
	id: api.ComponentID,
	tab: api.TabInfo,
) -> bool {
	component := get_component(registry, id)
	if component == nil || component.kind != .TabContainer do return false

	state := cast(^TabContainerState)component.state
	if state == nil do return false

	new_index := len(state.tabs)
	add_tab_to_state(state, tab, new_index, state.allocator)

	fmt.printf(
		"[components] Tab container %d: added tab '%s' at index %d\n",
		u64(id),
		tab.title,
		new_index,
	)
	return true
}

// Remove a tab from a tab container
tab_container_remove_tab :: proc(
	registry: ^ComponentRegistry,
	id: api.ComponentID,
	index: int,
) -> bool {
	component := get_component(registry, id)
	if component == nil || component.kind != .TabContainer do return false

	state := cast(^TabContainerState)component.state
	if state == nil do return false
	if index < 0 || index >= len(state.tabs) do return false

	// Get the tab to remove
	tab := state.tabs[index]

	// Remove tab button from tab bar
	api.remove_child(state.tab_bar, tab.tab_button_node)

	// Remove content container from content area
	api.remove_child(state.content_area, tab.content_container)

	// Free strings
	delete(tab.title, state.allocator)
	delete(tab.content_id, state.allocator)

	// Remove from tabs array
	ordered_remove(&state.tabs, index)

	// Update click contexts for tabs after the removed one
	for i := index; i < len(state.tabs); i += 1 {
		ctx := cast(^TabClickContext)state.tabs[i].tab_button_node.callback_ctx
		if ctx != nil {
			ctx.tab_index = i
		}
	}

	// Adjust active index
	if state.active_index == index {
		// Select previous tab or first tab
		if len(state.tabs) > 0 {
			new_active := index
			if new_active >= len(state.tabs) {
				new_active = len(state.tabs) - 1
			}
			state.active_index = -1 // Reset so select actually does something
			tab_container_select_tab_impl(state, new_active)
		} else {
			state.active_index = -1
		}
	} else if state.active_index > index {
		state.active_index -= 1
	}

	fmt.printf("[components] Tab container %d: removed tab at index %d\n", u64(id), index)
	return true
}

// Destroy tab container state
destroy_tab_container_state :: proc(state: ^TabContainerState, allocator: mem.Allocator) {
	if state == nil do return

	// Free tab data
	for tab in state.tabs {
		delete(tab.title, allocator)
		delete(tab.content_id, allocator)
		// Note: UINodes are cleaned up by the renderer
	}
	delete(state.tabs)

	free(state, allocator)
}
