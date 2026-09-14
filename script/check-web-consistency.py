#!/usr/bin/env python3
"""Catch the web copy drifting away from the cap it describes.

The cap is raised through the timelock every few months, and each raise has to
land in three places at once: config.js (which the page reads at runtime),
the hardcoded mentions in index.html, and the FAQ JSON-LD Google indexes.

Miss the JSON-LD and the rendered answer says one number while the structured
data says another — the mismatch Google penalises, and one nobody sees because
the page looks right. `data-cap` makes it worse, not better: it rewrites the
visible figure on load, so the page silently self-corrects while the JSON-LD
sitting beside it does not.

Run from the repo root; exits non-zero on any drift.
"""
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "web/config.js"
INDEX = ROOT / "web/index.html"

fail = []


def cap_label(n):
    """Mirror of capLabel() in app.js."""
    if n >= 1_000_000 and n % 1_000_000 == 0:
        return f"{n // 1_000_000}M"
    if n >= 1_000 and n % 1_000 == 0:
        return f"{n // 1_000}K"
    return f"{n:,}"


cfg = CONFIG.read_text()
m = re.search(r"stakeCapXP:\s*([0-9_]+)", cfg)
if not m:
    sys.exit("stakeCapXP not found in web/config.js")
cap = int(m.group(1).replace("_", ""))
label = cap_label(cap)

src = INDEX.read_text()

# The vault's opening cap is part of its history and is named as such. Every
# other figure on the page is a claim about the cap right now.
HISTORICAL = {"2M"}

# 1) every "<n>M XP" in the page must be the current cap ---------------------
# Tags are stripped first: the visible copy writes the figure as
# `<span data-cap>35M</span> XP`, which a regex over raw HTML walks straight
# past — and that span is exactly the one that rewrites itself at runtime.
flat = re.sub(r"<[^>]+>", "", src)
for mm in re.finditer(r"\b(\d+(?:\.\d+)?[MK])\s+XP\b", flat):
    found = mm.group(1)
    if found == label or found in HISTORICAL:
        continue
    ctx = re.sub(r"\s+", " ", flat[max(0, mm.start() - 80) : mm.end() + 40]).strip()
    fail.append(f"copy says {found} XP, cap is {label} XP\n      …{ctx}…")

# 2) the data-cap spans are rewritten on load, so their literal has to agree
#    with config or the served HTML contradicts the page a moment later
for mm in re.finditer(r"<span[^>]*\bdata-cap\b[^>]*>([^<]*)</span>", src):
    if mm.group(1).strip() != label:
        line = src[: mm.start()].count("\n") + 1
        fail.append(
            f"index.html:{line} data-cap span reads {mm.group(1).strip()!r}, "
            f"app.js will render {label!r}"
        )

# 3) FAQ JSON-LD must match the visible answers ------------------------------
block = re.search(r'<script type="application/ld\+json">\s*(.*?)\s*</script>', src, re.S)
graph = json.loads(block.group(1))["@graph"]
faq = next((x for x in graph if x.get("@type") == "FAQPage"), None)


def clean(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()


visible = {
    clean(q): clean(a)
    for q, a in re.findall(r"<summary[^>]*>(.*?)</summary>(.*?)</details>", src, re.S)
}
if faq:
    for e in faq["mainEntity"]:
        q, a = clean(e["name"]), clean(e["acceptedAnswer"]["text"])
        if q not in visible:
            fail.append(f'FAQ JSON-LD asks "{q[:60]}" — no such question on the page')
        elif visible[q] != a:
            fail.append(
                f'FAQ answer differs from its JSON-LD: "{q[:55]}"\n'
                f"      JSON-LD: {a[:90]}\n"
                f"      page   : {visible[q][:90]}"
            )

if fail:
    print("web copy is out of step with the cap:\n")
    for f in fail:
        print(f"  - {f}")
    sys.exit(1)
print(f"web copy consistent (cap {label} XP, {len(visible)} FAQ entries)")
