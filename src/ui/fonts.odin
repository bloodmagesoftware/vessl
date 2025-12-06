package ui

// Embedded font data - loaded at compile time using #load directive
// This allows the application to run as a single binary without external asset dependencies
// Using @(rodata) to keep data in read-only section while allowing runtime access

// JetBrains Mono - Primary monospace font for code and UI
@(rodata)
FONT_JETBRAINS_MONO := #load("../../assets/fonts/JetBrainsMono.ttf")
@(rodata)
FONT_JETBRAINS_MONO_ITALIC := #load("../../assets/fonts/JetBrainsMono-Italic.ttf")

// Roboto - Secondary font for UI elements
@(rodata)
FONT_ROBOTO := #load("../../assets/fonts/Roboto.ttf")
@(rodata)
FONT_ROBOTO_ITALIC := #load("../../assets/fonts/Roboto-Italic.ttf")
