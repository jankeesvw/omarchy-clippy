#!/usr/bin/env bash
#
# Clippy installer for the Omarchy shell.
#
# Run it from a clone of the repo:  ./install.sh
#
# What it does:
#   1. Registers the plugin (omarchy plugin add, never a file copy, or
#      `omarchy plugin update` could never fast-forward it later).
#   2. Enables it, which for a service means one entry in shell.json's
#      plugins[] and nothing in the bar.
#   3. Drops a launcher entry, since a shell plugin is not an app and
#      nothing else would put it in the launcher.
#
# There is nothing else to install: Clippy is drawn in QML and needs nothing
# beyond what Omarchy already has, so `omarchy plugin add` on its own works
# fine too. You only miss the launcher entry.
#
# Overrides:
#   CLIPPY_REPO=user/repo    register from a different repo
set -euo pipefail

REPO="${CLIPPY_REPO:-jankeesvw/omarchy-clippy}"
PLUGIN_ID="jankeesvw.clippy"

say() { printf '%s\n' "$*"; }

if ! command -v omarchy >/dev/null 2>&1; then
  say "This needs Omarchy 4 (the omarchy CLI is not on PATH)."
  exit 1
fi

# Already installed? Then this is an update, not an install.
if omarchy plugin list 2>/dev/null | grep -q "^${PLUGIN_ID}[[:space:]]"; then
  say "==> ${PLUGIN_ID} is already installed; updating"
  omarchy plugin update "$PLUGIN_ID"
else
  say "==> Registering ${PLUGIN_ID} from ${REPO}"
  # --yes only when there is no terminal to prompt on: with a TTY the user
  # gets the prompt a bare `plugin add` would give them.
  if [ -t 0 ] && [ -t 1 ]; then
    omarchy plugin add "https://github.com/${REPO}"
  else
    omarchy plugin add "https://github.com/${REPO}" --yes
  fi
fi

say "==> Enabling"
omarchy plugin enable "$PLUGIN_ID" || true

# A shell plugin is not an app, so nothing puts it in the launcher. This does:
# a desktop entry whose Exec is the toggle a keybinding would run. It is
# written to a temporary file next to it and renamed into place, so a symlink
# planted on the name is replaced instead of written through.
PLUGIN_DIR="$HOME/.config/omarchy/plugins/${PLUGIN_ID}"
APPS_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$APPS_DIR/clippy.desktop"
say "==> Adding the launcher entry"
mkdir -p "$APPS_DIR"
tmp=$(mktemp "$APPS_DIR/.clippy.desktop.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Clippy
Comment=Show or hide the paperclip with tips from the Omarchy manual
Exec=omarchy-shell jankeesvw.clippy toggle
Icon=${PLUGIN_DIR}/icon.png
Terminal=false
Categories=Utility;
StartupNotify=false
DESKTOP
chmod 644 "$tmp"
mv -f "$tmp" "$DESKTOP_FILE"
trap - EXIT
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

say ""
say "Done. Search for Clippy in the launcher, or bind a key to:"
say "  omarchy-shell jankeesvw.clippy toggle"
