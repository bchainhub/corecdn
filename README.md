# CORE CDN

This repository serves as a CDN (Content Delivery Network) for storing and deploying PNG and SVG image files. The images are organized in a specific folder structure and can be accessed through two CDN URLs.

## Actions

* [Open repository page](https://github.com/bchainhub/corecdn)
* [Fork repository](https://github.com/bchainhub/corecdn/fork)
* [Open issue](https://github.com/bchainhub/corecdn/issues)

## Click & Copy

> Modify the example link as needed

```url
https://corecdn.info/mark/256/xcb.png
```

## Folder Structure and Path

Source assets are **SVG files** located in the `base` folder.
A build script generates multiple square size variants (SVG + PNG) from these sources.

```txt
[badge|mark]/base/{name}.svg         ← source (SVG only)
[badge|mark]/[size]/{name}.svg       ← generated (square page)
[badge|mark]/[size]/{name}.png       ← generated (square image)
```

### Structure Explanation

* **badge / mark** — Top-level directories for badge or mark images.
* **base** — Contains only original source SVG files.
* **size** — Generated output folders named by pixel size.
* **{name}** — Filename without extension.

### Base SVG: no `<g>` tags

Using **`<g>` (group) tags** in base SVGs is **not supported**. Base images that contain `<g>` elements are **filtered out** by the build script and will not be exported.

To fix such SVGs, remove the group elements so the content is ungrouped. In Inkscape: use **Object → Ungroup** (or ungroup in the Layers panel) until no `<g>` wrappers remain, then save.

### Generated Sizes

The script produces square icons at these pixel sizes (both SVG and PNG):

**16**, **24**, **32**, **48**, **64**, **72**, **96**, **128**, **144**, **192**, **256**, **512**, **1024**

Each generated file:

* Preserves original aspect ratio (no deformation)
* Scales proportionally
* Expands canvas to a square
* Centers artwork on transparent background

## Build Script

The script `scripts/export.sh` generates all size variants from the base SVGs.

### What it does

1. Finds every SVG under:

   * `badge/base/`
   * `mark/base/`

2. For each base SVG and each size:

   * Scales proportionally (largest side = target size)
   * Fits page to drawing
   * Expands page to square
   * Centers artwork
   * Exports:
     * Square SVG
     * Square PNG

### Quiet / Verbose Modes

* By default, the script runs in **quiet mode** (suppresses Inkscape and macOS ColorSync messages).
* Use `--verbose` to enable normal Inkscape output.
* Use `--svgnominify` to skip SVG minification (on by default when Scour is installed).
* Use `--pngnominify` to skip PNG minification (on by default when oxipng is installed).
* Use `--noadvert` to run **only** branding removal: strip advertisement/branding attributes (e.g. `xmlns:serif="http://www.serif.com/"` from Affinity) from SVG files in `*/base/` and exit. No export is run. Off by default.
* Use `--analyze` to **check** all base SVGs in `mark/base` and `badge/base` for correctness (XML, viewBox, no `<g>`, valid path data). Reports malformed path `d` with exact reason (e.g. `invalid_number`, `not_enough_params`). No export is run. Exit code 1 if any file has issues.
* Use `--inkscape-svg` to generate resized SVGs via **Inkscape** (scale + fit + center) then resize to square. By default the script copies the base SVG and resizes it with **librsvg** (`rsvg-convert`).

### Overwrite Behavior

By default:

* Existing generated files are **not overwritten**
* Only missing files are created

To regenerate everything:

```bash
./scripts/export.sh --overwrite
```

You can combine flags:

```bash
# Verbose and overwrite everything
./scripts/export.sh --overwrite --verbose

# Skip SVG or PNG minification
./scripts/export.sh --svgnominify
./scripts/export.sh --pngnominify

# Only strip branding from base SVGs (no export)
./scripts/export.sh --noadvert

# Check base SVGs for correctness (no export)
./scripts/export.sh --analyze
```

### Progress and Parallelism

* The script shows an **export progress** count (e.g. `Export [=========>----] 423/1378`) so you can see it is not frozen.
* Exports run in **parallel** (default job count = number of CPU cores). To limit concurrency: `JOBS=4 ./scripts/export.sh`
* If export appears to hang, try `JOBS=1 ./scripts/export.sh --overwrite --verbose` to run one task at a time and see which file or size gets stuck.
* Optional: install **coreutils** (`brew install coreutils`) to get `gtimeout`. The script will then apply a timeout to Inkscape so a single stuck task does not block the run.

### Requirements

* [Inkscape](https://inkscape.org/) — required for PNG export and optionally for SVG export (`--inkscape-svg`). Must be available as `inkscape` in your `PATH`.
* [librsvg](https://wiki.gnome.org/Projects/LibRsvg) — required for resize + center. Install: `brew install librsvg`. Provides `rsvg-convert`, which resizes each SVG to the target size (e.g. 256×256) while preserving aspect ratio and centering.
* [Scour](https://github.com/scour-project/scour) — for SVG minification; must be available as `scour` in your `PATH`
* [oxipng](https://github.com/oxipng/oxipng) — for lossless PNG minification; must be available as `oxipng` in your `PATH`
* Python 3 — only for `--analyze` (checking base SVGs). Not used for export.
* Bash environment

### How to install Scour

* Homebrew (macOS): `brew install scour`
* pip (any OS): `pip install scour` or `pip3 install scour`

### How to install oxipng

* Homebrew (macOS): `brew install oxipng`
* Other systems: check [oxipng releases](https://github.com/oxipng/oxipng/releases) or your package manager (e.g. `cargo install oxipng` if you have Rust)

### Optional: timeout for stuck tasks

* `brew install coreutils` provides `gtimeout`. If available, the build script uses it to limit each Inkscape run so one stuck task does not freeze the whole export.

### Optional: alternatives to Inkscape for PNG export

The script uses **Inkscape** to export PNGs from the generated SVGs. If you prefer a different renderer (e.g. for consistency or to avoid Inkscape-related issues), you can install and use alternatives; the script does not integrate them automatically.

* **resvg** — Fast, accurate SVG renderer with a CLI. Install: `brew install resvg` (if available) or build from [RazrFalcon/resvg](https://github.com/RazrFalcon/resvg). Use it to rasterize the generated SVGs (e.g. `resvg input.svg output.png`) and optionally replace the PNG export step in your workflow.
* **CairoSVG** — Python-based SVG to PNG converter. Install: `pip install cairosvg`. Use: `cairosvg -o output.png -W 256 -H 256 input.svg` for a given size.
* The **SVG files** produced by the script are standard and can be opened or converted by any SVG-capable tool; only the **PNG export** step in `export.sh` is tied to Inkscape unless you change the script.

### Run Build

From the repository root:

```bash
./scripts/export.sh
```

After running, commit updated `badge/<size>/` and `mark/<size>/` folders as needed.

### Analyze base SVGs (no export)

To check that all base SVGs are valid and will export correctly:

```bash
./scripts/export.sh --analyze
```

This reports XML errors, `<g>` usage, viewBox issues, and **malformed path data** with a specific reason (e.g. `invalid_number`, `not_enough_params`, `iteration_limit`). Fix any reported files before running a full export.

## CDN URLs

You can access image files through:

### jsDelivr

```url
https://cdn.jsdelivr.net/gh/bchainhub/corecdn/{path}
```

Replace `{path}` with the desired image path.

### corecdn.info

```url
https://corecdn.info/{path}
```

Replace `{path}` with the desired image path.

## Usage Example

```html
<img src="https://cdn.jsdelivr.net/gh/bchainhub/corecdn/mark/256/xcb.png" alt="XCB Logo">
```

## Contributing

Contributions are welcome.

If you have suggestions, improvements, or fixes:

1. Open an issue first
2. Discuss major changes before implementation
3. Keep folder structure consistent
4. Do not manually edit generated folders — use the build script

## License

This software is licensed under the [CORE License](https://github.com/bchainhub/core-license/blob/master/LICENSE).
