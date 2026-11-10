"""Prints the CHANGELOG.md section of a version as simple HTML, for Sparkle's update window.

Usage: python3 scripts/changelog-html.py 1.0.4-beta
Handles what the changelog uses: ### headings, - bullets, **bold**, *italics*, `code`, [links](url).
The never-released sections that follow it (e.g. 1.1.0, included in 1.2.0) are included.
"""
import html
import re
import sys

tag = sys.argv[1]
text = open("CHANGELOG.md", encoding="utf-8").read()
END = r"(?=^## \[|^\[[^\]]+\]: |\Z)"
match = re.search(rf"^## \[{re.escape(tag)}\][^\n]*\n(.*?){END}", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {tag}")
# The sections right after it that were never released on their own ("## [1.1.0] — never
# released, included in 1.2.0") are part of this version: shown after its own, under their title.
sections = [("", match.group(1))]
NEXT = re.compile(rf"^## \[([^\]]+)\]([^\n]*never released[^\n]*)\n(.*?){END}", re.S | re.M)
pos = match.end()
while (more := NEXT.match(text, pos)):
    sections.append((more.group(1) + more.group(2).rstrip(), more.group(3)))
    pos = more.end()


def inline(line):
    line = html.escape(line, quote=False)
    line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
    line = re.sub(r"\*(.+?)\*", r"<i>\1</i>", line)
    line = re.sub(r"`(.+?)`", r"<code>\1</code>", line)
    line = re.sub(r"\[(.+?)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', line)
    return line


out, in_list = [], False
lines = []
for title, body in sections:
    if title:
        lines.append("## " + title)
    lines += body.strip().splitlines()
for raw in lines:
    line = raw.strip()
    if line.startswith("- "):
        if not in_list:
            out.append("<ul>")
            in_list = True
        out.append(f"<li>{inline(line[2:])}</li>")
        continue
    if in_list:
        out.append("</ul>")
        in_list = False
    if line.startswith("## "):
        out.append(f"<h2>{inline(line[3:])}</h2>")
    elif line.startswith("### "):
        out.append(f"<h3>{inline(line[4:])}</h3>")
    elif line:
        out.append(f"<p>{inline(line)}</p>")
if in_list:
    out.append("</ul>")
print("\n".join(out).replace("]]>", "]]&gt;"))  # it goes in a CDATA section
