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
ANALYZE=0
# SVG resize: 0 = scale from base in Python only (better alignment); 1 = Inkscape export then normalize
INKSCAPE_SVG=0

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
		--analyze)
			ANALYZE=1
			shift
			;;
		--inkscape-svg)
			INKSCAPE_SVG=1
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
# --analyze: CHECK BASE SVGs FOR CORRECTNESS, THEN EXIT
# ==============================
if [[ "$ANALYZE" -eq 1 ]]; then
	PYTHON3_BIN="$(command -v python3 || true)"
	if [[ -z "$PYTHON3_BIN" ]]; then
		echo "Error: python3 not found (required for --analyze)."
		exit 1
	fi
	echo "Analyzing base SVGs in mark/base and badge/base..."
	echo "Repo root: $ROOT_DIR"
	echo
	"$PYTHON3_BIN" "${SCRIPT_DIR}/analyze_base_svg.py" "$ROOT_DIR"
	exit "$?"
fi

# ==============================
# INKSCAPE
# ==============================
INKSCAPE_BIN="$(command -v inkscape || true)"
if [[ -z "$INKSCAPE_BIN" ]]; then
	echo "Error: inkscape not found in PATH."
	exit 1
fi

# ==============================
# SVG RESIZE + CENTER (required: Homebrew librsvg)
# ==============================
# rsvg-convert (brew install librsvg) resizes SVG to a square and preserves aspect ratio.
RSVG_CONVERT_BIN="$(command -v rsvg-convert || true)"
if [[ -z "$RSVG_CONVERT_BIN" ]]; then
	echo "Error: rsvg-convert not found. Install librsvg: brew install librsvg"
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
	# Use precision 6 to avoid misaligned curves (4 can shift path points and break joins)
	"$SCOUR_BIN" -q \
		-i "$f" \
		-o "${f}.min" \
		--no-line-breaks \
		--remove-descriptive-elements \
		--enable-comment-stripping \
		--set-precision=6 \
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
# QUIET / VERBOSE MODE + TIMEOUT
# ==============================
# In verbose mode Inkscape stderr is shown (no filter) so you can see why it might hang.
# Optional: timeout so a stuck Inkscape doesn't freeze (timeout/gtimeout from coreutils).
INKSCAPE_TIMEOUT_BIN=""
for cmd in timeout gtimeout; do
	if command -v "$cmd" &>/dev/null; then
		INKSCAPE_TIMEOUT_BIN="$cmd"
		break
	fi
done
INKSCAPE_TIMEOUT_SEC=300
inkscape_run() {
	if [[ "$VERBOSE" -eq 1 ]]; then
		# Verbose: show full Inkscape stderr (Gtk/CMSSystem etc.) to debug freezes
		if [[ -n "$INKSCAPE_TIMEOUT_BIN" ]]; then
			"$INKSCAPE_TIMEOUT_BIN" "$INKSCAPE_TIMEOUT_SEC" "$INKSCAPE_BIN" "$@"
		else
			"$INKSCAPE_BIN" "$@"
		fi
	else
		if [[ -n "$INKSCAPE_TIMEOUT_BIN" ]]; then
			script -q /dev/null "$INKSCAPE_TIMEOUT_BIN" "$INKSCAPE_TIMEOUT_SEC" "$INKSCAPE_BIN" "$@" >/dev/null 2>&1
		else
			script -q /dev/null "$INKSCAPE_BIN" "$@" >/dev/null 2>&1
		fi
	fi
}

log() {
	if [[ "$VERBOSE" -eq 1 ]]; then
		echo "$@"
	fi
}

echo "Starting icon export…"
echo "Repo root: $ROOT_DIR"
echo "Inkscape: ${INKSCAPE_VER:-unknown} ($([[ "$INKSCAPE_LEGACY_ACTIONS" -eq 1 ]] && echo 'legacy actions' || echo '1.3+ actions'))"
echo "SVG resize+center: librsvg (rsvg-convert)"
echo "SVG source: $([[ "$INKSCAPE_SVG" -eq 1 ]] && echo 'Inkscape (--inkscape-svg)' || echo 'base SVG')"
echo "Overwrite mode: $OVERWRITE"
echo "Verbose mode: $VERBOSE"
echo "Parallel jobs: $JOBS"
[[ "$VERBOSE" -eq 1 ]] && echo "Tip: if export hangs, try JOBS=1. To auto-kill stuck tasks: brew install coreutils (gtimeout)."
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
# EXPORT SQUARE SVG (Inkscape does resizing)
# ==============================
# Base SVGs use viewBox 0 0 1024 1024. We scale content by (size/1024), fit canvas to selection,
# then export. This produces SVG and PNG at the requested pixel size without a Python post-process.
# Scale factor: size/1024 (e.g. 256 -> 0.25)
export_square_svg() {
	local input_svg="$1"
	local size="$2"
	local output_svg="$3"
	local scale
	scale="$(awk "BEGIN { printf \"%.6f\", $size/1024 }")"
	# Deep ungroup before export so no <g transform="..."> in output (legacy only; 1.3+ action name varies/not available)
	local ungroup_legacy="SelectionUnGroup;SelectionUnGroup;SelectionUnGroup;SelectionUnGroup;SelectionUnGroup"

	# Center selection on page as a whole (multiple paths = one unit); group = treat selection as single bbox
	local align_center="object-align:page,hcenter,vcenter,group"
	if [[ "$INKSCAPE_LEGACY_ACTIONS" -eq 1 ]]; then
		# Legacy (Inkscape < 1.3): scale, fit, set document to size×size, center on page, export
		inkscape_run "$input_svg" \
			--batch-process \
			--actions="
				select-all;
				object-to-path;
				page-fit-to-selection;
				select-all;
				transform-scale:$scale;
				select-all;
				page-fit-to-selection;
				document-set-width:$size;
				document-set-height:$size;
				select-all;
				$align_center;
				select-all;
				$ungroup_legacy;
				export-plain-svg;
				export-filename:$output_svg;
			"
	else
		# Inkscape 1.3+: scale, fit, center, export (no ungroup - action name not reliable across versions)
		inkscape_run "$input_svg" \
			--batch-process \
			--actions="select-all:all;object-to-path;page-fit-to-selection;select-all:all;transform-scale:$scale;select-all:all;page-fit-to-selection;select-all:all;$align_center;select-all:all;export-plain-svg;export-filename:$output_svg;export-do"
	fi
}

