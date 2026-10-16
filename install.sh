#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_url="${POLISPEC_SOURCE:-https://github.com/SteveBenner/polispec.git}"
dry_run="${POLISPEC_DRY_RUN:-0}"

if [ -n "${POLISPEC_DATA_HOME:-}" ]; then
  data="$POLISPEC_DATA_HOME"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  data="$XDG_DATA_HOME/polispec"
else
  data="$HOME/.local/share/polispec"
fi

missing=""
command -v git >/dev/null 2>&1 || missing="$missing git"
command -v ruby >/dev/null 2>&1 || missing="$missing ruby"
if [ -n "$missing" ]; then
  echo "polispec install: missing:$missing" >&2
  exit 1
fi
if ! ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.6") ? 0 : 1)'; then
  echo "polispec install: ruby 2.6 or newer is required" >&2
  exit 1
fi

ref="${POLISPEC_REF:-}"
if [ -z "$ref" ]; then
  ref="$(git ls-remote --tags --refs "$source_url" \
    | sed -n 's|.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n 1)"
  if [ -z "$ref" ]; then
    echo "polispec install: no vX.Y.Z tag found at $source_url" >&2
    exit 1
  fi
  ref="v$ref"
fi

harness="${POLISPEC_HARNESS:-auto}"
if [ "$harness" = "auto" ]; then
  harness=""
  if command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; then
    harness="claude"
  fi
  if command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then
    harness="${harness:+$harness,}codex"
  fi
elif [ "$harness" = "none" ]; then
  harness=""
fi

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$source_url" "$tmp/src"

if [ "$dry_run" = "1" ]; then
  ruby "$tmp/src/bin/polispec" pin --source "$source_url" --ref "$ref" --dry-run
  polispec_bin="$tmp/src/bin/polispec"
  extra="--dry-run"
else
  ruby "$tmp/src/bin/polispec" pin --source "$source_url" --ref "$ref"
  polispec_bin="$data/current/bin/polispec"
  extra=""
fi

wired=""
old_ifs="$IFS"
IFS=","
for h in $harness; do
  IFS="$old_ifs"
  # shellcheck disable=SC2086
  "$polispec_bin" install --harness "$h" $extra
  wired="${wired:+$wired, }$h"
  IFS=","
done
IFS="$old_ifs"

echo
echo "pinned path: $data/current"
echo "hooks wired for: ${wired:-none}"
echo "ledger: run polispec doctor to see it; add a project with polispec apply environment-control --repo <repo>"
echo "polispec starts in advise mode: it logs verdicts and blocks nothing. Turn enforcement on with: polispec settings set polispec.enforce enforce"
case ":${PATH:-}:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Add polispec to your PATH: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo "Next: polispec doctor"
