# Technical Specification: "Vessl" (Odin Extensible IDE)

## 1. Project Overview
A high-performance, retained-mode IDE built in Odin using SDL3 for windowing/input and Clay for UI layout. The architecture follows a strict "Everything is a Plugin" philosophy. The core binary acts as a host/runtime that manages the Event Bus, the UI DOM (Document Object Model), and the Plugin Loader.

**Core Tech Stack:**
*   **Language:** Odin
*   **Platform:** SDL3
*   **UI Layout/Rendering:** Clay
*   **Terminal Emulation:** libghostty (bindings required)
*   **Scripting:** WASM/JavaScript (QuickJS or similar for future extensibility)

## 2. Directory Structure
```text
/src
  /core         // The Engine (Window, EventBus, Plugin Registry)
  /ui           // Clay abstraction, DOM, Renderer, Plugin API
  /plugins      // Builtin plugins
    /vscode_default  // Default layout plugin (VSCode mimic)
    /buffer     // Text editing logic (future)
    /filetree   // Filesystem navigator (future)
    /terminal   // Ghostty wrapper (future)
    /git        // VCS integration (future)
  main.odin     // Entry point and main event loop
/vendor         // Third-party dependencies
  /clay-odin    // Clay UI library Odin bindings
/assets         // Static assets (fonts, icons, etc.)
  /fonts        // Font files for text rendering
```

## 3. Core Data Structures (Odin)

### 3.1 The Event Bus
The nervous system of the IDE. Events cascade through plugins until consumed. The EventBus uses an arena allocator for efficient event allocation and includes thread-safe subscription management.

```odin
package core

import "core:strings"
import "core:mem"
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

Event :: struct {
    type: EventType,
    handled: bool,     // If true, propagation stops
    payload: union {
        EventPayload_Layout,
        EventPayload_Buffer,
        EventPayload_File,
        EventPayload_Custom,
    },
}

EventPayload_Layout :: struct {
    container_id: string,  // The ID of the container ready to receive children
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

EventBus :: struct {
    subscribers: [dynamic]SubscriberEntry,
    mutex: sync.Mutex, // Thread safety for subscription/unsubscription
    arena: mem.Arena,  // Arena allocator for events (short-lived)
    arena_backing: []u8, // Backing memory for arena
}
```

The EventBus provides:
- `subscribe(bus, plugin_id, handler)` - Register event handler
- `unsubscribe(bus, plugin_id)` - Remove event handler
- `emit_event(bus, event)` - Emit event to all subscribers
- `emit_event_typed(bus, type, payload)` - Helper to create and emit events

### 3.2 The UI DOM (Retained Mode)
Plugins do not call Clay directly. They manipulate this data structure through the UIPluginAPI. The Core Engine traverses this tree every frame to generate Clay draw calls.

```odin
package ui

import "core:math/linalg"

ElementID :: distinct string

ElementType :: enum {
    Container,
    Text,
    // Primitives used to build higher-level components
}

LayoutDirection :: enum {
    TopDown,
    LeftRight,
}

// Sizing with explicit units (improved over union type)
SizingUnit :: enum {
    Pixels,      // Fixed pixel value
    Percent,     // Percentage (0.0-1.0 range, where 1.0 = 100%)
    Grow,        // Grow to fill available space
}

Sizing :: struct {
    unit: SizingUnit,
    value: f32,  // Only used for Pixels and Percent
}

Style :: struct {
    width:  Sizing,
    height: Sizing,
    color:  [4]f32,
    padding: [4]u16,
    gap: u16,
    layout_dir: LayoutDirection,
}

UINode :: struct {
    id:       ElementID,
    type:     ElementType,
    parent:   ^UINode,
    children: [dynamic]^UINode,
    style:    Style,
    
    // Content
    text_content: string, // If Type == Text
    
    // Behavior (Callbacks)
    on_click: proc(ctx: rawptr),
}

// The Component Registry ensures consistency
ComponentType :: enum { Button, Checkbox, Input, Label }
```

### 3.2.1 UI Plugin API
Plugins interact with the UI DOM through the UIPluginAPI, which provides a safe interface for manipulating nodes:

```odin
package ui

UIPluginAPI :: struct {
    renderer_ctx: ^RendererContext,
    root_node: ^UINode,
}

// Key functions:
// - find_node_by_id(api, id) -> ^UINode
// - attach_to_container(api, container_id, node) -> bool
// - create_container(api, id, style) -> ^UINode
// - get_root_node(api) -> ^UINode
// - set_root_node_api(api, root) // Used by main layout plugin
```

