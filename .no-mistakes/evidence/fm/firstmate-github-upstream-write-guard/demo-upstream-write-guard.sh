#!/usr/bin/env bash
# End-to-end demonstration of the protected-upstream write guard as a worker
# would experience it. All gh/gh-axi invocations resolve through the installed
# PATH shims to the guard; a stub records only commands the guard actually lets
# through, proving refusals never reach the forge.
set -u

ROOT=/Users/jin-holee/.no-mistakes/worktrees/6810fa9ca453/01M5BGB8RK8GVJP31M37NQX3YN
GUARD="$ROOT/bin/fm-upstream-write-guard.sh"
POLICY="$ROOT/bin/fm-upstream-write-command-policy.mjs"
TMP=$(cd "$(mktemp -d)" && pwd -P)   # physical path so the shim's own skip check matches
STUBS="$TMP/stubs"
SHIMS="$TMP/shims"
LOG="$TMP/forge.log"
: >"$LOG"

mkdir -p "$STUBS"
for tool in gh gh-axi; do
  cat >"$STUBS/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$FM_TEST_FORGE_LOG"
exit 0
SH
  chmod +x "$STUBS/$tool"
done

"$GUARD" install-shims "$SHIMS" >/dev/null || exit 1

run() { FM_TEST_FORGE_LOG="$LOG" PATH="$SHIMS:$STUBS:/usr/bin:/bin" "$@"; }

echo '=============================================================='
echo '1. Worker tries to open a PR against the protected upstream'
echo '=============================================================='
run gh pr create -R kunchenguid/dotfiles --title accidental
echo "[exit=$?]"

echo
echo '2. Worker tries the fork-aware default (no -R) PR create'
echo '--------------------------------------------------------------'
run gh pr create --title accidental
echo "[exit=$?]"

echo
echo '3. Read-only upstream operations remain available'
echo '--------------------------------------------------------------'
run gh pr view 48 -R kunchenguid/dotfiles
echo "[exit=$?]"

echo
echo '4. An explicit personal fork remains allowed'
echo '--------------------------------------------------------------'
run gh pr create -R Jin-HoMLee/dotfiles --title intended
echo "[exit=$?]"

echo
echo '5. Decoy -R graphql mutation is refused (query-body target)'
echo '--------------------------------------------------------------'
run gh api graphql -R someuser/somerepo -f 'query=mutation { createRepository(input:{name:"x", ownerId:"id"}) }'
echo "[exit=$?]"

echo
echo '6. gh repo unarchive mirrors archive'
echo '--------------------------------------------------------------'
run gh repo unarchive kunchenguid/dotfiles
echo "[exit=$?]"
run gh repo unarchive someuser/somerepo
echo "[exit=$?]"

echo
echo '7. Only allowed commands reached the forge stub'
echo '--------------------------------------------------------------'
cat "$LOG"

echo
echo '=============================================================='
echo '8. Primary PreToolUse policy output (the exact PR-create intent)'
echo '=============================================================='
node "$POLICY" --root "$ROOT" --command 'gh pr create -R kunchenguid/dotfiles --title accidental'
echo
node "$POLICY" --root "$ROOT" --command 'gh pr view 48 -R kunchenguid/dotfiles'
echo

echo
echo '=============================================================='
echo '9. The only override: exact captain words + exact repo'
echo '=============================================================='
WORDS="$TMP/captain-words.txt"
printf '%s\n' 'Open exactly one PR in kunchenguid/dotfiles titled upstream-sync.' >"$WORDS"
AUTH_HOME="$TMP/home"
mkdir -p "$AUTH_HOME/state"

echo '--- worker tries to authorize (must be refused) ---'
FM_TASK_ID=worker FM_HOME="$AUTH_HOME" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$WORDS" -- \
  gh-axi pr create -R kunchenguid/dotfiles --title upstream-sync
echo "[exit=$?]"

echo '--- firstmate (no FM_TASK_ID) authorizes the exact operation ---'
FM_HOME="$AUTH_HOME" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$WORDS" -- \
  gh-axi pr create -R kunchenguid/dotfiles --title upstream-sync
echo "[exit=$?]"

echo '--- audit record ---'
find "$AUTH_HOME/state/upstream-write-authorizations" -name '*.record' -type f -print -exec cat {} \;

chmod -R u+w "$TMP/shims" "$TMP" 2>/dev/null || true
rm -rf "$TMP"
