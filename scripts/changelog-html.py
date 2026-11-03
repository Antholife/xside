"""Prints the CHANGELOG.md section of a version as simple HTML, for Sparkle's update window.

Usage: python3 scripts/changelog-html.py 1.0.4-beta
Handles what the changelog uses: ### headings, - bullets, **bold**, *italics*, `code`, [links](url).
"""
import html
import re
import sys

tag = sys.argv[1]
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(rf"^## \[{re.escape(tag)}\][^\n]*\n(.*?)(?=^## \[|^\[[^\]]+\]: )", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {tag}")


def inline(line):
    line = html.escape(line, quote=False)
    line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
    line = re.sub(r"\*(.+?)\*", r"<i>\1</i>", line)
    line = re.sub(r"`(.+?)`", r"<code>\1</code>", line)
    line = re.sub(r"\[(.+?)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', line)
    return line


out, in_list = [], False
for raw in match.group(1).strip().splitlines():
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
    if line.startswith("### "):
        out.append(f"<h3>{inline(line[4:])}</h3>")
    elif line:
        out.append(f"<p>{inline(line)}</p>")
if in_list:
    out.append("</ul>")
print("\n".join(out).replace("]]>", "]]&gt;"))  # it goes in a CDATA section