### 3.3 The Plugin Interface
Every piece of functionality must adhere to this vtable. Plugins are managed through a PluginRegistry that handles registration, initialization, and lifecycle.

```odin
package core

import "core:mem"
import "core:sync"

PluginHandle :: distinct u64

PluginVTable :: struct {
    // Lifecycle
    init:      proc(ctx: ^PluginContext) -> bool,
    update:    proc(ctx: ^PluginContext, dt: f32),
    shutdown:  proc(ctx: ^PluginContext),
    
    // Event Handling (Return true to consume event)
    on_event:  proc(ctx: ^PluginContext, event: ^Event) -> bool,
}

PluginContext :: struct {
    eventbus: ^EventBus,
    plugin_id: string,
    user_data: rawptr,
    allocator: mem.Allocator,
    ui_api: rawptr, // ^UIPluginAPI from ui package (cast when needed)
    ctx: rawptr, // Reserved field (context is a keyword)
}

Plugin :: struct {
    id: string,
    vtable: PluginVTable,
    user_data: rawptr,
    handle: PluginHandle,
    plugin_ctx: PluginContext,
}

PluginRegistry :: struct {
    plugins: map[string]^Plugin, // Map from plugin ID to Plugin
    next_handle: u64,
    mutex: sync.Mutex,
    allocator: mem.Allocator,
}
```

The PluginRegistry provides:
- `init_plugin_registry()` - Create new registry
- `register_plugin(registry, plugin)` - Register a plugin (returns handle)
- `init_plugin(registry, plugin_id, eventbus, ui_api)` - Initialize a registered plugin
- `update_plugins(registry, dt)` - Update all plugins with delta time
- `dispatch_event_to_plugins(registry, event)` - Dispatch event to all plugins
- `get_plugin(registry, id)` - Retrieve plugin by ID

## 4. Architecture Flow

### 4.1 Startup Sequence
1.  **Initialize SDL3 & Clay.**
2.  **Initialize Plugin Registry.**
3.  **Load Config:** Check specific user path. If missing, generate defaults.
4.  **Load "Main" Plugin:** The config determines which plugin is the "Layout Manager" (defaulting to `builtin:vscode_default`).
5.  **Load Supporting Plugins:** Load `builtin:filetree`, `builtin:buffer`, etc., but do not render them yet.
6.  **Event Loop Starts:**
    *   Send `App_Startup` event.

### 4.2 The Layout Handshake (Crucial)
Plugins are passive regarding *where* they appear. They wait for the Main Plugin to dictate layout.

1.  **Main Plugin (VSCode Mimic):**
    *   Constructs a Root Container (Flex Column).
    *   Constructs a Top Bar, Side Bar container, Main Area container, Bottom Panel container.
    *   Assigns IDs: `id="sidebar_left"`, `id="editor_main"`.
2.  **Main Plugin:** Emits Event:
    *   `Layout_Container_Ready { container_id: "sidebar_left", target_plugin: "builtin:filetree" }`
3.  **FileTree Plugin:**
    *   Receives Event.
    *   Checks: `if payload.target_plugin == "builtin:filetree"`.
    *   Calls UI API: `ui_attach_to("sidebar_left", my_root_node)`.

### 4.3 Rendering Loop (The Host)
Plugins only update the `UINode` tree logic. They do not issue draw commands. The renderer uses an animation decay architecture for optimal performance (60 FPS during interactions, ~0% CPU when idle).

```text
While App is Running:
  1. Check render_required flag and animation state.
  2. Wait for SDL Events (with timeout based on activity state).
  3. Convert SDL Events -> Internal Events -> Send to Event Bus.
  4. Update Plugins (update logic, animations) with delta time.
  5. If render needed:
     a. Clear renderer
     b. Clay Begin Layout
     c. Recursive Function: Walk `UINode` Tree (build_clay_ui)
        -> Convert UINode.style to Clay ElementDeclaration
        -> Apply Clay settings (sizing, padding, layout direction)
        -> Recursively process children
     d. Clay End Layout (get render commands)
     e. Process render commands (rectangles, text, borders)
     f. SDL Render Present (VSync handles frame pacing)
  6. Clear render_required flag.
```

**Renderer Features:**
- Text rendering with SDL3 Text Engine and TTF font support
- Text object caching to avoid recreation every frame
- Bitmap font fallback if TTF loading fails
- Automatic DPI scaling support
- Clay integration with proper layout dimensions

## 5. Builtin Plugins Specifications

