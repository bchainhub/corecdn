#!/usr/bin/env bash
set -euo pipefail

# ==============================
# FLAGS
# ==============================
OVERWRITE=0
VERBOSE=0
MINIFY_SVG=1
MINIFY_PNG=1

for arg in "$@"; do
	case "$arg" in
		--overwrite)
			OVERWRITE=1
			shift
			;;
		--verbose)
			VERBOSE=1
			shift
			;;
		--svgnominify)
			MINIFY_SVG=0
			shift
			;;
		--pngnominify)
			MINIFY_PNG=0
			shift
			;;
	esac
done

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
# INKSCAPE
# ==============================
INKSCAPE_BIN="$(command -v inkscape || true)"
if [[ -z "$INKSCAPE_BIN" ]]; then
	echo "Error: inkscape not found in PATH."
	exit 1
fi

# ==============================
# SVG MINIFICATION
# ==============================
SCOUR_BIN="$(command -v scour || true)"
minify_svg() {
	local f="$1"
	[[ "$MINIFY_SVG" -eq 0 || -z "$SCOUR_BIN" ]] && return 0
	# Minify to temp file then replace (safe overwrite)
	"$SCOUR_BIN" -q \
		-i "$f" \
		-o "${f}.min" \
		--no-line-breaks \
		--remove-descriptive-elements \
		--enable-comment-stripping \
		--set-precision=4 \
		&& mv "${f}.min" "$f"
}

# ==============================
# PNG MINIFICATION (lossless)
# ==============================
OXIPNG_BIN="$(command -v oxipng || true)"
minify_png() {
	local f="$1"
	[[ "$MINIFY_PNG" -eq 0 || -z "$OXIPNG_BIN" ]] && return 0
	# Lossless compress in place (oxipng overwrites by default)
	"$OXIPNG_BIN" -q -o 6 "$f" 2>/dev/null || true
}

# ==============================
# QUIET / VERBOSE MODE
# ==============================
inkscape_run() {
	if [[ "$VERBOSE" -eq 1 ]]; then
		"$INKSCAPE_BIN" "$@"
	else
		script -q /dev/null "$INKSCAPE_BIN" "$@" >/dev/null 2>&1
	fi
}

log() {
	if [[ "$VERBOSE" -eq 1 ]]; then
		echo "$@"
	fi
}

echo "Starting icon export..."
echo "Repo root: $ROOT_DIR"
echo "Overwrite mode: $OVERWRITE"
echo "Verbose mode: $VERBOSE"
echo "Parallel jobs: $JOBS"
if [[ "$MINIFY_SVG" -eq 1 && -n "$SCOUR_BIN" ]]; then
	echo "SVG minification: on (scour)"
elif [[ "$MINIFY_SVG" -eq 0 ]]; then
	echo "SVG minification: off (--svgnominify)"
else
	echo "SVG minification: off (install scour: brew install scour, or pip install scour)"
fi
if [[ "$MINIFY_PNG" -eq 1 && -n "$OXIPNG_BIN" ]]; then
	echo "PNG minification: on (oxipng)"
elif [[ "$MINIFY_PNG" -eq 0 ]]; then
	echo "PNG minification: off (--pngnominify)"
else
	echo "PNG minification: off (install oxipng: brew install oxipng)"
fi
echo

# ==============================
# CONCURRENCY
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
# EXPORT SQUARE SVG
# ==============================
export_square_svg() {
	local input_svg="$1"
	local size="$2"
	local output_svg="$3"

	inkscape_run "$input_svg" \
		--batch-process \
		--actions="
			select-all;
			object-to-path;
			page-fit-to-selection;
			document-set-width:$size;
			document-set-height:$size;
			select-all;
			object-align:hcenter;
			object-align:vcenter;
			export-plain-svg;
			export-filename:$output_svg;
		"
}

# ==============================
# EXPORT SQUARE PNG
# ==============================
export_square_png() {
	local input_svg="$1"
	local size="$2"
	local output_png="$3"

	inkscape_run "$input_svg" \
		--export-type=png \
		--export-area-page \
		--export-width="$size" \
		--export-height="$size" \
		--export-background-opacity=0 \
		--export-filename="$output_png"
}

# ==============================
# PROCESS ONE SIZE
# ==============================
process_one_size() {
	local svg="$1"
	local size="$2"
	local out_svg="$3"
	local out_png="$4"

	if [[ "$OVERWRITE" -eq 0 && -f "$out_svg" && -f "$out_png" ]]; then
		log "	→ ${size}px (skipped, exists)"
		return
	fi

	log "	→ ${size}px (exporting)"

	export_square_svg "$svg" "$size" "$out_svg"
	export_square_png "$out_svg" "$size" "$out_png"
	minify_svg "$out_svg"
	minify_png "$out_png"
}

# ==============================
# CHECK FOR <g> TAGS (not supported)
# ==============================
svg_has_g_tag() {
	grep -qE '<g([[:space:]]|>)' "$1"
}

# ==============================
# FIND SVG FILES
# ==============================
SVG_FILES=()

while IFS= read -r -d '' f; do
	SVG_FILES+=("$f")
done < <(find "$ROOT_DIR" -type f -path "*/base/*.svg" -print0)

if [[ ${#SVG_FILES[@]} -eq 0 ]]; then
	echo "No SVG files found under */base/"
	exit 0
fi

echo "Found ${#SVG_FILES[@]} SVG file(s)"
echo

# ==============================
# MAIN LOOP
# ==============================
for svg in "${SVG_FILES[@]}"; do
	if svg_has_g_tag "$svg"; then
		echo "Warning: $svg contains <g> tag(s) and will not be processed. Ungroup in Inkscape (Object → Ungroup) and save, then re-run."
		echo
		continue
	fi

	echo "Processing: $svg"

	base_dir="$(dirname "$svg")"
	base_name="$(basename "$svg" .svg)"
	parent_dir="$(dirname "$base_dir")"

	for size in "${SIZES[@]}"; do
		out_dir="${parent_dir}/${size}"
		out_svg="${out_dir}/${base_name}.svg"
		out_png="${out_dir}/${base_name}.png"

		mkdir -p "$out_dir"

		spawn_limited process_one_size \
			"$svg" "$size" "$out_svg" "$out_png"
	done

	echo
done

wait_all
echo "All icons exported successfully."
