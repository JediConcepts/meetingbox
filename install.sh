#!/usr/bin/env bash
#
# meetingbox bootstrap. One line, then click through the prompts.
#
#   curl -fsSL https://raw.githubusercontent.com/JediConcepts/meetingbox/main/install.sh | bash
#
# Fetches meetingbox, puts it on your PATH, and hands over to `meetingbox setup`
# which checks what is missing and offers to install it.

set -euo pipefail

REPO="${MB_REPO:-JediConcepts/meetingbox}"
BRANCH="${MB_BRANCH:-main}"
BIN_DIR="${MB_BIN_DIR:-$HOME/.local/bin}"
SRC="https://raw.githubusercontent.com/$REPO/$BRANCH/meetingbox"

if [ -t 2 ]; then
  b=$'\033[1m'; d=$'\033[2m'; r=$'\033[0;31m'; g=$'\033[0;32m'; z=$'\033[0m'
else
  b=; d=; r=; g=; z=
fi
say() { printf '%s\n' "${b}meetingbox${z} $*" >&2; }
ok()  { printf '%s\n' "${g}         +${z} $*" >&2; }
die() { printf '%s\n' "${r}     error${z} $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "meetingbox is macOS only"

mkdir -p "$BIN_DIR"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Prefer the copy sitting next to this script. If you cloned the repo or
# downloaded both files, there is nothing to fetch.
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/meetingbox" ]; then
  say "using the local copy"
  cp "$here/meetingbox" "$tmp"
else
  say "fetching"
  curl -fsSL "$SRC" -o "$tmp" || die "could not download $SRC
             If you already have the meetingbox script, put it next to this
             install.sh and run it again."
fi

grep -q '^#!/usr/bin/env bash' "$tmp" || die "that file does not look like meetingbox"
install -m 755 "$tmp" "$BIN_DIR/meetingbox"
ok "meetingbox -> $BIN_DIR/meetingbox"

# Put it on PATH for this shell and for the next one.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    export PATH="$BIN_DIR:$PATH"
    for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
      [ "$rc" = "$HOME/.zshrc" ] || [ -e "$rc" ] || continue
      grep -qF '.local/bin' "$rc" 2>/dev/null \
        || printf '\n# meetingbox\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    done
    ok "added $BIN_DIR to your PATH"
    ;;
esac

# `curl | bash` leaves stdin consumed, so setup cannot read a yes/no answer.
# Reattach the terminal when there is one. `[ -r /dev/tty ]` is not a good enough
# test, since the node can be readable while opening it fails, so open it.
if [ -t 0 ]; then
  say "handing over to setup"
  exec "$BIN_DIR/meetingbox" setup
elif ( exec < /dev/tty ) 2>/dev/null; then
  say "handing over to setup"
  exec "$BIN_DIR/meetingbox" setup < /dev/tty
else
  say "installed. Now run:"
  printf '\n             %smeetingbox setup%s\n\n' "$b" "$z" >&2
fi
