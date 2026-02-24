#!/usr/bin/env python3
"""
Normalize an SVG canvas to a given pixel size: set viewBox to "0 0 size size",
bake scale and translate into path/element coordinates (no wrapper <g>), set width/height.

Called by scripts/export.sh after Inkscape export so the SVG is square and PNG export
is correct (Inkscape may leave a non-square viewBox). Uses content bbox for scale.

Usage: normalize_svg_canvas.py <svg_path> <size>
"""
import io
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
NS = {"svg": SVG_NS}

# Path command letter -> (num params per repetition, is_relative)
# A/a: rx ry x-axis-rotation large-arc sweep x y  (last 2 are point; for 'a' they're relative)
_PATH_PARAMS = {
    "M": 2, "m": 2, "L": 2, "l": 2, "H": 1, "h": 1, "V": 1, "v": 1,
    "C": 6, "c": 6, "S": 4, "s": 4, "Q": 4, "q": 4, "T": 2, "t": 2,
    "A": 7, "a": 7, "Z": 0, "z": 0,
}


def _t(x, y, scale, dx, dy):
    """Transform point: first translate then scale."""
    return (round(scale * (x + dx), 3), round(scale * (y + dy), 3))


# Max iterations in path parsing to avoid hangs on malformed or huge path data
_PATH_PARSE_MAX_ITER = 2_000_000

def _path_d_bbox(d):
    """Return (min_x, min_y, max_x, max_y) from path d, or None if empty/invalid."""
    if not d or not d.strip():
        return None
    tokens = re.findall(r"[MLHVCSQTAZmlhvcsqtaz]|[-+]?(?:\d*\.?\d+(?:[eE][-+]?\d+)?)", d)
    if not tokens:
        return None
    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")
    i = 0
    current_x = current_y = 0.0
    start_x = start_y = 0.0
    iterations = 0

    def consume(n):
        nonlocal i
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

    while i < len(tokens):
        iterations += 1
        if iterations > _PATH_PARSE_MAX_ITER:
            return None
        t = tokens[i]
        if t not in _PATH_PARAMS:
            i += 1
            continue
        cmd = t
        i += 1
        n = _PATH_PARAMS[cmd]
        if n == 0:  # Z/z - close path to start; include start point in bbox
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
                update((x, y))  # endpoint only; control points can extend outside visible curve
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
            # Do not break after first M; keep consuming implicit L pairs for full bbox
    if min_x == float("inf"):
        return None
    return (min_x, min_y, max_x, max_y)


