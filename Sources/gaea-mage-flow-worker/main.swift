import GaeaPluginKit
import MagePlugin

// The plugin's worker: MagePlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(magePlugin)
