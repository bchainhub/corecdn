#!/usr/bin/env bash
set -euo pipefail

# ==============================
# FLAGS
# ==============================
OVERWRITE=0
VERBOSE=0
MINIFY_SVG=1
MINIFY_PNG=1
NOADVERT=0

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
		--noadvert)
			NOADVERT=1
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
# --noadvert: STRIP BRANDING FROM BASE SVGs ONLY, THEN EXIT
# ==============================
# Known advertisement/branding attributes to remove from <svg> root (e.g. Affinity/Serif).
# Disabled by default; when --noadvert is set, only this runs (no export).
strip_svg_adverts() {
	local f="$1"
	[[ ! -f "$f" ]] && return 1
	local tmp
	tmp="$(mktemp)"
	# Remove known branding attributes (optional leading whitespace before attribute)
	# Serif/Affinity: xmlns:serif="http://www.serif.com/"
	sed 's/[[:space:]]*xmlns:serif="http:\/\/www\.serif\.com\/"//g' \
		"$f" > "$tmp" && mv "$tmp" "$f"
}

if [[ "$NOADVERT" -eq 1 ]]; then
	echo "Running in noadvert mode: stripping branding from */base/*.svg only."
	echo "Repo root: $ROOT_DIR"
	echo
	count=0
	while IFS= read -r -d '' f; do
		strip_svg_adverts "$f"
		echo "Stripped: $f"
		((count++)) || true
	done < <(find "$ROOT_DIR" -type f -path "*/base/*.svg" -print0 2>/dev/null)
	if [[ "$count" -eq 0 ]]; then
		echo "No SVG files found under */base/"
	else
		echo
		echo "Done. Stripped $count base SVG file(s)."
	fi
	exit 0
fi

# ==============================
# INKSCAPE
# ==============================
INKSCAPE_BIN="$(command -v inkscape || true)"
if [[ -z "$INKSCAPE_BIN" ]]; then
	echo "Error: inkscape not found in PATH."
	exit 1
fi
# Parse major.minor (e.g. 1.3 from "Inkscape 1.3.2 ...") for action compatibility
INKSCAPE_VER="$("$INKSCAPE_BIN" --version 2>/dev/null | sed -n 's/.*[Ii]nkscape \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
INKSCAPE_VER_MAJOR="${INKSCAPE_VER%%.*}"
INKSCAPE_VER_MINOR="${INKSCAPE_VER#*.}"
INKSCAPE_VER_MINOR="${INKSCAPE_VER_MINOR%%.*}"
# 1.3+ uses different action names (document-set-width/height removed); 1.2 and older use legacy actions
INKSCAPE_LEGACY_ACTIONS=0
if [[ -n "$INKSCAPE_VER_MAJOR" && -n "$INKSCAPE_VER_MINOR" ]]; then
	if [[ "$INKSCAPE_VER_MAJOR" -lt 1 ]] || [[ "$INKSCAPE_VER_MAJOR" -eq 1 && "$INKSCAPE_VER_MINOR" -lt 3 ]]; then
		INKSCAPE_LEGACY_ACTIONS=1
	fi
fi

