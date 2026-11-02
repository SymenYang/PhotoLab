# PhotoLab

[简体中文](README.md) | English

PhotoLab is a native macOS photo and video manager with local AI search, smart culling, and non-destructive editing. Built with SwiftUI and SQLite, it works with media on local disks and mounted network shares.

## Features

- Recursively import folders, pair RAW / JPG / HEIC files with matching names, and browse metadata, thumbnails, and originals.
- Organize with star ratings, pick/reject flags, tags, combined filters, and saved filters. Compare multiple photos and play videos.
- Edit, crop, rotate, and export photos non-destructively. Edits are stored in `.photolab` sidecar files beside the originals.
- Run semantic search, similar-photo grouping, aesthetic/quality scoring, and AI color adjustments locally.
- Adjust white balance, basic tones, HSL, black and white, RGB and per-channel point curves, parametric curves, color grading, sharpening, noise reduction, vignetting, and grain. AI and manual adjustments share parameters and support undo/redo.
- Develop RAW images at the resolution needed for AI input and editing previews; generate full-resolution results when finishing edits or exporting. RGB white balance uses 5500 K and tint 0 as its relative neutral reference.
- Download models on demand after reviewing their sources and licenses and confirming the download. Monitor progress, cancel, or retry failed downloads.
- Use local caches, background task queues, and resumable scans. Inference runs on your machine.

## Build and Run

The complete app bundle currently targets Apple Silicon and macOS 26.3 or later. It requires compatible Xcode Command Line Tools and Python 3. Native color-processing dependencies and pinned archives are included in `Vendor/Redlamp/`; AI models do not need to be downloaded before building.

```sh
zsh scripts/build-app.sh
open build/PhotoLab.app
```

Install the models you need from the app's model management/download screen. Developers with existing model environments can configure `.local/ai-config.json`:

```json
{
  "python": "/absolute/path/to/embedding-env/bin/python",
  "model": "/absolute/path/to/siglip-model",
  "artPython": "/absolute/path/to/scoring-env/bin/python",
  "artModel": "/absolute/path/to/q-realign-model"
}
```

This file is used only for local builds and is excluded from Git. Additional supported path keys are `qwenModel`, `qwenCoreML`, and `jarvisModel`. Existing models do not need to be moved or downloaded again.

Create a separate distribution bundle without local model configuration:

```sh
zsh scripts/build-distribution.sh
# Output: build/PhotoLab-Distribution.app
```

This leaves the local app bundle intact. The scripts currently use ad hoc signing; a public release requires your own developer signing and notarization setup. Model licenses are separate from the application code. In particular, JarvisArt has non-commercial and non-production restrictions. See the [model distribution notes](AI/MODEL_DISTRIBUTION.md) and `AI/licenses/`.

## Project Layout

| Path | Purpose |
| --- | --- |
| `Sources/PhotoLab/` | SwiftUI interface, catalog, media browsing and editing, background tasks, and model management |
| `Sources/CSQLite/` | SQLite system library bridge |
| `Native/PhotoLabRedlamp/` | Native color engine bridge |
| `AI/` | Python inference workers, model installer, manifests, and licenses |
| `Vendor/Redlamp/` | Pinned third-party source, build dependencies, and licenses |
| `Resources/` | Icon source, border textures, stickers, brand marks, and source attribution |
| `Tests/` | Swift / Python tests and isolated download simulations |
| `scripts/` | Build, packaging, and test entry points |
| `Package.swift` | Swift package definition |

`research/`, `checkpoints/`, `test_photo/`, `.local/`, local model directories, and build outputs are excluded from Git. The source and normal build do not depend on this project's `research/` directory; upstream research paths retained in third-party source appear only in comments and model descriptions. Integration tests using real models or media require your own local environments and samples.

Ignore rules also cover common model weights, RAW files, photos, videos, private keys, and signing certificates. The app icon and attributed paper texture are explicitly retained as project assets. Review the purpose and licensing of any new bitmap assets and update the `.gitignore` allowlist. The catalog defaults to `~/Library/Application Support/PhotoLab/` and is not distributed with the source.

The third-party dependencies include `Sam3AppPrompts.bin` (about 16 KB) and its license. This contains upstream precomputed text-prompt features for Snow, read by the SAM3 segmentation code; it is not model weights or user photography. The LibRaw source archive, ColorTools runtime archive, and Metal library in `Vendor/Redlamp/vendor/` are required build resources. Model manifest JSON files contain download metadata only.

## Testing

Run the download simulation without real models:

```sh
zsh scripts/test-model-downloads.sh
```

The simulation uses isolated temporary directories, synthetic files, and a local HTTP server. It does not download real weights. See the [simulation test notes](Tests/ModelDownloads/README.md) for coverage. Other entry points are available as `scripts/test-*.sh`; some require local AI Python environments or media in `test_photo/`.

Supply external acceptance-test fixtures through environment variables:

- `PHOTOLAB_TEST_IMAGE`: image for aesthetic scoring.
- `PHOTOLAB_REDLAMP_FIXTURES`: directory containing a 768×576 `before.jpg` and `full.redrecipe`.
- `PHOTOLAB_HEIC_REFERENCES`: HEIC reference images.
- `PHOTOLAB_COLOR_FIXTURES`: color experiment JSON fixtures.

Performance reports default to the ignored `build/reports/` directory.

