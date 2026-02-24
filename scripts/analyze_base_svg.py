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
import sys
import xml.etree.ElementTree as ET

# Import from same dir so export.sh can run: python3 scripts/analyze_base_svg.py ROOT
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)
from normalize_svg_canvas import path_d_analyze

SVG_NS = "http://www.w3.org/2000/svg"


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