# ==============================
# SVG MINIFICATION
# ==============================
SCOUR_BIN="$(command -v scour || true)"
minify_svg() {
	local f="$1"
	[[ "$MINIFY_SVG" -eq 0 || -z "$SCOUR_BIN" ]] && return 0
	[[ ! -f "$f" ]] && return 0
	# Minify to temp file then replace (safe overwrite). Safe to call on missing file (no-op).
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
	[[ ! -f "$f" ]] && return 0
	# Lossless compress in place (oxipng overwrites by default). Safe to call on missing file (no-op).
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
echo "Inkscape: ${INKSCAPE_VER:-unknown} ($([[ "$INKSCAPE_LEGACY_ACTIONS" -eq 1 ]] && echo 'legacy actions' || echo '1.3+ actions'))"
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
# EXPORT SQUARE SVG (version-specific actions)
# ==============================
# Inkscape 1.3+ removed document-set-width/height and changed action parsing; use single-line + export-do.
# Older Inkscape uses legacy multi-line actions with document-set-width/height.
export_square_svg() {
	local input_svg="$1"
	local size="$2"
	local output_svg="$3"

	if [[ "$INKSCAPE_LEGACY_ACTIONS" -eq 1 ]]; then
		# Legacy (Inkscape < 1.3): document-set-width/height, multi-line actions
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
	else
		# Inkscape 1.3+: no document-set-* (removed), single-line, explicit export-do
		inkscape_run "$input_svg" \
			--batch-process \
			--actions="select-all:all;object-to-path;page-fit-to-selection;select-all:all;object-align:hcenter;object-align:vcenter;export-plain-svg;export-filename:$output_svg;export-do"
	fi
}

# ==============================
# SQUARE CANVAS POST-PROCESS (center content, no stretch)
# ==============================
# Inkscape 1.3+ does not set document size; exported SVG may be non-square.
# This step makes the canvas square and centers the content so PNG export is not deformed.
PYTHON3_BIN="$(command -v python3 || true)"
square_svg_canvas() {
	local svg_path="$1"
	local size="$2"
	[[ ! -f "$svg_path" ]] && return 1
	[[ -z "$PYTHON3_BIN" ]] && return 1
	"$PYTHON3_BIN" "${SCRIPT_DIR}/square_svg.py" "$svg_path" "$size" 2>/dev/null || true
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
	# Make canvas square and center content (fixes non-square / stretched output)
	square_svg_canvas "$out_svg" "$size"
	export_square_png "$out_svg" "$size" "$out_png"
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

# ==============================
# SECOND PASS: MINIFY ALL GENERATED FILES
# ==============================
# Minification runs after the full Inkscape batch. Progress bar (normal) or per-file (verbose).
MINIFY_FILES=()
if [[ "$MINIFY_SVG" -eq 1 && -n "$SCOUR_BIN" ]] || [[ "$MINIFY_PNG" -eq 1 && -n "$OXIPNG_BIN" ]]; then
	for size in "${SIZES[@]}"; do
		for dir in "$ROOT_DIR"/mark "$ROOT_DIR"/badge; do
			[[ ! -d "$dir/$size" ]] && continue
			for f in "$dir/$size"/*.svg; do [[ -f "$f" ]] && MINIFY_FILES+=("$f" "svg"); done
			for f in "$dir/$size"/*.png; do [[ -f "$f" ]] && MINIFY_FILES+=("$f" "png"); done
		done
	done
	MINIFY_TOTAL=$((${#MINIFY_FILES[@]} / 2))
	if [[ "$MINIFY_TOTAL" -gt 0 ]]; then
		echo "Minifying $MINIFY_TOTAL generated file(s)..."
		MINIFY_PROGRESS_BAR_WIDTH=30
		idx=0
		i=0
		while [[ $i -lt "${#MINIFY_FILES[@]}" ]]; do
			f="${MINIFY_FILES[$i]}"
			typ="${MINIFY_FILES[$((i+1))]}"
			((idx++)) || true
			if [[ "$VERBOSE" -eq 1 ]]; then
				echo "  minify: $f"
			else
				# Progress bar: [=====>     ] idx/total
				filled=$((MINIFY_PROGRESS_BAR_WIDTH * idx / MINIFY_TOTAL))
				empty=$((MINIFY_PROGRESS_BAR_WIDTH - filled))
				bar="[$(printf "%${filled}s" "" | tr ' ' '=')$(printf "%${empty}s" "" | tr ' ' ' ')]"
				printf "\r  %s %s/%s" "$bar" "$idx" "$MINIFY_TOTAL"
			fi
			if [[ "$typ" == "svg" ]]; then minify_svg "$f"; else minify_png "$f"; fi
			((i += 2)) || true
		done
		[[ "$VERBOSE" -eq 0 ]] && echo
		echo "Minification done."
	fi
fi

echo "All icons exported successfully."
