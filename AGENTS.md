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

Plugins should only use the API layer in `./src/plugin_api/` to decouple them from the core system.

Run `odinfmt ./src/ -w` to format the core when you are done with your changes.
Run the program for a few seconds to ensure it builds and runs correctly using `timeout 3 odin run src/`.

Keep the documentation, especially the API documentation, up to date.
