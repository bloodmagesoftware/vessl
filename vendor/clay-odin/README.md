# Clay Odin Bindings

This directory should contain the official Clay Odin bindings from the [Clay repository](https://github.com/nicbarker/clay).

## Installation

According to the [Clay Odin documentation](https://github.com/nicbarker/clay/tree/main/bindings/odin), you should:

1. Download the `clay-odin` directory from: https://github.com/nicbarker/clay/tree/main/bindings/odin/clay-odin
2. Copy its contents into this `vendor/clay-odin` directory

### Quick Setup (using git)

```bash
# Clone the Clay repository (or download the bindings directory)
git clone --depth 1 --filter=blob:none --sparse https://github.com/nicbarker/clay.git /tmp/clay
cd /tmp/clay
git sparse-checkout set bindings/odin/clay-odin

# Copy the bindings to this directory
cp -r bindings/odin/clay-odin/* /path/to/your/project/vendor/clay-odin/

# Clean up
rm -rf /tmp/clay
```

### Manual Setup

1. Visit https://github.com/nicbarker/clay/tree/main/bindings/odin/clay-odin
2. Download all files from that directory
3. Place them in this `vendor/clay-odin` directory

## Usage

Once installed, you can import Clay in your Odin code:

```odin
import clay "vendor/clay-odin"
```

## Important Notes

- **DO NOT manually modify files in this directory** - they are third-party library files
- If you need to make changes, consider:
  - Creating a wrapper module in `src/ui/` that provides your own abstraction
  - Forking the Clay repository and maintaining your own version
  - Contributing changes back to the upstream Clay project

