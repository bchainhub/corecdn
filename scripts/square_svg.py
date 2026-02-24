#!/usr/bin/env python3
"""
Make an SVG canvas square and center the content. Preserves aspect ratio; no stretch.
Reads SVG from path, sets viewBox to a square (side = max(width, height)), wraps content
in a group with translate(dx, dy) to center, and sets width/height to the given pixel size.
Usage: square_svg.py <svg_path> <size>
"""
import os
import sys
import tempfile
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
NS = {"svg": SVG_NS}


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("Usage: square_svg.py <svg_path> <size>\n")
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

    # Get viewBox: "minX minY width height" or from width/height
    view_box = root.get("viewBox")
    if view_box:
        parts = view_box.strip().replace(",", " ").split()
        if len(parts) >= 4:
            min_x = float(parts[0])
            min_y = float(parts[1])
            w = float(parts[2])
            h = float(parts[3])
        else:
            sys.stderr.write("Invalid viewBox\n")
            sys.exit(1)
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

    # Build a wrapper group with transform
    wrapper = ET.Element(q("g"))
    wrapper.set("transform", "translate(%s,%s)" % (dx, dy))

    # Move all current children into the wrapper (preserve order)
    children = list(root)
    for child in children:
        root.remove(child)
        wrapper.append(child)
    root.append(wrapper)

    # Set square viewBox and output size
    root.set("viewBox", "0 0 %s %s" % (side, side))
    root.set("width", str(size))
    root.set("height", str(size))

    # Write to a temp file then replace
    with tempfile.NamedTemporaryFile(mode="w", suffix=".svg", delete=False) as out:
        tmp = out.name
    try:
        with open(tmp, "w", encoding="utf-8") as out:
            tree.write(
                out,
                encoding="unicode",
                method="xml",
                xml_declaration=True,
            )
        with open(tmp, "r", encoding="utf-8") as f:
            content = f.read()
        # Ensure root has xmlns and strip ns0: prefix from tags (ET writes namespaced tags)
        if 'xmlns="' not in content and 'xmlns=' not in content:
            content = content.replace("<svg ", '<svg xmlns="%s" ' % SVG_NS, 1)
        content = content.replace("<ns0:svg ", '<svg xmlns="%s" ' % SVG_NS, 1)
        content = content.replace("</ns0:svg>", "</svg>")
        content = content.replace(' xmlns:ns0="%s"' % SVG_NS, "")
        content = content.replace("ns0:", "")  # <ns0:g> -> <g>, etc.
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


if __name__ == "__main__":
    main()
