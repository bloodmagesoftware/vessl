# Technical Specification: "Vessl" (Extensible IDE)

This is a IDE with a focus on extensibility and customizability while being easy to use and performant.

It uses gaming technologies to be fast while maintaining a low memory and CPU footprint.

Everything in Vessl is a plugin. Even core editor features like a file tree, text editor, and a terminal are implemented as plugins.
This ensures that the plugin system is extensible enough to allow for any kind of plugin to be created.
I want to avoid situations like VSCode or Zed where you can't extend the program in a way that was not intended by the authors.
The plugin API should give the necessary tools to do what you want.

## Vendor

Libraries should be stored in the `vendor/` directory. Not as submodules, just copy the whole library.

Don't edit vendored code unless absolutely necessary.

## Target platforms

- macOS arm64
- Windows x64
- Linux x64
- Linux arm64

## Development

Plugins should only use the API layer in `./src/api/` to decouple them from the core system.

Run `odinfmt ./src/ -w` to format the core when you are done with your changes.
Run the program for a few seconds to ensure it builds and runs correctly using `timeout 3 odin run src/`.

Keep the documentation, especially the API documentation, up to date.

## Codebase Reference

### Tech Stack
- **Language**: Odin
- **Window/Input**: SDL3 (`vendor:sdl3`)
- **UI Layout**: Clay (`vendor/clay-odin/`) - retained mode UI tree → Clay declarative layout
- **Text**: SDL3_ttf text engine, embedded fonts in `src/ui/fonts.odin`
- **Syntax**: Tree-sitter (`vendor/odin-tree-sitter/`)

### Directory Structure
```
src/
├── api/              # Plugin API - ONLY import this in plugins
│   ├── types.odin    # All shared types (Event, UINode, Style, PluginVTable, etc.)
│   └── api.odin      # Helper functions (sizing_*, create_node, emit_event wrappers)
├── core/             # Internal systems (NOT for plugins)
│   ├── eventbus.odin # EventBus, ShortcutRegistry
│   ├── plugin.odin   # PluginRegistry, dispatch_event_to_plugins
│   └── window.odin   # SDL window wrapper
├── ui/               # UI internals (NOT for plugins)
│   ├── renderer.odin # Clay integration, render_frame, text/image rendering
│   ├── components.odin # High-level components (TabContainer)
│   ├── dom.odin      # UINode re-exports for internal use
│   ├── api.odin      # UIPluginAPI (internal)
│   ├── platform.odin # Native dialogs (folder picker)
│   └── fonts.odin    # Embedded font data
├── plugins/          # Built-in plugins
│   ├── vscode_default/ # Layout plugin - creates root UI, emits Layout_Container_Ready
│   ├── filetree/       # File tree sidebar
│   ├── buffer_manager/ # Tab management, routes files to editors
│   ├── text_editor/    # Text file viewer
│   └── image_viewer/   # Image file viewer
├── api_impl.odin     # VesslAPI VTable implementation (connects api → core/ui)
└── main.odin         # Entry point, SDL event loop, plugin registration
```

### Key Types (all in `src/api/types.odin`)
| Type | Purpose |
|------|---------|
| `EventType` | Enum: App_Startup, Layout_Container_Ready, Request_Open_File, Mouse_Down/Up/Move, Custom_Signal, etc. |
| `Event` | `{type, handled, payload}` |
| `EventPayload` | Union of payload structs (EventPayload_Layout, _OpenFile, _MouseDown, etc.) |
| `UINode` | `{id, type, parent, children, style, text_content, image_path, on_click, callback_ctx, cursor}` |
| `Style` | `{width, height, color, padding, gap, layout_dir, clip_*, hidden}` |
| `Sizing` | `{unit: SizingUnit, value}` - use `sizing_px/pct/grow/fit()` helpers |
| `ElementID` | `distinct string` - unique UI node identifier |
| `PluginVTable` | `{init, update, shutdown, on_event}` procs |
| `PluginContext` | `{plugin_id, user_data, allocator, api}` - passed to all plugin procs |
| `VesslAPI` | VTable struct with all API functions |
| `ComponentID` | `distinct u64` - for high-level components |
| `KeyModifier` | `bit_set[KeyModifierFlag]` - Ctrl/Cmd/Alt/Opt/Shift |

