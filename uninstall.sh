#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

dry_run="${POLISPEC_DRY_RUN:-0}"
keep="${POLISPEC_KEEP:-}"

if [ -n "${POLISPEC_DATA_HOME:-}" ]; then
  data="$POLISPEC_DATA_HOME"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  data="$XDG_DATA_HOME/polispec"
else
  data="$HOME/.local/share/polispec"
fi

bin=""
if [ -n "${POLISPEC_BIN:-}" ] && [ -x "$POLISPEC_BIN" ]; then
  bin="$POLISPEC_BIN"
elif command -v polispec >/dev/null 2>&1; then
  bin="$(command -v polispec)"
elif [ -x "$HOME/.local/bin/polispec" ]; then
  bin="$HOME/.local/bin/polispec"
elif [ -x "$data/current/bin/polispec" ]; then
  bin="$data/current/bin/polispec"
elif [ -x "${RPLUGINS_HOME:-$HOME/.rplugins}/polispec/bin/polispec" ]; then
  bin="${RPLUGINS_HOME:-$HOME/.rplugins}/polispec/bin/polispec"
fi
if [ -z "$bin" ]; then
  echo "polispec uninstall: polispec is not installed here (looked at POLISPEC_BIN, PATH, ~/.local/bin, $data/current, the rplugin store)" >&2
  exit 1
fi

if [ -n "$keep" ]; then
  "$bin" uninstall --all --dry-run --keep "$keep"
else
  "$bin" uninstall --all --dry-run
fi

if [ "$dry_run" = "1" ]; then
  echo
  echo "dry run only: nothing was changed"
  exit 0
fi

echo
echo "The real uninstall asks you to type a phrase on this terminal."
if [ -n "$keep" ]; then
  exec "$bin" uninstall --all --keep "$keep" </dev/tty
fi
exec "$bin" uninstall --all </dev/tty