# ==============================
# NORMALIZE SVG TO SQUARE (resize + center via librsvg)
# ==============================
normalize_svg_to_square() {
	local svg_path="$1"
	local size="$2"
	[[ ! -f "$svg_path" ]] && return 1
	local tmp
	tmp="$(mktemp)"
	cp "$svg_path" "$tmp"
	"$RSVG_CONVERT_BIN" -w "$size" -h "$size" -a -f svg -o "$svg_path" "$tmp"
	local ret=$?
	rm -f "$tmp"
	return $ret
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
# Optional: run entire task under timeout so one stuck job (e.g. normalize) doesn't block forever.
# By default we scale from base in Python only (one transform = better alignment). Use --inkscape-svg for the old path.
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
	if [[ "$INKSCAPE_SVG" -eq 1 ]]; then
		log "	    [${size}px] Inkscape SVG..."
		export_square_svg "$svg" "$size" "$out_svg"
		log "	    [${size}px] Inkscape SVG done; resize to square..."
		normalize_svg_to_square "$out_svg" "$size"
	else
		log "	    [${size}px] copy base; resize to square..."
		cp "$svg" "$out_svg"
		normalize_svg_to_square "$out_svg" "$size"
	fi
	log "	    [${size}px] resize done; Inkscape PNG..."
	export_square_png "$out_svg" "$size" "$out_png"
	log "	    [${size}px] done."
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

# Count valid base files (no <g> tag) for progress total
VALID_BASE_COUNT=0
for svg in "${SVG_FILES[@]}"; do
	svg_has_g_tag "$svg" || ((VALID_BASE_COUNT++)) || true
done
TOTAL_TASKS=$((VALID_BASE_COUNT * ${#SIZES[@]}))

echo "Found ${#SVG_FILES[@]} SVG file(s) ($VALID_BASE_COUNT to export), $TOTAL_TASKS tasks"
echo

# ==============================
# PROGRESS REPORTER (runs in background until wait_all)
# ==============================
export EXPORT_PROGRESS_VERBOSE="$VERBOSE"
export EXPORT_PROGRESS_TOTAL="$TOTAL_TASKS"
export EXPORT_PROGRESS_ROOT="$ROOT_DIR"
progress_reporter() {
	local total="$EXPORT_PROGRESS_TOTAL"
	local root="$EXPORT_PROGRESS_ROOT"
	local verbose="$EXPORT_PROGRESS_VERBOSE"
	local width=28
	while true; do
		sleep 1
		[[ -z "$root" || "$total" -eq 0 ]] && continue
		current=$(find "$root"/mark "$root"/badge -mindepth 2 -maxdepth 2 -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
		[[ -z "$current" ]] && current=0
		if [[ "$verbose" -eq 1 ]]; then
			printf "Export progress: %s/%s\n" "$current" "$total"
		else
			filled=$((width * current / total))
			[[ "$filled" -gt "$width" ]] && filled=$width
			empty=$((width - filled))
			bar="[$(printf "%${filled}s" "" | tr ' ' '=')$(printf "%${empty}s" "" | tr ' ' '-')]"
			printf "\r  Export %s %s/%s " "$bar" "$current" "$total"
		fi
	done
}
progress_reporter &
PROGRESS_PID=$!
# Ensure Ctrl+C and normal exit kill the progress reporter so it doesn't run forever
trap 'kill "$PROGRESS_PID" 2>/dev/null; exit 130' INT TERM
trap 'kill "$PROGRESS_PID" 2>/dev/null' EXIT

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
kill "$PROGRESS_PID" 2>/dev/null || true
[[ "$VERBOSE" -eq 0 ]] && printf "\n"

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
