# gaea-plugin-mage-flow

Microsoft's **Mage-Flow** family (a 4.1B native-resolution NR-MMDiT with Qwen3-VL-4B conditioning, MIT) as a
[Gaea](https://github.com/xocialize/gaea) **research plugin**. It is built on
[GaeaPluginKit](https://github.com/xocialize/gaea-plugin-kit) over
[mage-flow-swift](https://github.com/xocialize/mage-flow-swift), runs in its own process, and speaks the Gaea Plugin
Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize/gaea-plugin-mage-flow
```

## A research plugin: every model is named-only

Gaea's normalizer never picks a Mage-Flow model by default. A request runs one only by naming it (`"model":
"mage-flow-turbo"`). Every offer says `named_only: true`, as Gaea's plan has it for the research models (AB-T-0374).
The weights are MIT, so Gaea doesn't make them opt-in: they are on once the plugin is installed, but reachable only by
name.

## What it offers

| Model | MES operation | Quality tiers | Notes |
|---|---|---|---|
| `mage-flow` | `image.generate` | standard, best | RL-aligned, 20 steps with CFG 5, negative prompts honoured. |
| `mage-flow-turbo` | `image.generate` | draft, standard | Distilled to 4 steps without CFG: a negative prompt is reported `negative_prompt_ignored`. |
| `mage-flow-edit` | `image.edit` | standard, best | RL-aligned instruction editing, 20 steps with CFG 5, from 1–3 references named in the instruction in order. |
| `mage-flow-edit-turbo` | `image.edit` | draft, standard | 4-step distilled edit on the int8 DiT. The normalizer's remover (erase at `best`) and the creative upscale's editor, when it names it. |
| `mage-flow-edit-base` | `image.edit` | best | The quality edit checkpoint, 30 steps with CFG 5. |

- **Sizes.** Mage-Flow draws squares. The side keeps the requested area, clamped to 512–1024 px (the 1024² cap the
  footprints were measured at) and floored to a multiple of 16; a change is reported `size_snapped`. An edit without
  a size takes the first image's area.
- **`count`** on `image.generate`: 1–8 images, each with `seed + i`. A request without a seed gets one, reported in
  `effective`. `image.edit` has one output; `strength` does nothing (`param_ignored`).
- **Options**, as MES extensions: `x-mage.steps` (every model) and `x-mage.guidance` (the CFG models).
- **The normalizer's own calls by name:** `mode: tiles` (each image edited alone with the same instruction, returned
  stacked, the conditioner loaded once) and `initSigma` (start from Image 1 noised to that sigma) pass to the package.
- **Content filter.** Microsoft's Responsible-AI screen is off, as in mlx-image-runtime's catalog (AB-D-0122): it
  refused benign photos and is the slowest stage of a 4-step edit.
- **Not yet offered:** per-request LoRA adapters (the surfaces take them; no registry is vendored), and the small-Mac
  residency tiers (`evictConditioner`, `evictTransformer`).

## Lanes and memory

Each lane is a DiT quant, with the package's footprints at 1024² (DiT + Qwen3-VL-4B conditioner + VAE resident):

| Lane | Resident | Peak while running | Gaea schedules |
|---|---|---|---|
| `bf16` (default, except Edit Turbo) | 16.4 GB | 3.7 GB | 20.1 GB |
| `int8` (Edit Turbo's default) | 14.2 GB | 3.7 GB | 17.9 GB |
| `int4` | 12.9 GB | 3.7 GB | 16.6 GB |

Edit Turbo has no bf16 lane: its components come without the bf16 DiT. When the default lane doesn't fit, Gaea loads a
smaller one and warns (`lane_fallback`, G-23). A request naming a lane (`x-gaea.lane`) never falls back.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default; `gaea models root` changes it). Each model
reads two snapshots there:
- `mage-flow-community/<Checkpoint>`: the upstream components. The bf16 lane needs `transformer/`; every lane needs
  `text_encoder/` and `vae/`.
- `xocialize/<Checkpoint>-mlx`: the port's folded adaLN, plus `transformer-int8` or `-int4` for those lanes.

The worker downloads a missing snapshot on `prepare` or `materialize`.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
CHECK_MODELS_ROOT=<a models root holding Mage-Flow-Turbo> scripts/check-plugin.sh
```

`check-plugin.sh` generates one 512² image with Mage-Flow Turbo int8, with every `.build` folder hidden so MLX can
find its metallib only inside the bundle. A control then shows that the bare worker, outside the bundle, can't.
`scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release.
See the [demo plugin](https://github.com/xocialize/gaea-plugin-demo) for signing, notarization and CI secrets.

`mage-inproc` (`swift run -c release mage-inproc`; its header lists the options) is not part of the plugin. It runs
the same lane in-process through MLXServeEngine, the reference that Gaea's runs are compared against byte for byte.

## Licence

The plugin is Apache-2.0 (Gaea G-21). The Mage-Flow weights are MIT (Microsoft, mirrored at mage-flow-community), and
mage-flow-swift is MIT.
