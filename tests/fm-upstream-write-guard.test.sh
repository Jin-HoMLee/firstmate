#!/usr/bin/env bash
# Regression coverage for the protected-upstream mutation guard. All forge
# executables are local stubs and all git repositories/remotes are local.
set -u

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-upstream-write-guard.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
POLICY="$ROOT/bin/fm-upstream-write-command-policy.mjs"
TMP_ROOT=$(fm_test_tmproot fm-upstream-write-guard)
STUBS="$TMP_ROOT/stubs"
SHIMS="$TMP_ROOT/shims"
LOG="$TMP_ROOT/forge.log"
mkdir -p "$STUBS"
: >"$LOG"

for tool in gh gh-axi; do
  cat >"$STUBS/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$FM_TEST_FORGE_LOG"
exit 0
SH
  chmod +x "$STUBS/$tool"
done

"$GUARD" install-shims "$SHIMS" || fail "guard shims should install"

run_guarded() {
  FM_TEST_FORGE_LOG="$LOG" PATH="$SHIMS:$STUBS:/usr/bin:/bin" "$@"
}

expect_refused() {
  local before status=0
  before=$(wc -l <"$LOG" | tr -d ' ')
  run_guarded "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || status=$?
  [ "$status" -eq 2 ] || fail "$* should be refused with exit 2, got $status"
  [ "$(wc -l <"$LOG" | tr -d ' ')" = "$before" ] || fail "$* reached the forge stub"
}

expect_allowed() {
  local before
  before=$(wc -l <"$LOG" | tr -d ' ')
  run_guarded "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || fail "$* should be allowed"
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq $((before + 1)) ] || fail "$* did not reach the forge stub"
}

expect_allowed gh-axi pr view 48 -R kunchenguid/dotfiles
expect_allowed gh pr view 48 --repo kunchenguid/dotfiles
expect_allowed gh-axi api GET /repos/kunchenguid/dotfiles/pulls/48
pass "read-only protected-upstream operations remain available"

expect_refused gh-axi pr create --title accidental
expect_refused gh pr create --title accidental
assert_contains "$(cat "$TMP_ROOT/err")" "must name its exact repository" \
  "omitted-repository refusal did not explain fork-aware default protection"
pass "both GitHub CLIs refuse the omitted-repository PR-create path"

expect_refused gh-axi pr create -R kunchenguid/dotfiles --title accidental
expect_refused gh pr close 48 --repo=kunchenguid/dotfiles
expect_refused gh-axi api PATCH /repos/kunchenguid/dotfiles/pulls/48 --field state=closed
expect_allowed gh-axi pr create -R Jin-HoMLee/dotfiles --title intended
expect_allowed gh pr create --repo Jin-HoMLee/dotfiles --title intended
pass "both GitHub CLIs block protected writes and allow an explicit personal fork"

repo="$TMP_ROOT/repo"
remote="$TMP_ROOT/remote.git"
fm_git_init_commit "$repo"
git init -q --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" remote add upstream git@github.com:kunchenguid/dotfiles.git
status=0
"$GUARD" check git -C "$repo" push upstream HEAD:refs/heads/test >"$TMP_ROOT/git.out" 2>"$TMP_ROOT/git.err" || status=$?
[ "$status" -eq 2 ] || fail "protected git push should be refused locally"
[ ! -e "$remote/refs/heads/test" ] || fail "protected push unexpectedly changed the local bare remote"
pass "git push destination classification blocks the protected remote without network access"

project_marker="$TMP_ROOT/project-pre-push.log"
cat >"$repo/.git/hooks/pre-push" <<SH
#!/usr/bin/env bash
printf 'ran\n' >>'$project_marker'
SH
chmod +x "$repo/.git/hooks/pre-push"
hooks="$TMP_ROOT/hooks"
"$STRIP" install "$hooks" "$repo" || fail "spawn git hooks should install"
status=0
(
  cd "$repo" || exit 1
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    "$hooks/pre-push" upstream git@github.com:kunchenguid/dotfiles.git </dev/null
) >"$TMP_ROOT/hook.out" 2>"$TMP_ROOT/hook.err" || status=$?
[ "$status" -eq 2 ] || fail "generated pre-push should refuse the protected URL"
[ ! -e "$project_marker" ] || fail "project hook ran after the protected destination was refused"
(
  cd "$repo" || exit 1
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    "$hooks/pre-push" origin "$remote" </dev/null
) || fail "generated pre-push should allow a local remote and chain the project hook"
[ -s "$project_marker" ] || fail "allowed push path did not chain the project pre-push hook"
pass "the spawn-owned pre-push guard runs before and preserves project hooks"