### Plugin Lifecycle
1. `get_vtable()` returns `PluginVTable`
2. `init(ctx)` → allocate state, store in `ctx.user_data`
3. `on_event(ctx, event)` → handle events, return `true` to consume
4. `update(ctx, dt)` → called every frame
5. `shutdown(ctx)` → cleanup

### Event Flow
```
vscode_default (App_Startup) → emit Layout_Container_Ready(container_id, target_plugin)
                             ↓
filetree (on_event) → check target_plugin == "builtin:filetree"
                    → create UI nodes
                    → api.attach_to_container(ctx, container_id, root_node)
```

### Common Patterns

**Create UI node:**
```odin
node := api.create_node(api.ElementID("my_id"), .Container, ctx.allocator)
node.style.width = api.sizing_grow()
node.style.height = api.sizing_px(100)
node.style.color = {0.2, 0.2, 0.2, 1.0}  // RGBA 0-1
node.style.layout_dir = .TopDown
api.add_child(parent, node)
```

**Click handler:**
```odin
node.on_click = proc(ctx: rawptr) { /* handle */ }
node.callback_ctx = my_data_ptr
node.cursor = .Hand
```

**Emit & dispatch event:**
```odin
payload := api.EventPayload_OpenFile{path = file_path}
event, _ := api.emit_event(ctx, .Request_Open_File, payload)
if event != nil do api.dispatch_event(ctx, event)
```

**Handle event:**
```odin
#partial switch event.type {
case .Layout_Container_Ready:
    #partial switch payload in event.payload {
    case api.EventPayload_Layout:
        if payload.target_plugin != "my:plugin" do return false
        // attach UI...
        return true
    }
}
return false
```

**Register shortcut:**
```odin
api.register_shortcut(ctx, 'o', {.Ctrl}, "open_file")  // Win/Linux
api.register_shortcut(ctx, 'o', {.Cmd}, "open_file")   // macOS
```

### Main Loop (`main.odin`)
- Animation Decay pattern: 60fps during interaction, 0% CPU when idle
- `SDL.WaitEventTimeout` blocks when idle
- `render_required` flag + `animation_until` timestamp control rendering
- Events converted from SDL → internal types → dispatched to plugins

### Internal Registries (in `main.odin`)
- `eventbus` → `core.EventBus`
- `plugin_registry` → `core.PluginRegistry`
- `shortcut_registry` → `core.ShortcutRegistry`
- `renderer_ctx` → `ui.RendererContext`
- `component_registry` → `ui.ComponentRegistry`

### Built-in Plugin IDs
- `builtin:vscode_default` - layout (priority 0)
- `builtin:filetree` - file tree (priority 10)
- `builtin:buffer_manager` - tab/buffer management (priority 0)
- `builtin:text_editor` - text viewer (priority 0, fallback)
- `builtin:image_viewer` - image viewer (priority 10)

### Container IDs (from vscode_default)
- `sidebar_left` → filetree
- `editor_main` → buffer_manager
- `status_bar` → status plugin

### Commands
```bash
odinfmt ./src/ -w           # Format code
timeout 3 odin run src/     # Test build & run
./build_parsers.sh          # Rebuild tree-sitter parsers
```

### Files to Check First
- New plugin? → `src/plugins/filetree/filetree.odin` (example)
- API changes? → `src/api/types.odin`, `src/api/api.odin`, `src/api_impl.odin`
- UI rendering? → `src/ui/renderer.odin`
- Event system? → `src/core/eventbus.odin`
- Main loop? → `src/main.odin`
- High-level components? → `src/ui/components.odin`
