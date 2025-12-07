package ui

import api "../api"

// Re-export types from api for internal use and backward compatibility
// This allows existing code to use ui.UINode, ui.Style, etc.
ElementID :: api.ElementID
ElementType :: api.ElementType
LayoutDirection :: api.LayoutDirection
CursorType :: api.CursorType
SizingUnit :: api.SizingUnit
Sizing :: api.Sizing
Style :: api.Style
UINode :: api.UINode
ComponentType :: api.ComponentType

// Re-export constants
SIZE_FULL :: api.SIZE_FULL

// Re-export helper functions from api
sizing_px :: api.sizing_px
sizing_pct :: api.sizing_pct
sizing_grow :: api.sizing_grow
sizing_fit :: api.sizing_fit
create_node :: api.create_node
add_child :: api.add_child
remove_child :: api.remove_child
clear_children_except :: api.clear_children_except
find_node_by_id_recursive :: api.find_node_by_id_recursive