### 5.1 Main Config (VSCode Mimic) - `builtin:vscode_default`
*   **Responsibility:** Only sets up the empty grid/skeleton.
*   **Layout:**
    *   Root: Full window container (vertical stack)
    *   Top: Top Bar (Height 30px, horizontal layout)
    *   Middle: Horizontal stack containing:
        *   Left: Sidebar (`sidebar_left`, 200px fixed width)
        *   Center: Editor Main (`editor_main`, grows to fill)
    *   Bottom: Status Bar (`status_bar`, Height 30px, horizontal layout)
*   **Logic:** 
    *   On `App_Startup` event, emits `Layout_Container_Ready` events for:
        *   `sidebar_left` -> `builtin:filetree`
        *   `editor_main` -> `builtin:buffer`
        *   `status_bar` -> `builtin:status`
    *   Sets root node in UIPluginAPI for rendering

### 5.2 Buffer (The Editor)
*   **Responsibility:** Text manipulation, syntax highlighting (rendering), cursor management.
*   **Structure:** Uses a Gap Buffer or Rope data structure.
*   **Events:** Listens for `Event_File_Open`. When received, creates a new tab in the `editor_main` container.

### 5.3 File Tree
*   **Responsibility:** Read directory, display clickable list.
*   **UI:** Recursive list of `Component_Label` with indentation style.
*   **Events:** On Click -> Sends `Event_File_Open { path: "..." }`.

### 5.4 Terminal
*   **Backend:** integration with `libghostty` (C ABI).
*   **UI:** Renders the Ghostty texture into a Clay container.
*   **Input:** Captures raw input when focused and forwards to the PTY.

## 6. Predefined Component API (UI Library)
To ensure the "extensible but consistent" look, plugins should use these helpers instead of raw Nodes.

*   `comp_button(text: string, onclick: proc()) -> ^UINode`
*   `comp_input(placeholder: string, onchange: proc(val: string)) -> ^UINode`
*   `comp_checkbox(label: string, checked: bool) -> ^UINode`
*   `comp_panel(children: []^UINode) -> ^UINode`

## 7. Implementation Plan for Agent

### Phase 1: The Skeleton ✅ COMPLETE
1.  ✅ Set up `odin` project.
2.  ✅ Get SDL3 window opening with DPI scaling support.
3.  ✅ Integrate Clay (using the C bindings) with full rendering pipeline.
4.  ✅ Implement the `UINode` struct with improved `Sizing` system.
5.  ✅ Implement the recursive tree walker (`build_clay_ui`) that calls `Clay` functions.
6.  ✅ Implement renderer with text support, font loading, and render command processing.

### Phase 2: The Plugin System ✅ COMPLETE
1.  ✅ Implement `EventBus` with arena allocator and thread-safe subscription system.
2.  ✅ Define the `PluginVTable` and `PluginContext`.
3.  ✅ Implement `PluginRegistry` for plugin lifecycle management.
4.  ✅ Create `UIPluginAPI` for safe UI manipulation by plugins.
5.  ✅ Create the `builtin:vscode_default` plugin that builds a static node tree and emits layout events.

### Phase 3: Interactivity
1.  Implement `builtin:filetree`.
2.  Implement the Event "Handshake" logic (Main plugin invites Filetree plugin).
3.  Implement basic mouse clicking in the UI Engine (Raycasting handled by Clay, event triggering handled by Engine).

### Phase 4: Text Editing
1.  Implement `builtin:buffer`.
2.  Implement basic text rendering and keyboard input forwarding.

## 8. Specific Odin Directives for the Agent
*   **Memory:** 
    *   Use `core:mem/virtual` for large buffers.
    *   Use arena allocator (`mem.Arena`) for short-lived event allocations in EventBus.
    *   Use context allocator for plugin-allocated UI nodes (retained mode).
    *   Use frame allocator for immediate-mode style wrappers if needed.
*   **String Handling:** 
    *   Use `string` (slice) for viewing.
    *   Use `strings.Builder` for mutation.
    *   Clone strings when storing in persistent data structures (e.g., plugin IDs, cached text).
*   **Naming:** 
    *   Use `snake_case` for variables/procedures.
    *   Use `PascalCase` for Structs/Enums.
*   **Thread Safety:**
    *   Use `sync.Mutex` for shared data structures (EventBus subscribers, PluginRegistry).
    *   Protect render_required flags and animation state with mutexes.
*   **Performance:**
    *   Implement animation decay architecture (60 FPS during activity, idle when not needed).
    *   Cache text objects to avoid recreation every frame.
    *   Use VSync for frame pacing.
