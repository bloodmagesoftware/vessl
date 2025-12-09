# libvterm

[libvterm](https://github.com/neovim/libvterm) is a terminal emulator library that handles ANSI escape sequences and maintains terminal state.

## Building

### Option 1: Use the build script (Recommended)

```bash
./build_libvterm.sh
```

This will:
1. Clone libvterm from the Neovim repository
2. Build it for your current platform
3. Optionally cross-compile for other platforms (if `zig` is installed)

### Option 2: Manual build

1. Clone libvterm:
   ```bash
   git clone https://github.com/neovim/libvterm.git
   cd libvterm
   ```

2. Build:
   ```bash
   make
   ```

3. Copy the library:
   ```bash
   # macOS ARM64
   cp .libs/libvterm.a /path/to/vessl/vendor/libvterm/macos-arm64/
   
   # macOS x64
   cp .libs/libvterm.a /path/to/vessl/vendor/libvterm/macos-amd64/
   
   # Linux x64
   cp .libs/libvterm.a /path/to/vessl/vendor/libvterm/linux-amd64/
   
   # Linux ARM64
   cp .libs/libvterm.a /path/to/vessl/vendor/libvterm/linux-arm64/
   ```

### Windows

On Windows, you need to build with MSVC or MinGW:

1. Clone libvterm
2. Build using the provided Visual Studio project or:
   ```cmd
   cl /c /O2 /DNDEBUG src/*.c
   lib /OUT:vterm.lib *.obj
   ```
3. Copy `vterm.lib` to `vendor/libvterm/windows-amd64/`

## Directory Structure

```
vendor/libvterm/
├── vterm.odin          # Odin bindings
├── build_libvterm.sh   # Build script
├── README.md           # This file
├── macos-arm64/
│   └── libvterm.a
├── macos-amd64/
│   └── libvterm.a
├── linux-amd64/
│   └── libvterm.a
├── linux-arm64/
│   └── libvterm.a
└── windows-amd64/
    └── vterm.lib
```

## License

libvterm is licensed under the MIT license. See the [original repository](https://github.com/neovim/libvterm) for details.

