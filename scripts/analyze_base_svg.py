#!/usr/bin/env python3
"""
Analyze SVG files in mark/base and badge/base for export readiness.
Reports: XML parse errors, <g> tags (unsupported), missing/invalid viewBox,
and malformed path data (with exact reason).

Usage: analyze_base_svg.py <repo_root>
  or   analyze_base_svg.py  (uses cwd as repo root)

Called by scripts/export.sh when --analyze is passed.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"

# Path command letter -> number of params per repetition (for path 'd' parsing)
_PATH_PARAMS = {
    "M": 2, "m": 2, "L": 2, "l": 2, "H": 1, "h": 1, "V": 1, "v": 1,
    "C": 6, "c": 6, "S": 4, "s": 4, "Q": 4, "q": 4, "T": 2, "t": 2,
    "A": 7, "a": 7, "Z": 0, "z": 0,
}
_PATH_PARSE_MAX_ITER = 2_000_000


def path_d_analyze(d):
    """
    Parse path 'd' and return (bbox, None) on success or (None, reason) on failure.
    Reasons: empty, no_tokens, iteration_limit, not_enough_params, invalid_number, no_geometry.
    """
    if not d or not d.strip():
        return (None, "empty")
    tokens = re.findall(r"[MLHVCSQTAZmlhvcsqtaz]|[-+]?(?:\d*\.?\d+(?:[eE][-+]?\d+)?)", d)
    if not tokens:
        return (None, "no_tokens")
    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")
    i = 0
    current_x = current_y = 0.0
    start_x = start_y = 0.0
    iterations = 0

    def consume(n):
        nonlocal i
        if i + n > len(tokens):
            raise IndexError("not enough params")
        vals = [float(tokens[i + k]) for k in range(n)]
        i += n
        return vals

    def update(*pts):
        nonlocal min_x, min_y, max_x, max_y
        for (x, y) in pts:
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)

    try:
        while i < len(tokens):
            iterations += 1
            if iterations > _PATH_PARSE_MAX_ITER:
                return (None, "iteration_limit")
            t = tokens[i]
            if t not in _PATH_PARAMS:
                i += 1
                continue
            cmd = t
            i += 1
            n = _PATH_PARAMS[cmd]
            if n == 0:
                update((start_x, start_y))
                continue
            first = True
            while i + n <= len(tokens) and (
                first or (tokens[i] not in _PATH_PARAMS or tokens[i] in "Mm")
            ):
                if tokens[i] in _PATH_PARAMS and not first and (tokens[i] not in "Mm" or cmd not in "Mm"):
                    break
                first = False
                if cmd in "Mm" and not first:
                    cmd = "L" if cmd == "M" else "l"
                    n = 2
                if cmd in "ML":
                    x, y = consume(2)
                    current_x, current_y = x, y
                    update((x, y))
                elif cmd in "ml":
                    x, y = consume(2)
                    current_x, current_y = current_x + x, current_y + y
                    update((current_x, current_y))
                elif cmd == "H":
                    x = consume(1)[0]
                    current_x = x
                    update((x, current_y))
                elif cmd == "h":
                    current_x += consume(1)[0]
                    update((current_x, current_y))
                elif cmd == "V":
                    y = consume(1)[0]
                    current_y = y
                    update((current_x, y))
                elif cmd == "v":
                    current_y += consume(1)[0]
                    update((current_x, current_y))
                elif cmd == "C":
                    x1, y1, x2, y2, x, y = consume(6)
                    current_x, current_y = x, y
                    update((x, y))
                elif cmd == "c":
                    dx1, dy1, dx2, dy2, dx_val, dy_val = consume(6)
                    current_x += dx_val
                    current_y += dy_val
                    update((current_x, current_y))
                elif cmd == "S":
                    x2, y2, x, y = consume(4)
                    current_x, current_y = x, y
                    update((x, y))
                elif cmd == "s":
                    dx2, dy2, dx_val, dy_val = consume(4)
                    current_x += dx_val
                    current_y += dy_val
                    update((current_x, current_y))
                elif cmd == "Q":
                    x1, y1, x, y = consume(4)
                    current_x, current_y = x, y
                    update((x, y))
                elif cmd == "q":
                    dx1, dy1, dx_val, dy_val = consume(4)
                    current_x += dx_val
                    current_y += dy_val
                    update((current_x, current_y))
                elif cmd == "T":
                    x, y = consume(2)
                    current_x, current_y = x, y
                    update((x, y))
                elif cmd == "t":
                    dx_val, dy_val = consume(2)
                    current_x += dx_val
                    current_y += dy_val
                    update((current_x, current_y))
                elif cmd == "A":
                    rx, ry, rot, la, sweep, x, y = consume(7)
                    current_x, current_y = x, y
                    update((x, y))
                elif cmd == "a":
                    rx, ry, rot, la, sweep, dx_val, dy_val = consume(7)
                    current_x += dx_val
                    current_y += dy_val
                    update((current_x, current_y))
                if cmd in "Mm":
                    start_x, start_y = current_x, current_y
        if min_x == float("inf"):
            return (None, "no_geometry")
        return ((min_x, min_y, max_x, max_y), None)
    except IndexError:
        return (None, "not_enough_params")
    except ValueError:
        return (None, "invalid_number")


def _local_tag(el):
    raw = el.tag if isinstance(el.tag, str) else ""
    return raw.split("}")[-1] if "}" in raw else raw


def _has_g_element(root):
    """Return True if any <g> element exists."""
    for el in root.iter():
        if _local_tag(el) == "g":
            return True
    return False


def _get_viewbox(root):
    vb = root.get("viewBox")
    if not vb:
        return None, "missing"
    parts = vb.strip().replace(",", " ").split()
    if len(parts) < 4:
        return None, "invalid (need 4 numbers)"
    try:
        vals = [float(parts[j]) for j in range(4)]
        return tuple(vals), None
    except ValueError:
        return None, "invalid (non-numeric)"


def analyze_svg(path):
    """
    Analyze one SVG file. Returns (issues_list, path_count).
    issues_list: list of strings (human-readable issues)
    """
    issues = []
    path_count = 0
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        return (["XML parse error: %s" % e], 0)
    root = tree.getroot()

    if _has_g_element(root):
        issues.append("Contains <g> elements (ungroup in Inkscape before export)")

    viewbox, vb_err = _get_viewbox(root)
    if vb_err:
        issues.append("viewBox: %s" % vb_err)
    elif viewbox and (viewbox[2] <= 0 or viewbox[3] <= 0):
        issues.append("viewBox: width or height <= 0")

    for el in root.iter():
        if _local_tag(el) != "path":
            continue
        path_count += 1
        d = el.get("d") or ""
        bbox, reason = path_d_analyze(d)
        if reason is not None:
            issues.append("Path %d 'd' %s (len=%d)" % (path_count, reason, len(d)))

    return (issues, path_count)


def main():
    if len(sys.argv) > 1:
        root = os.path.abspath(sys.argv[1])
    else:
        root = os.path.abspath(os.getcwd())
    if not os.path.isdir(root):
        sys.stderr.write("Not a directory: %s\n" % root)
        sys.exit(1)

    base_dirs = [
        os.path.join(root, "mark", "base"),
        os.path.join(root, "badge", "base"),
    ]
    all_files = []
    for d in base_dirs:
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".svg"):
                    all_files.append(os.path.join(d, f))

    if not all_files:
        sys.stderr.write("No SVG files found under %s\n" % " or ".join(base_dirs))
        sys.exit(1)

    print("Analyzing %d SVG file(s) in mark/base and badge/base\n" % len(all_files))
    ok = 0
    with_issues = 0
    for path in all_files:
        rel = os.path.relpath(path, root)
        issues, num_paths = analyze_svg(path)
        if not issues:
            ok += 1
            print("  OK   %s (%d path(s))" % (rel, num_paths))
        else:
            with_issues += 1
            print("  FAIL %s" % rel)
            for msg in issues:
                print("       - %s" % msg)

    print("")
    print("Result: %d OK, %d with issues" % (ok, with_issues))
    if with_issues > 0:
        print("\nPath 'd' failure reasons:")
        print("  empty               - path has no content")
        print("  no_tokens           - no commands/numbers found (wrong format?)")
        print("  not_enough_params   - command has fewer numbers than required")
        print("  invalid_number      - expected a number but got something else (e.g. letter, Unicode minus,")
        print("                        or a path command like V/H in the middle of another command's params)")
        print("  iteration_limit     - path too long (> 2M segments, may hang)")
        print("  no_geometry         - no valid geometry after parsing")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