status=0
node "$POLICY" --root "$ROOT" --command \
  "gh-axi pr create --title accidental && git -C '$repo' push upstream HEAD:x" \
  >"$TMP_ROOT/policy.out" 2>"$TMP_ROOT/policy.err" || status=$?
[ "$status" -eq 0 ] || fail "primary policy CLI should report its decision on stdout"
assert_contains "$(cat "$TMP_ROOT/policy.out")" $'deny\tprotected-upstream-write\t' \
  "primary shell policy did not deny the dangerous GitHub command"
policy_read=$(node "$POLICY" --root "$ROOT" --command 'gh-axi pr view 48 -R kunchenguid/dotfiles')
[ "$policy_read" = allow ] || fail "primary shell policy blocked a read-only upstream operation: $policy_read"

primary="$TMP_ROOT/plain-primary"
mkdir -p "$primary/bin"
printf '# Firstmate\n' >"$primary/AGENTS.md"
git -C "$primary" init -q
for file in fm-upstream-write-pretool-check.sh fm-upstream-write-command-policy.mjs \
  fm-upstream-write-guard.sh fm-arm-command-policy.mjs fm-hook-host-lib.sh; do
  cp "$ROOT/bin/$file" "$primary/bin/$file"
done
chmod +x "$primary/bin/fm-upstream-write-pretool-check.sh" "$primary/bin/fm-upstream-write-guard.sh"
status=0
FM_ROOT_OVERRIDE="$primary" "$primary/bin/fm-upstream-write-pretool-check.sh" \
  --command 'gh pr create --repo kunchenguid/dotfiles --title accidental' \
  >"$TMP_ROOT/primary.out" 2>"$TMP_ROOT/primary.err" || status=$?
[ "$status" -eq 2 ] || fail "plain primary PreToolUse transport should deny the protected write, got $status"
assert_contains "$(cat "$TMP_ROOT/primary.err")" "protected-upstream-write" \
  "plain primary refusal omitted the stable guard code"
FM_ROOT_OVERRIDE="$primary" "$primary/bin/fm-upstream-write-pretool-check.sh" \
  --command 'gh pr view 48 --repo kunchenguid/dotfiles' \
  || fail "plain primary PreToolUse transport blocked a read"
pass "ordinary primary shell commands share the same write guard"

words="$TMP_ROOT/captain-words.txt"
printf '%s\n' 'Open exactly one test issue in kunchenguid/dotfiles.' >"$words"
AUTH_HOME="$TMP_ROOT/home"
mkdir -p "$AUTH_HOME/state"
: >"$LOG"
FM_HOME="$AUTH_HOME" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$words" -- \
  gh-axi issue create -R kunchenguid/dotfiles --title test \
  || fail "exact protected operation should run through the authorization interface"
assert_contains "$(cat "$LOG")" "issue create -R kunchenguid/dotfiles" \
  "authorized exact operation did not reach the forge stub"
record=$(find "$AUTH_HOME/state/upstream-write-authorizations" -name '*.record' -type f -print | head -n 1)
[ -n "$record" ] || fail "authorization did not create an audit record"
assert_contains "$(cat "$record")" "repo=kunchenguid/dotfiles" "audit record omitted the exact repo"
assert_contains "$(cat "$record")" "Open exactly one test issue" "audit record omitted the captain words"
status=0
FM_TASK_ID=worker FM_HOME="$AUTH_HOME" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$words" -- \
  gh-axi issue create -R kunchenguid/dotfiles --title worker \
  >"$TMP_ROOT/worker.out" 2>"$TMP_ROOT/worker.err" || status=$?
[ "$status" -eq 2 ] || fail "worker authorization should be refused"
assert_contains "$(cat "$TMP_ROOT/worker.err")" "workers cannot authorize" \
  "worker refusal did not name the authority boundary"
pass "the only override is exact, audited, and unavailable to workers"

echo "# all fm-upstream-write-guard tests passed"
