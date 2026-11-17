"""Finds a widget in a `uiautomator dump` XML file by its visible label.

usage: ui_find.py ui.xml find|field|has|texts LABEL [FIELD_INDEX]
  find   prints "x y" (centre) of the best node whose label matches
  field  same, but only text fields; falls back to the FIELD_INDEX-th field
  has    exit 0 if LABEL appears anywhere on screen
  texts  prints every label on screen (for the run log)
"""
import re
import sys
import xml.etree.ElementTree as ET

path, mode, label = sys.argv[1], sys.argv[2], sys.argv[3]
index = int(sys.argv[4]) if len(sys.argv) > 4 else 0
try:
    nodes = list(ET.parse(path).getroot().iter("node"))
except Exception:
    sys.exit(1)


def labels(node):
    return [node.get(k) or "" for k in ("text", "content-desc", "hint")]


def centre(node):
    m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", node.get("bounds", ""))
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


if mode == "texts":
    seen = []
    for n in nodes:
        for t in labels(n):
            t = " ".join(t.split())
            if t and t not in seen:
                seen.append(t)
    print("\n".join("    | " + t for t in seen))
    sys.exit(0)

if mode == "has":
    found = any(label in " ".join(t.split()) for n in nodes for t in labels(n))
    sys.exit(0 if found else 1)

if mode == "field":
    fields = [n for n in nodes if "EditText" in (n.get("class") or "")]
    hit = [n for n in fields if any(label in t for t in labels(n))]
    pick = hit[0] if hit else (fields[index] if len(fields) > index else None)
    c = centre(pick) if pick is not None else None
    if c:
        print(c[0], c[1])
        sys.exit(0)
    sys.exit(1)

best = None
for n in nodes:
    c = centre(n)
    if not c:
        continue
    ls = [" ".join(t.split()) for t in labels(n)]
    exact = label in ls
    part = any(label in t for t in ls)
    if not part:
        continue
    score = (2 if exact else 0) + (1 if n.get("clickable") == "true" else 0)
    if best is None or score > best[0]:
        best = (score, c)
if best:
    print(best[1][0], best[1][1])
    sys.exit(0)
sys.exit(1)
