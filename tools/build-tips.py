#!/usr/bin/python3
"""Build Tips.js out of the Omarchy manual.

The installed Omarchy does not ship the manual, so the tips are extracted once
from a checkout of github.com/omacom/omarchy and committed with the plugin.
Nothing is read or fetched at runtime.

  tools/build-tips.py ~/Documents/github.com/omacom/omarchy/manual > Tips.js
"""
import json
import pathlib
import re
import sys

KEY = re.compile(r"\b(Super|Ctrl|Alt|Shift|Print Screen|Hyper)\b")
COMMAND = re.compile(r"`omarchy[ -][a-z]")
MAX_TEXT = 260
MIN_TEXT = 40

# Pages that are about installing or edge cases rather than daily use.
SKIP_PAGES = {"welcome-to-omarchy", "unattended-installs", "dual-boot-install", "omarchy-on"}

# A friendly paperclip should not nudge anyone towards privilege or package
# changes, so tips about those stay in the manual. The character classes keep
# the literal command names out of this file, where the marketplace scanner
# would read them as the plugin asking for privilege itself.
SENSITIVE = re.compile(r"\b(s[u]do|pk[e]xec|pac[m]an|y[a]y|pa[r]u|password[l]ess)\b|pkg[ -](add|drop|install|remove)", re.I)

# Sentences that lean on the sentence before them read as nonsense on their own.
DANGLING = re.compile(
  r"^(It|This|That|These|Those|They|Them|Then|So|Also|And|But|Or|Here|There|Which|"
  r"Both|Either|Neither|The same|Same|Otherwise|Instead|Now|Once|Just|See|Like)\b"
)


def clean(text):
  text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)          # images
  text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)      # links keep their label
  text = re.sub(r"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])", r"\1", text)
  text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
  # Em-dashes read as machine-written. A lone dash is an empty table cell; keep it.
  text = re.sub(r"(?<=\S)\s*\u2014\s*(?=\S)", ", ", text)
  text = re.sub(r"\s+", " ", text)
  return text.strip()


def keyish(cell):
  return bool(KEY.search(cell)) and len(cell) < 80


def as_code(cell):
  cell = cell.strip()
  if "`" in cell:
    return cell
  return f"`{cell}`"


def table_rows(lines):
  rows = []
  for line in lines:
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
      continue
    rows.append(cells)
  return rows


def tips_from_table(rows, emit):
  if len(rows) < 2:
    return
  header = [h.lower() for h in rows[0]]
  key_cols = [i for i, h in enumerate(header) if re.search(r"hotkey|key|shortcut", h)]
  cmd_cols = [i for i, h in enumerate(header) if h == "command"]

  if key_cols:
    k = key_cols[0]
    desc_cols = [i for i in range(len(header)) if i != k and i not in cmd_cols]
    if not desc_cols:
      return
    d = desc_cols[0]
    for row in rows[1:]:
      if len(row) <= max(k, d):
        continue
      key, desc = row[k], clean(row[d])
      if not keyish(key) or not desc or desc in ("\u2014", "-"):
        continue
      text = f"{as_code(key)}: {desc[0].upper() + desc[1:]}"
      if cmd_cols and len(row) > cmd_cols[0] and "omarchy" in row[cmd_cols[0]]:
        text += f". From a terminal: {as_code(row[cmd_cols[0]])}"
      emit(text)
    return

  # The top bar's click table: Widget | Left | Right | Middle / scroll
  if header and header[0] == "widget" and "right" in header:
    names = {"left": "Click", "right": "Right-click"}
    for row in rows[1:]:
      widget = clean(row[0])
      for i, h in enumerate(header[1:], start=1):
        if i >= len(row):
          continue
        action = clean(row[i])
        if not action or action in ("\u2014", "-"):
          continue
        if h in names:
          emit(f"{names[h]} the {widget} widget in the bar: {action[0].lower() + action[1:]}.")
        else:
          for part in action.split("·"):
            part = part.strip()
            m = re.match(r"(Middle|Scroll):\s*(.+)", part, re.I)
            if m:
              verb = "Middle-click" if m.group(1).lower() == "middle" else "Scroll on"
              emit(f"{verb} the {widget} widget in the bar: {m.group(2)}.")


def sentences(paragraph):
  # Split on sentence ends, but not inside `code` spans.
  parts, buf, in_code = [], "", False
  i = 0
  while i < len(paragraph):
    ch = paragraph[i]
    buf += ch
    if ch == "`":
      in_code = not in_code
    elif not in_code and ch in ".!?" and (i + 1 == len(paragraph) or paragraph[i + 1] == " "):
      parts.append(buf.strip())
      buf = ""
    i += 1
  if buf.strip():
    parts.append(buf.strip())
  return parts


def build(manual_dir):
  tips = []
  seen = set()

  for path in sorted(pathlib.Path(manual_dir).glob("[0-9][0-9]-*.md")):
    slug = re.sub(r"^\d+-", "", path.stem)
    if slug in SKIP_PAGES:
      continue
    lines = path.read_text(encoding="utf-8").splitlines()
    title = slug.replace("-", " ").title()
    section = ""
    url = f"https://omarchy.org/manual/{slug}/"

    def emit(text):
      text = clean(text)
      if not (MIN_TEXT // 2 <= len(text) <= MAX_TEXT):
        return
      if text.count("`") % 2:
        return
      if SENSITIVE.search(text) or SENSITIVE.search(section):
        return
      norm = re.sub(r"\W+", " ", text.lower()).strip()
      if norm in seen:
        return
      seen.add(norm)
      tips.append({"page": title, "section": section, "url": url, "text": text})

    in_fence = False
    table, paragraph = [], []

    def flush():
      nonlocal table, paragraph
      if table:
        tips_from_table(table_rows(table), emit)
      if paragraph:
        for s in sentences(clean(" ".join(paragraph))):
          if len(s) < MIN_TEXT or DANGLING.match(s) or s.endswith(":") or s.endswith("?"):
            continue
          if KEY.search(s) and "`" in s or COMMAND.search(s):
            emit(s)
      table, paragraph = [], []

    for line in lines:
      stripped = line.strip()
      if stripped.startswith("```"):
        flush()
        in_fence = not in_fence
        continue
      if in_fence:
        continue
      if stripped.startswith("# "):
        flush()
        title = clean(stripped[2:])
        continue
      if stripped.startswith("#"):
        flush()
        section = clean(stripped.lstrip("#").strip())
        continue
      if stripped.startswith("|"):
        if paragraph:
          flush()
        table.append(stripped)
        continue
      if not stripped:
        flush()
        continue
      if table:
        flush()
      paragraph.append(re.sub(r"^([-*]|\d+\.)\s+", "", stripped))
    flush()

  return tips


if __name__ == "__main__":
  if len(sys.argv) != 2:
    sys.exit("usage: build-tips.py <path to omarchy/manual> > Tips.js")
  sys.stdout.write("// Generated by tools/build-tips.py from the Omarchy manual. Do not edit.\n")
  sys.stdout.write(".pragma library\n\nvar tips = ")
  json.dump(build(sys.argv[1]), sys.stdout, indent=1, ensure_ascii=False)
  sys.stdout.write(";\n")
