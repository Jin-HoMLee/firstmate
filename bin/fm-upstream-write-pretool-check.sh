#!/usr/bin/env bash
# Stable cross-harness PreToolUse transport for the primary-session protected
# upstream write policy. The policy finds shell command positions; the guard
# script owns GitHub/git operation classification. This transport only extracts
# command text, scopes itself to a plain Firstmate checkout, and renders each
# harness's established deny shape.
#
# Usage:
#   <PreToolUse JSON> | fm-upstream-write-pretool-check.sh [--claude|--cursor]
#   fm-upstream-write-pretool-check.sh --command '<shell command>'
#
# Empty/malformed transport or an unavailable classifier fails open. A proved
# protected write exits 2 (except Cursor, whose deny object exits 0).
set -u

CMD='' CMD_SET=0 CLAUDE_MODE=0 CURSOR_MODE=0
usage() {
  cat >&2 <<'EOF'
usage: fm-upstream-write-pretool-check.sh [--command <cmd>] [--claude|--cursor]
EOF
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || usage; CMD=$2; CMD_SET=1; shift 2 ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    --cursor) CURSOR_MODE=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then exit 0; fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi
[ -n "$CMD" ] || exit 0

# Cheap strict-superset filter. Quoting is stripped before matching so ordinary
# quoted/escaped command words still reach the shared shell lexer.
PREFILTER=${CMD//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in *gh*|*git*push*) ;; *) exit 0 ;; esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] && [ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
POLICY=$FM_ROOT/bin/fm-upstream-write-command-policy.mjs
[ -f "$POLICY" ] || exit 0
OUT=$(node "$POLICY" --root "$FM_ROOT" --command "$CMD" 2>/dev/null) || exit 0
TAB=$(printf '\t')
[ "${OUT%%"$TAB"*}" = deny ] || exit 0
REST=${OUT#*"$TAB"}
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }
DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
