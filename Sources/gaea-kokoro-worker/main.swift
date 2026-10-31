import GaeaPluginKit
import KokoroPlugin

// The plugin's worker: KokoroPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(kokoroPlugin)