def path_d_analyze(d):
    """
    Parse path 'd' and return (bbox, None) on success or (None, reason) on failure.
    Used by --analyze to report what is malformed. Reasons:
      - "empty": d is empty or whitespace
      - "no_tokens": no path commands/numbers found
      - "iteration_limit": path has too many segments (> _PATH_PARSE_MAX_ITER)
      - "not_enough_params": a command has fewer numbers than required (e.g. M with one number)
      - "invalid_number": a token could not be parsed as float
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


def _element_bbox(el):
    """Bounding box for one element; return (min_x, min_y, max_x, max_y) or None."""
    raw = el.tag if isinstance(el.tag, str) else ""
    tag = raw.split("}")[-1] if "}" in raw else raw
    if tag == "path":
        return _path_d_bbox(el.get("d") or "")
    if tag == "circle":
        cx = el.get("cx")
        cy = el.get("cy")
        r = el.get("r")
        if cx is not None and cy is not None and r is not None:
            cx, cy, r = float(cx), float(cy), float(r)
            return (cx - r, cy - r, cx + r, cy + r)
    elif tag == "ellipse":
        cx, cy = el.get("cx"), el.get("cy")
        rx, ry = el.get("rx"), el.get("ry")
        if all(x is not None for x in (cx, cy, rx, ry)):
            cx, cy, rx, ry = float(cx), float(cy), float(rx), float(ry)
            return (cx - rx, cy - ry, cx + rx, cy + ry)
    elif tag == "line":
        x1, y1 = el.get("x1"), el.get("y1")
        x2, y2 = el.get("x2"), el.get("y2")
        if all(x is not None for x in (x1, y1, x2, y2)):
            return (min(float(x1), float(x2)), min(float(y1), float(y2)),
                    max(float(x1), float(x2)), max(float(y1), float(y2)))
    elif tag == "rect":
        x = float(el.get("x") or 0)
        y = float(el.get("y") or 0)
        w = float(el.get("width") or 0)
        h = float(el.get("height") or 0)
        return (x, y, x + w, y + h)
    elif tag in ("polyline", "polygon"):
        pts = el.get("points")
        if pts:
            parts = re.split(r"[\s,]+", pts.strip())
            if len(parts) >= 2 and len(parts) % 2 == 0:
                xs = [float(parts[j]) for j in range(0, len(parts), 2)]
                ys = [float(parts[j + 1]) for j in range(0, len(parts), 2)]
                return (min(xs), min(ys), max(xs), max(ys))
    return None


def _content_bbox(root):
    """Union bounding box of all path/shape elements; return (min_x, min_y, w, h) or None."""
    boxes = []

    def walk(el):
        b = _element_bbox(el)
        if b is not None:
            boxes.append(b)
        for child in el:
            walk(child)

    walk(root)
    if not boxes:
        return None
    min_x = min(b[0] for b in boxes)
    min_y = min(b[1] for b in boxes)
    max_x = max(b[2] for b in boxes)
    max_y = max(b[3] for b in boxes)
    return (min_x, min_y, max_x - min_x, max_y - min_y)


def _transform_path_d(d, scale, dx, dy):
    """Apply translate(dx,dy) then scale(scale) to path d; return new d string."""
    if not d or not d.strip():
        return d
    # Tokenize: commands and numbers
    tokens = re.findall(r"[MLHVCSQTAZmlhvcsqtaz]|[-+]?(?:\d*\.?\d+(?:[eE][-+]?\d+)?)", d)
    if not tokens:
        return d
    out = []
    i = 0
    current_x = current_y = 0.0
    start_x = start_y = 0.0
    last_cmd = None
    iterations = 0

    def consume(n):
        nonlocal i
        vals = [float(tokens[i + k]) for k in range(n)]
        i += n
        return vals

    while i < len(tokens):
        iterations += 1
        if iterations > _PATH_PARSE_MAX_ITER:
            return d
        t = tokens[i]
        if t in _PATH_PARAMS:
            cmd = t
            i += 1
            n = _PATH_PARAMS[cmd]
            if n == 0:  # Z/z
                out.append("Z")
                current_x, current_y = start_x, start_y
                continue
            # Consume one set of params; for M/L we may have multiple pairs
            first = True
            while i + n <= len(tokens) and (
                first or (tokens[i] not in _PATH_PARAMS or tokens[i] in "Mm")
            ):
                if tokens[i] in _PATH_PARAMS and not first and (tokens[i] not in "Mm" or cmd not in "Mm"):
                    break
                first = False
                if cmd in "Mm" and not first and (last_cmd is not None and last_cmd in "Mm"):
                    cmd = "L" if cmd == "M" else "l"
                    n = 2
                if cmd in "ML":
                    x, y = consume(2)
                    nx, ny = _t(x, y, scale, dx, dy)
                    current_x, current_y = x, y
                    out.append("%s%s %s" % (cmd, nx, ny))
                elif cmd in "ml":
                    x, y = consume(2)
                    nx, ny = scale * x, scale * y
                    current_x, current_y = current_x + x, current_y + y
                    out.append("%s%s %s" % (cmd, round(nx, 3), round(ny, 3)))
                elif cmd == "H":
                    x = consume(1)[0]
                    nx, _ = _t(x, current_y, scale, dx, dy)
                    current_x = x
                    out.append("L%s %s" % (nx, round(scale * (current_y + dy), 3)))
                elif cmd == "h":
                    dx_val = consume(1)[0]
                    current_x += dx_val
                    out.append("l%s 0" % round(scale * dx_val, 3))
                elif cmd == "V":
                    y = consume(1)[0]
                    _, ny = _t(current_x, y, scale, dx, dy)
                    current_y = y
                    out.append("L%s %s" % (round(scale * (current_x + dx), 3), ny))
                elif cmd == "v":
                    dy_val = consume(1)[0]
                    current_y += dy_val
                    out.append("l0 %s" % round(scale * dy_val, 3))
                elif cmd == "C":
                    x1, y1, x2, y2, x, y = consume(6)
                    p1 = _t(x1, y1, scale, dx, dy)
                    p2 = _t(x2, y2, scale, dx, dy)
                    p = _t(x, y, scale, dx, dy)
                    current_x, current_y = x, y
                    out.append("C%s %s %s %s %s %s" % (p1[0], p1[1], p2[0], p2[1], p[0], p[1]))
                elif cmd == "c":
                    dx1, dy1, dx2, dy2, dx_val, dy_val = consume(6)
                    out.append("c%s %s %s %s %s %s" % (
                        round(scale * dx1, 3), round(scale * dy1, 3),
                        round(scale * dx2, 3), round(scale * dy2, 3),
                        round(scale * dx_val, 3), round(scale * dy_val, 3)))
                    current_x += dx_val
                    current_y += dy_val
                elif cmd == "S":
                    x2, y2, x, y = consume(4)
                    p2 = _t(x2, y2, scale, dx, dy)
                    p = _t(x, y, scale, dx, dy)
                    current_x, current_y = x, y
                    out.append("S%s %s %s %s" % (p2[0], p2[1], p[0], p[1]))
                elif cmd == "s":
                    dx2, dy2, dx_val, dy_val = consume(4)
                    out.append("s%s %s %s %s" % (
                        round(scale * dx2, 3), round(scale * dy2, 3),
                        round(scale * dx_val, 3), round(scale * dy_val, 3)))
                    current_x += dx_val
                    current_y += dy_val
                elif cmd == "Q":
                    x1, y1, x, y = consume(4)
                    p1 = _t(x1, y1, scale, dx, dy)
                    p = _t(x, y, scale, dx, dy)
                    current_x, current_y = x, y
                    out.append("Q%s %s %s %s" % (p1[0], p1[1], p[0], p[1]))
                elif cmd == "q":
                    dx1, dy1, dx_val, dy_val = consume(4)
                    out.append("q%s %s %s %s" % (
                        round(scale * dx1, 3), round(scale * dy1, 3),
                        round(scale * dx_val, 3), round(scale * dy_val, 3)))
                    current_x += dx_val
                    current_y += dy_val
                elif cmd == "T":
                    x, y = consume(2)
                    p = _t(x, y, scale, dx, dy)
                    current_x, current_y = x, y
                    out.append("T%s %s" % (p[0], p[1]))
                elif cmd == "t":
                    dx_val, dy_val = consume(2)
                    out.append("t%s %s" % (round(scale * dx_val, 3), round(scale * dy_val, 3)))
                    current_x += dx_val
                    current_y += dy_val
                elif cmd == "A":
                    rx, ry, rot, la, sweep, x, y = consume(7)
                    nrx, nry = round(scale * rx, 3), round(scale * ry, 3)
                    p = _t(x, y, scale, dx, dy)
                    current_x, current_y = x, y
                    out.append("A%s %s %s %s %s %s %s" % (nrx, nry, rot, la, sweep, p[0], p[1]))
                elif cmd == "a":
                    rx, ry, rot, la, sweep, dx_val, dy_val = consume(7)
                    out.append("a%s %s %s %s %s %s %s" % (
                        round(scale * rx, 3), round(scale * ry, 3), rot, la, sweep,
                        round(scale * dx_val, 3), round(scale * dy_val, 3)))
                    current_x += dx_val
                    current_y += dy_val
                if cmd in "Mm":
                    start_x, start_y = current_x, current_y
                last_cmd = cmd
                if cmd in "Mm" and n == 2:
                    break
    return " ".join(out)


def _apply_transform_to_element(el, scale, dx, dy):
    """Bake scale and translate into element coordinates. No wrapper <g>."""
    raw = el.tag if isinstance(el.tag, str) else ""
    tag = raw.split("}")[-1] if "}" in raw else raw
    if tag == "path":
        d = el.get("d")
        if d:
            el.set("d", _transform_path_d(d, scale, dx, dy))
        for child in list(el):
            _apply_transform_to_element(child, scale, dx, dy)
        return
    if tag == "circle":
        cx = el.get("cx")
        cy = el.get("cy")
        r = el.get("r")
        if cx is not None and cy is not None:
            nx, ny = _t(float(cx), float(cy), scale, dx, dy)
            el.set("cx", str(nx))
            el.set("cy", str(ny))
        if r is not None:
            el.set("r", str(round(scale * float(r), 3)))
    elif tag == "ellipse":
        cx_s = el.get("cx")
        cy_s = el.get("cy")
        if cx_s is not None and cy_s is not None:
            nx, ny = _t(float(cx_s), float(cy_s), scale, dx, dy)
            el.set("cx", str(nx))
            el.set("cy", str(ny))
        for a in ("rx", "ry"):
            v = el.get(a)
            if v is not None:
                el.set(a, str(round(scale * float(v), 3)))
    elif tag == "line":
        x1_s, y1_s = el.get("x1"), el.get("y1")
        x2_s, y2_s = el.get("x2"), el.get("y2")
        if x1_s is not None and y1_s is not None:
            p1 = _t(float(x1_s), float(y1_s), scale, dx, dy)
            el.set("x1", str(p1[0]))
            el.set("y1", str(p1[1]))
        if x2_s is not None and y2_s is not None:
            p2 = _t(float(x2_s), float(y2_s), scale, dx, dy)
            el.set("x2", str(p2[0]))
            el.set("y2", str(p2[1]))
    elif tag in ("rect", "foreignObject"):
        x = el.get("x")
        y = el.get("y")
        if x is not None and y is not None:
            nx, ny = _t(float(x), float(y), scale, dx, dy)
            el.set("x", str(nx))
            el.set("y", str(ny))
        for a in ("width", "height"):
            v = el.get(a)
            if v is not None:
                el.set(a, str(round(scale * float(v), 3)))
    elif tag in ("polyline", "polygon"):
        points = el.get("points")
        if points:
            parts = re.split(r"[\s,]+", points.strip())
            if len(parts) >= 2 and len(parts) % 2 == 0:
                new_pts = []
                for j in range(0, len(parts), 2):
                    nx, ny = _t(float(parts[j]), float(parts[j + 1]), scale, dx, dy)
                    new_pts.append("%s,%s" % (nx, ny))
                el.set("points", " ".join(new_pts))
    for child in list(el):
        _apply_transform_to_element(child, scale, dx, dy)


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("Usage: normalize_svg_canvas.py <svg_path> <size>\n")
        sys.exit(1)
    path = sys.argv[1]
    try:
        size = int(sys.argv[2])
    except ValueError:
        sys.stderr.write("size must be an integer\n")
        sys.exit(1)

    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        sys.stderr.write(f"Parse error: {e}\n")
        sys.exit(1)
    root = tree.getroot()

    # Handle default namespace: tag may be {http://...}svg or just svg
    def q(tag):
        if tag.startswith("{"):
            return tag
        return "{%s}%s" % (SVG_NS, tag)

    # Bounds for centering: prefer content bbox when viewBox is square so the drawing is centered
    # (Inkscape may export a square viewBox with content off-center, e.g. left-aligned).
    # When viewBox is non-square (e.g. 0 0 166 256), use it so we center the canvas in a square.
    view_box = root.get("viewBox")
    view_box_rect = None
    if view_box:
        parts = view_box.strip().replace(",", " ").split()
        if len(parts) >= 4:
            view_box_rect = (float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
        else:
            view_box = None
    content = _content_bbox(root)
    if view_box_rect is not None:
        vbx, vby, vbw, vbh = view_box_rect
        # Square viewBox: center using actual content bbox so the graphic is centered.
        if abs(vbw - vbh) < 1e-6 and content is not None:
            min_x, min_y, w, h = content
        else:
            min_x, min_y, w, h = vbx, vby, vbw, vbh
    elif content is not None:
        min_x, min_y, w, h = content
    else:
        min_x = min_y = 0.0
        w = float(root.get("width", 0).replace("px", "")) or 0
        h = float(root.get("height", 0).replace("px", "")) or 0
        if w <= 0 or h <= 0:
            sys.stderr.write("Cannot determine SVG dimensions\n")
            sys.exit(1)

    side = max(w, h)
    if side <= 0:
        sys.exit(1)
    dx = (side - w) / 2.0 - min_x
    dy = (side - h) / 2.0 - min_y
    # Round to 3 decimals to avoid floating-point noise and misaligned curves in viewers
    side = round(side, 3)
    dx = round(dx, 3)
    dy = round(dy, 3)
    scale = round(size / side, 6)

    # Bake scale and translate into all coordinate elements (no wrapper <g>)
    for child in list(root):
        _apply_transform_to_element(child, scale, dx, dy)

    # Set viewBox to match requested size (1 unit = 1 pixel) and output dimensions
    root.set("viewBox", "0 0 %s %s" % (size, size))
    root.set("width", str(size))
    root.set("height", str(size))

    # Write tree to memory (no temp file), apply regex fixes, write to path
    buf = io.StringIO()
    tree.write(
        buf,
        encoding="unicode",
        method="xml",
        xml_declaration=True,
    )
    content = buf.getvalue()
    # Ensure root has xmlns and strip ns0: prefix from tags (ET writes namespaced tags)
    if 'xmlns="' not in content and 'xmlns=' not in content:
        content = content.replace("<svg ", '<svg xmlns="%s" ' % SVG_NS, 1)
    content = content.replace("<ns0:svg ", '<svg xmlns="%s" ' % SVG_NS, 1)
    content = content.replace("</ns0:svg>", "</svg>")
    content = content.replace(' xmlns:ns0="%s"' % SVG_NS, "")
    content = content.replace("ns0:", "")  # <ns0:g> -> <g>, etc.
    # Force viewBox and width/height on root so the original is never kept
    new_viewbox = 'viewBox="0 0 %s %s"' % (size, size)
    content = re.sub(r'\bviewBox="[^"]*"', new_viewbox, content, count=1)
    content = re.sub(r'\bwidth="[^"]*"', 'width="%s"' % size, content, count=1)
    content = re.sub(r'\bheight="[^"]*"', 'height="%s"' % size, content, count=1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


if __name__ == "__main__":
    main()