Run color-control and RAW workflow regressions with `zsh scripts/test-color-controls.sh`. Metal is required; inference uses fixed test responses by default. Add `--snapshot` for panel screenshots or `--real-ai` to run the configured local JarvisArt model on a test 3FR file.

## Editing Workflow

Color, crop, border, and sticker changes remain in an in-memory draft until you click Done. Saving writes the `.photolab` file and triggers embedding/scoring updates. Closing discards the current draft and preserves the previously saved version. Finishing without changes, undoing back to the original state, or closing without saving does not rewrite files or trigger analysis. When switching photos or switching between RAW and camera-rendered input, you can save, discard, or continue editing.

### Focus Full-Screen Viewing

Press F to open Focus viewing. The viewer first uses the shared browsing cache matching the current edit revision and rotation, then loads the HDR original or edited preview at the screen's pixel dimensions instead of decoding the entire full-resolution image by default.

Zooming or pinching requests more detail based on visible pixel requirements while preserving the viewport as previews are replaced. Recent HDR original previews use a separate bounded memory cache. RAW decoding sets the scale before development. Viewing the original bypasses edited caches. If the original is offline, the viewer can retain an already displayed cached image and report the error. Results from outdated requests are ignored after switching photos or exiting.

Run `zsh scripts/test-focus-viewing.sh` to check progressive display, zoom requests, cancellation, HDR, and edited previews, and to measure decoding times with local HEIC/JPG/RAW samples.

### Borders and Stickers

The Photo Shadow toggle adds a soft shadow around the photo and is off by default. The shadow scales with the photo and supports saving, presets, undo, and export without changing the photo area's colors or canvas dimensions. New text stickers and camera, lens, and exposure text in information presets default to Helvetica. System, serif, and handwritten font choices remain available; existing stickers retain their selected fonts.

Borders and content are independent. Borders control solid color, cotton paper, instant-photo paper, or film edges, along with color, margins, bottom spacing, aspect ratio, and texture. Left-aligned information, two-column information, and signature presets create independent text and logo stickers without changing the border. Each sticker can be moved, resized, rotated, edited, or deleted. Text can bind to camera, lens, exposure, or date metadata; typing directly switches it to custom text. Legacy information borders are converted to stickers when opened and rendered, preserving canvas size, background color, and field toggles. Opening alone does not rewrite an edit file.

The sticker panel groups Brand Logos, Built-in Stickers, and Imported Stickers. Brand assets cover 13 major brands, the Hasselblad H symbol, and a separate Leica wordmark, with 45 original-color, black, and white SVG variants. Backgrounds are transparent. Nikon's yellow square background is removed; Leica's original-color version keeps its circular badge, while black and white variants use transparent wordmarks. The Hasselblad H symbol was traced into a vector from the official Phocus transparent graphic; its source record explicitly identifies it as a derived SVG rather than an officially published SVG.

Automatic brand stickers use each photo's EXIF Make / Model, prioritizing Make and never inferring the camera brand from the lens name. Unknown brands remain blank and can be replaced with a specific logo. Information presets, batch application, and favorites preserve dynamic bindings; edited text retains user-supplied content. Sources, processing notes, copyright status, and SHA-256 hashes are recorded in `Resources/Decorations/CREDITS.txt`, `manifest.json`, and `Brands/*.source.json`.

Import PNG or static SVG assets, add editable text stickers, or use the 12 original vector stickers included with PhotoLab. Drag stickers on the canvas; use the bottom-right handle to scale proportionally and the top circular handle to rotate. Each drag is one undo step. Panel controls also provide size, rotation, opacity, font, text color, visibility, and stacking order, with duplicate, delete, and undo/redo support.

Imported assets are saved in a local asset library and embedded in `.photolab` files, so edits can be reopened and exported after the original PNG/SVG is moved. Each PNG is limited to 8 MB and 32 megapixels. SVG files are limited to 2 MB and remain vector-based; basic shapes, paths, text, gradients, and local references are supported, while scripts, external links, animation, embedded images, and HTML are rejected. Each photo supports up to 48 stickers and 24 MB of assets.

Save complete presets as favorites, or explicitly apply the current decoration to other photos selected in the grid before opening the editor. Batch saving preserves each photo's color adjustments and crop, replaces its decorations, and refreshes only successfully saved photos with actual changes. The current photo is still saved with Done; closing its editor does not undo a completed batch save.

Decorations are composited after photo rendering. Moving stickers or changing borders does not rerun RAW color processing, and a valid full-resolution photo cache can be reused when saving decorations. Thumbnails, viewing, and export share the same decoration renderer. Decorated exports currently use SDR; exporting the original preserves the original file.

The built-in paper texture comes from [ambientCG Paper 001](https://ambientcg.com/view?id=Paper001) under CC0 1.0. The 12 original PhotoLab sticker SVGs are also provided under CC0; brand logos have separate source and rights notices. Attribution, licensing, and SHA-256 hashes are included in `Resources/Decorations/manifest.json` and `CREDITS.txt` and bundled with the app. The app uses system fonts and requires no additional font installation.

Run `zsh scripts/test-decorations.sh` to verify templates, rotation, PNG/SVG/text, legacy edits, embedded assets, caching, export, and undo. The tests also check transparency and black/white pixels for all 45 logo variants and generate `build/decoration-preview.png`, `build/camera-logo-preview.png`, and `build/logo-variants-preview.png` for visual review.
