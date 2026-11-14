# Shared test setup. A test file is:
#   #!/bin/bash
#   . "$(dirname "$0")/lib.sh"
#   ...checks...
#   finish
# Never touches the real HOME: everything runs in a scratch folder with stubs.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"
HOME="$(mktemp -d)" || exit 1
# never the real HOME, and never empty: every test path is built from it
[ -n "$HOME" ] && [ "$HOME" != "$REAL_HOME" ] || exit 1
export HOME
: > "$HOME/calls.log"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; }
finish() {
  printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
  exit $?
}

# A user's own MB_* settings must never point a test at real folders.
# MB_TEST_BIN is the exception: it names the folder tests/run.sh built mb-transcript into,
# and holds no user setting.
for v in $(compgen -e | grep '^MB_' | grep -v '^MB_TEST_BIN$'); do unset "$v"; done

# Everything from the main marker onwards is left out, so only functions load.
# shellcheck disable=SC1090
sed '/^# -* main$/,$d' "$ROOT/meetingbox" > "$HOME/meetingbox.functions"
. "$HOME/meetingbox.functions"
set +e   # the script sets -e; a failing check must not end the test file
# After the script's own settings, which would otherwise put the real one back: a test never
# registers its scratch bundles with LaunchServices.
LSREGISTER=/usr/bin/true

tccutil()  { echo "tccutil $*" >> "$HOME/calls.log"; return 0; }
confirm()  { echo "confirm $*" >> "$HOME/calls.log"; return 0; }
codesign() { echo "codesign $*" >> "$HOME/calls.log"; return 0; }
security() { echo "security $*" >> "$HOME/calls.log"; return 0; }
openssl()  { echo "openssl $*" >> "$HOME/calls.log"; return 0; }
# The app's preferences live with the real user, whatever HOME says: never read them. Unset
# unless a test says otherwise.
defaults() { echo "defaults $*" >> "$HOME/calls.log"; return 1; }
# Nothing reaches the network, builds for real or decodes audio unless a suite replaces these.
curl()      { echo "curl $*" >> "$HOME/calls.log"; return 7; }
swift()     { echo "swift $*" >> "$HOME/calls.log"; return 1; }
afconvert() { echo "afconvert $*" >> "$HOME/calls.log"; : > "${!#}"; }
# Parakeet counts as set up, so a setup() test sees no Parakeet step unless its suite says otherwise.
speech_ready() { return 0; }
# Node is never run by name: the engine runs the recorded one with env -i and its absolute path, which
# this stub cannot see, so a suite that may reach outside minutes also calls fake_node.
node() { echo "node $*" >> "$HOME/calls.log"; return 1; }
# Outside models count as set up, and their setup step does nothing, so a setup() test never finds a
# real Node, runs npm or offers Homebrew unless its suite says otherwise (test_writer.sh does).
minutes_ready()   { return 0; }
install_minutes() { echo "install_minutes" >> "$HOME/calls.log"; return 0; }

# A fake Node in the scratch home, recorded in NODE_FILE as setup records the real one, beside a
# placeholder MINUTES_DIR/writer.mjs. It runs with an empty environment, so every path in it is
# absolute. Each call appends "argv: ..." and "env: ..." lines to $HOME/node.log; "Never calls Node"
# means that file does not exist. What it reads on stdin goes to $HOME/node.stdin.<command>. It answers:
#   --version             $HOME/node-version, else v22.22.2
#   <writer.mjs> version  {"router": "1.1.1"}, or $HOME/node-router-version's text
#   <writer.mjs> list     $HOME/node-list, else {"models": []}
#   <writer.mjs> complete $HOME/node-reply, else minutes in Markdown
# with the status in $HOME/node-status (default 0). $HOME/node-sleep makes complete sleep that many
# seconds first (exec, so a TERM reaches the sleep), and $HOME/node-stderr-stdin makes it copy its
# stdin to stderr, the key included.
fake_node() {
  local f="$HOME/fake-node/node"
  mkdir -p "$HOME/fake-node" "$STATE_DIR" "$MINUTES_DIR"
  cat > "$f" <<EOF
#!/bin/bash
h="$HOME"
{ printf 'argv:'; printf ' %s' "\$@"; printf '\n'; printf 'env:'; /usr/bin/env | /usr/bin/tr '\n' ' '; printf '\n'; } >> "\$h/node.log"
case "\$1" in --version) /bin/cat "\$h/node-version" 2>/dev/null || echo v22.22.2; exit 0 ;; esac
cmd="\${2:-}"
case "\$cmd" in list|complete) /bin/cat > "\$h/node.stdin.\$cmd" ;; esac
[ ! -e "\$h/node-stderr-stdin" ] || /bin/cat "\$h/node.stdin.\$cmd" >&2
case "\$cmd" in
  version) if [ -e "\$h/node-router-version" ]; then /bin/cat "\$h/node-router-version"; else echo '{"router": "1.1.1"}'; fi ;;
  list) if [ -e "\$h/node-list" ]; then /bin/cat "\$h/node-list"; else echo '{"models": []}'; fi ;;
  complete)
    [ ! -e "\$h/node-sleep" ] || exec /bin/sleep "\$(/bin/cat "\$h/node-sleep")"
    if [ -e "\$h/node-reply" ]; then /bin/cat "\$h/node-reply"
    else printf '%s\n' '{"text": "## Summary\\nThe plan was agreed.\\n\\n## Decisions\\nNone\\n", "finishReason": "stop", "inputTokens": 0, "tokenSource": "unreported"}'; fi ;;
esac
exit "\$(/bin/cat "\$h/node-status" 2>/dev/null || echo 0)"
EOF
  chmod 755 "$f"
  printf '%s\n' "$f" > "$NODE_FILE"
  record_install "$NODE_FILE"
  [ -e "$MINUTES_DIR/writer.mjs" ] || : > "$MINUTES_DIR/writer.mjs"
}
