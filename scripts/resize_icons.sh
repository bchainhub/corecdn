#!/usr/bin/env bash
set -euo pipefail

# ==============================
# CONFIG
# ==============================
SIZES=(16 24 32 48 64 72 96 128 144 192 256 512 1024)

DEFAULT_JOBS="$(
	getconf _NPROCESSORS_ONLN 2>/dev/null \
	|| sysctl -n hw.ncpu 2>/dev/null \
	|| echo 4
)"
JOBS="${JOBS:-$DEFAULT_JOBS}"

SCRIPT_DIR="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
	pwd
)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

# ==============================
# INKSCAPE DETECTION
# ==============================
INKSCAPE_BIN="$(command -v inkscape || true)"
if [[ -z "$INKSCAPE_BIN" ]]; then
	echo "Error: inkscape not found in PATH."
	exit 1
fi

INK_VER="$("$INKSCAPE_BIN" --version | head -n 1)"
INK_MAJOR="$(echo "$INK_VER" | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\./){split($i,a,".");print a[1];exit}}')"
[[ -z "${INK_MAJOR:-}" ]] && INK_MAJOR=1

INK_MODE="1x"
[[ "$INK_MAJOR" -lt 1 ]] && INK_MODE="092"

echo "Starting icon export..."
echo "Repo root: $ROOT_DIR"
echo "Target sizes: ${SIZES[*]}"
echo "Inkscape: $INK_VER"
echo "Mode: $INK_MODE"
echo "Parallel jobs: $JOBS"
echo

# ==============================
# QUIET WRAPPER (filters macOS GTK/CMS noise)
# ==============================
inkscape_quiet() {
	"$@" 2> >(
		grep -vE '^(CMSSystem::load_profiles:|/Library/ColorSync/Profiles/Displays/|\(org\.inkscape\.Inkscape:.*\): Gtk-(CRITICAL|WARNING))' \
		1>&2
	)
}

# ==============================
# CONCURRENCY (bash 3.2 safe)
# ==============================
pids=()
spawn_limited() {
	"$@" &
	pids+=("$!")
	if [[ "${#pids[@]}" -ge "$JOBS" ]]; then
		wait "${pids[0]}"
		pids=("${pids[@]:1}")
	fi
}
wait_all() {
	for pid in "${pids[@]}"; do
		wait "$pid"
	done
	pids=()
}

# ==============================
# INKSCAPE HELPERS (1.x)
# ==============================
get_selection_width_1x() {
	local svg="$1"
	inkscape_quiet "$INKSCAPE_BIN" "$svg" \
		--actions="select-all;query-width" \
		--batch-process | tail -n 1
}

export_resized_svg_1x() {
	local svg="$1"
	local scale="$2"
	local out_svg="$3"

	inkscape_quiet "$INKSCAPE_BIN" "$svg" \
		--actions="select-all;transform-scale:${scale};page-fit-to-selection;export-type:svg;export-plain-svg;export-filename:${out_svg};export-overwrite;export-do" \
		--batch-process >/dev/null
}

export_png_1x() {
	local svg="$1"
	local size="$2"
	local out_png="$3"

	inkscape_quiet "$INKSCAPE_BIN" "$svg" \
		--export-type=png \
		--export-area-drawing \
		--export-width="$size" \
		--export-filename="$out_png" \
		>/dev/null
}

# ==============================
# INKSCAPE HELPERS (0.92 fallback)
# ==============================
export_png_092() {
	local svg="$1"
	local size="$2"
	local out_png="$3"

	inkscape_quiet "$INKSCAPE_BIN" -z -f "$svg" \
		--export-area-drawing \
		--export-png="$out_png" \
		--export-width="$size" \
		>/dev/null
}

process_one_size() {
	local svg="$1"
	local size="$2"
	local out_svg="$3"
	local out_png="$4"
	local orig_w="$5"

	if [[ "$INK_MODE" == "1x" ]]; then
		local scale
		scale="$(awk -v t="$size" -v o="$orig_w" 'BEGIN{printf "%.10f",(t/o)}')"
		export_resized_svg_1x "$svg" "$scale" "$out_svg"
		export_png_1x "$out_svg" "$size" "$out_png"
	else
		cp -f "$svg" "$out_svg"
		export_png_092 "$svg" "$size" "$out_png"
	fi
}

# ==============================
# FIND SVG FILES
# ==============================
SVG_FILES=()
while IFS= read -r -d '' f; do
	SVG_FILES+=("$f")
done < <(find "$ROOT_DIR" -type f -path "*/base/*.svg" -print0)

if [[ ${#SVG_FILES[@]} -eq 0 ]]; then
	echo "No SVG files found under */base/ (searched under: $ROOT_DIR)"
	exit 0
fi

echo "Found ${#SVG_FILES[@]} SVG file(s)"
echo

# ==============================
# PROCESS
# ==============================
for svg in "${SVG_FILES[@]}"; do
	echo "Processing: $svg"

	base_dir="$(dirname "$svg")"
	base_name="$(basename "$svg" .svg)"
	parent_dir="$(dirname "$base_dir")"

	orig_w=0
	if [[ "$INK_MODE" == "1x" ]]; then
		orig_w="$(get_selection_width_1x "$svg" | awk '{print $1+0}')"
		if [[ "$orig_w" == "0" ]]; then
			echo "	! Could not determine drawing width. Skipping."
			echo
			continue
		fi
	fi

	for size in "${SIZES[@]}"; do
		out_dir="${parent_dir}/${size}"
		out_svg="${out_dir}/${base_name}.svg"
		out_png="${out_dir}/${base_name}.png"

		mkdir -p "$out_dir"
		echo "	→ ${size}px (geometry-resize svg + png)"
		spawn_limited process_one_size "$svg" "$size" "$out_svg" "$out_png" "$orig_w"
	done

	echo
done

wait_all
echo "All icons exported successfully."
