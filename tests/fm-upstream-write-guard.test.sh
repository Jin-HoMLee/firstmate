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

expect_allowed gh api -X POST /user
expect_allowed gh api -X PUT /user
expect_allowed gh api -X POST /gists
pass "non-repository gh api mutations remain available"

expect_refused gh api 'repos/{owner}/{repo}/issues' -f title=x
expect_allowed gh api 'repos/{owner}/{repo}/issues'
expect_refused gh api repos/kunchenguid/dotfiles/issues -f title=x
expect_allowed gh api repos/kunchenguid/dotfiles/issues
pass "gh api repo-path mutations refuse when {owner}/{repo} placeholders hide the target"

expect_refused gh api -X POST /orgs/kunchenguid/repos -f name=newrepo
expect_refused gh api -X POST orgs/kunchenguid/repos -f name=newrepo
expect_refused gh api -X POST https://api.github.com/orgs/kunchenguid/repos -f name=newrepo
expect_refused gh api -X POST http://api.github.com/orgs/kunchenguid/repos -f name=newrepo
expect_refused gh api -X POST /orgs/kunchenguid/repos/ -f name=newrepo
expect_refused gh api -X POST orgs/kunchenguid/repos/ -f name=newrepo
expect_refused gh api -X POST 'https://api.github.com/orgs/kunchenguid/repos?foo=bar' -f name=newrepo
expect_refused gh api -X POST '/orgs/kunchenguid/repos?foo=bar' -f name=newrepo
expect_refused gh api -X POST 'orgs/kunchenguid/repos?foo=bar' -f name=newrepo
expect_allowed gh api /orgs/kunchenguid/repos
expect_allowed gh api -X POST /user/repos -f name=myrepo
pass "gh api org-level repository creation into kunchenguid is blocked"

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

expect_refused gh secret set -v private NAME -R kunchenguid/dotfiles
expect_refused gh variable set -v selected NAME -R kunchenguid/dotfiles
expect_allowed gh secret set -v private NAME -R Jin-HoMLee/dotfiles
expect_allowed gh variable set -v selected NAME -R Jin-HoMLee/dotfiles
pass "gh secret/variable set parse -v as --visibility, not a help/version early-return"

expect_allowed gh repo create myrepo
expect_allowed gh repo create myorg/myrepo
expect_refused gh repo create kunchenguid/newrepo
expect_refused gh repo create KUNCHENGUID/newrepo
expect_allowed gh repo create myrepo --source kunchenguid/dotfiles
expect_allowed gh repo create myrepo --template kunchenguid/dotfiles
expect_allowed gh repo create myrepo --source=kunchenguid/dotfiles
expect_allowed gh repo create myrepo -s kunchenguid/dotfiles
expect_allowed gh repo create myorg/myrepo --source kunchenguid/dotfiles
expect_refused gh repo create kunchenguid/newrepo --source Jin-HoMLee/dotfiles
pass "gh repo create keeps protected --source/--template inputs distinct from its destination"

expect_refused gh repo create kunchenguid/newrepo -h https://example.com
expect_refused gh repo create -h https://example.com kunchenguid/newrepo
expect_refused gh repo edit kunchenguid/dotfiles -h https://example.com
expect_allowed gh repo create myrepo -h https://example.com
expect_allowed gh repo create --help
expect_allowed gh repo edit --help
pass "gh repo create/edit parse -h as --homepage, not help, while --help stays allowed"

expect_refused gh repo edit -h https://github.com/someuser/somerepo kunchenguid/dotfiles
expect_refused gh repo edit --homepage https://github.com/someuser/somerepo kunchenguid/dotfiles
expect_refused gh repo edit --default-branch feature/x kunchenguid/dotfiles
expect_refused gh repo edit -h https://github.com/someuser/somerepo
expect_allowed gh repo create myrepo --source https://github.com/kunchenguid/dotfiles
expect_allowed gh repo create myrepo --template https://github.com/kunchenguid/dotfiles
pass "gh repo edit skips homepage/branch flag values when locating its destination"

expect_allowed gh repo edit --template myorg/myrepo
expect_allowed gh repo edit myorg/myrepo --template
expect_refused gh repo edit --template kunchenguid/dotfiles
pass "gh repo edit treats --template as a boolean, not a destination value"

expect_allowed gh repo fork kunchenguid/dotfiles
expect_allowed gh repo fork Jin-HoMLee/dotfiles
expect_refused gh repo fork kunchenguid/dotfiles --org kunchenguid --fork-name newname
expect_refused gh repo fork someuser/somerepo --org kunchenguid
expect_refused gh repo fork someuser/somerepo --org=kunchenguid
expect_refused gh repo fork someuser/somerepo --org otherorg --org kunchenguid
expect_refused gh repo fork someuser/somerepo --org kunchenguid --org otherorg
expect_refused gh repo fork someuser/somerepo --org=otherorg --org=kunchenguid
expect_allowed gh repo fork kunchenguid/dotfiles --org otherorg
pass "gh repo fork allows protected-source reads but refuses a protected-org destination"

expect_allowed gh repo read-dir kunchenguid/dotfiles
expect_allowed gh repo read-file kunchenguid/dotfiles --path README.md
expect_allowed gh repo gitignore list
expect_allowed gh repo license list
expect_allowed gh repo deploy-key list -R kunchenguid/dotfiles
expect_allowed gh repo autolink list -R kunchenguid/dotfiles
expect_allowed gh repo deploy-key -R kunchenguid/dotfiles list
expect_allowed gh repo autolink -R kunchenguid/dotfiles list
expect_allowed gh repo autolink -R kunchenguid/dotfiles view
expect_allowed gh repo set-default kunchenguid/dotfiles
expect_refused gh repo deploy-key add -R kunchenguid/dotfiles key
expect_refused gh repo autolink create -R kunchenguid/dotfiles --key-prefix x --url-template y
pass "gh repo read-only subcommands stay available while deploy-key/autolink writes are blocked"

for agent_alias in agent-task agent-tasks agent agents; do
  expect_refused gh "$agent_alias" create -R kunchenguid/dotfiles x
  expect_allowed gh "$agent_alias" create -R Jin-HoMLee/dotfiles x
  expect_allowed gh "$agent_alias" list -R kunchenguid/dotfiles
done
pass "gh agent-task create is blocked at protected upstreams across every alias"

expect_refused gh issue transfer 123 kunchenguid/dotfiles -R myorg/myrepo
expect_refused gh issue transfer 123 myorg/myrepo -R kunchenguid/dotfiles
expect_allowed gh issue transfer 123 myorg/myrepo -R otherorg/otherrepo
pass "gh issue transfer blocks a protected destination and protected source"

policy_repo_own=$(node "$POLICY" --root "$ROOT" --command 'gh repo create myrepo')
[ "$policy_repo_own" = allow ] || fail "primary shell policy blocked own-account repo creation: $policy_repo_own"
policy_repo_protected=$(node "$POLICY" --root "$ROOT" --command 'gh repo create kunchenguid/newrepo')
case "$policy_repo_protected" in
  deny*) ;;
  *) fail "primary shell policy allowed a protected repo creation: $policy_repo_protected" ;;
esac
policy_create_source=$(node "$POLICY" --root "$ROOT" --command 'gh repo create myrepo --source kunchenguid/dotfiles')
[ "$policy_create_source" = allow ] || fail "primary shell policy blocked own-account creation from a protected source: $policy_create_source"
policy_fork=$(node "$POLICY" --root "$ROOT" --command 'gh repo fork kunchenguid/dotfiles')
[ "$policy_fork" = allow ] || fail "primary shell policy blocked a protected-source fork: $policy_fork"
policy_repo_edit_homepage=$(node "$POLICY" --root "$ROOT" --command 'gh repo edit -h https://github.com/someuser/somerepo kunchenguid/dotfiles')
case "$policy_repo_edit_homepage" in
  deny*) ;;
  *) fail "primary shell policy allowed a protected repo edit with a homepage flag value: $policy_repo_edit_homepage" ;;
esac
policy_fork_dup_org=$(node "$POLICY" --root "$ROOT" --command 'gh repo fork someuser/somerepo --org otherorg --org kunchenguid')
case "$policy_fork_dup_org" in
  deny*) ;;
  *) fail "primary shell policy allowed a protected-org fork with a duplicate org flag: $policy_fork_dup_org" ;;
esac
policy_repo_edit_template=$(node "$POLICY" --root "$ROOT" --command 'gh repo edit --template myorg/myrepo')
[ "$policy_repo_edit_template" = allow ] || fail "primary shell policy blocked a repo edit with a boolean --template: $policy_repo_edit_template"
policy_agent_task=$(node "$POLICY" --root "$ROOT" --command 'gh agent-task create -R kunchenguid/dotfiles x')
case "$policy_agent_task" in
  deny*) ;;
  *) fail "primary shell policy allowed an agent-task protected write: $policy_agent_task" ;;
esac
policy_issue_transfer=$(node "$POLICY" --root "$ROOT" --command 'gh issue transfer 123 kunchenguid/dotfiles -R myorg/myrepo')
case "$policy_issue_transfer" in
  deny*) ;;
  *) fail "primary shell policy allowed a protected issue transfer: $policy_issue_transfer" ;;
esac
policy_read_dir=$(node "$POLICY" --root "$ROOT" --command 'gh repo read-dir kunchenguid/dotfiles')
[ "$policy_read_dir" = allow ] || fail "primary shell policy blocked a read-only repo read-dir: $policy_read_dir"

policy_api_placeholder=$(node "$POLICY" --root "$ROOT" --command "gh api 'repos/{owner}/{repo}/issues' -f title=x")
case "$policy_api_placeholder" in
  deny*) ;;
  *) fail "primary shell policy allowed a protected gh api placeholder mutation: $policy_api_placeholder" ;;
esac

policy_api_org_repo=$(node "$POLICY" --root "$ROOT" --command "gh api -X POST /orgs/kunchenguid/repos -f name=newrepo")
case "$policy_api_org_repo" in
  deny*) ;;
  *) fail "primary shell policy allowed an org-level repository creation into kunchenguid: $policy_api_org_repo" ;;
esac

policy_nice_unresolved=$(node "$POLICY" --root "$ROOT" --command 'nice -10 gh pr create -R kunchenguid/dotfiles --title x')
case "$policy_nice_unresolved" in
  deny*) ;;
  *) fail "primary shell policy allowed an unresolved nice wrapper around a protected write: $policy_nice_unresolved" ;;
esac
policy_nice_resolved=$(node "$POLICY" --root "$ROOT" --command 'nice -n 5 gh pr create -R kunchenguid/dotfiles --title x')
case "$policy_nice_resolved" in
  deny*) ;;
  *) fail "primary shell policy allowed a resolved nice wrapper around a protected write: $policy_nice_resolved" ;;
esac
policy_nice_read=$(node "$POLICY" --root "$ROOT" --command 'nice -10 gh pr view 48 -R kunchenguid/dotfiles')
[ "$policy_nice_read" = allow ] || fail "primary shell policy blocked a read-only unresolved nice wrapper: $policy_nice_read"
pass "primary shell policy fails closed on unresolved wrapper options around guarded tools"

for nested in \
  "nice -10 sh -c 'gh pr create -R kunchenguid/dotfiles --title x'" \
  "nice -10 bash -c 'gh pr create -R kunchenguid/dotfiles --title x'" \
  "nice -10 eval 'gh pr create -R kunchenguid/dotfiles --title x'"; do
  policy_nested_shell=$(node "$POLICY" --root "$ROOT" --command "$nested")
  case "$policy_nested_shell" in
    deny*) ;;
    *) fail "primary shell policy allowed a nested shell after an unresolved wrapper: $nested -> $policy_nested_shell" ;;
  esac
done
policy_nested_shell_read=$(node "$POLICY" --root "$ROOT" --command "nice -10 sh -c 'gh pr view 48 -R kunchenguid/dotfiles'")
[ "$policy_nested_shell_read" = allow ] || fail "primary shell policy blocked a read-only nested shell after an unresolved wrapper: $policy_nested_shell_read"
pass "primary shell policy classifies nested shells after unresolved wrapper options"

for nested in \
  "nice -10 sh <<< 'gh pr create -R kunchenguid/dotfiles --title x'" \
  "nice -10 bash <<< 'gh pr create -R kunchenguid/dotfiles --title x'" \
  "nice -10 sh -s <<< 'gh pr create -R kunchenguid/dotfiles --title x'" \
  "nice -10 env -S 'gh pr create -R kunchenguid/dotfiles --title x'"; do
  policy_stdin_env=$(node "$POLICY" --root "$ROOT" --command "$nested")
  case "$policy_stdin_env" in
    deny*) ;;
    *) fail "primary shell policy allowed a stdin/env payload after an unresolved wrapper: $nested -> $policy_stdin_env" ;;
  esac
done
policy_wrapped_heredoc=$(node "$POLICY" --root "$ROOT" --command $'nice -10 sh <<\'EOF\'\ngh pr create -R kunchenguid/dotfiles --title x\nEOF')
case "$policy_wrapped_heredoc" in
  deny*) ;;
  *) fail "primary shell policy allowed a heredoc after an unresolved wrapper: $policy_wrapped_heredoc" ;;
esac
policy_stdin_read=$(node "$POLICY" --root "$ROOT" --command "nice -10 sh <<< 'gh pr view 48 -R kunchenguid/dotfiles'")
[ "$policy_stdin_read" = allow ] || fail "primary shell policy blocked a read-only here-string after an unresolved wrapper: $policy_stdin_read"
pass "primary shell policy classifies stdin and env -S payloads after unresolved wrapper options"

for nested in \
  "env -P /usr/bin gh pr create -R kunchenguid/dotfiles --title x" \
  "env -P /usr/bin gh-axi pr create -R kunchenguid/dotfiles" \
  "env -P /usr/bin git push git@github.com:kunchenguid/dotfiles.git" \
  "sudo FOO=bar gh pr create -R kunchenguid/dotfiles --title x" \
  "sudo FOO=bar git push git@github.com:kunchenguid/dotfiles.git"; do
  policy_wrapper_flag=$(node "$POLICY" --root "$ROOT" --command "$nested")
  case "$policy_wrapper_flag" in
    deny*) ;;
    *) fail "primary shell policy allowed a protected write through a wrapper flag/assignment: $nested -> $policy_wrapper_flag" ;;
  esac
done
policy_env_P_read=$(node "$POLICY" --root "$ROOT" --command "env -P /usr/bin gh pr view 48 -R kunchenguid/dotfiles")
[ "$policy_env_P_read" = allow ] || fail "primary shell policy blocked a read-only env -P operation: $policy_env_P_read"
policy_sudo_assign_read=$(node "$POLICY" --root "$ROOT" --command "sudo FOO=bar gh pr view 48 -R kunchenguid/dotfiles")
[ "$policy_sudo_assign_read" = allow ] || fail "primary shell policy blocked a read-only sudo assignment operation: $policy_sudo_assign_read"
pass "primary shell policy classifies env -P and sudo assignment wrapper forms"

repo="$TMP_ROOT/repo"
remote="$TMP_ROOT/remote.git"
fm_git_init_commit "$repo"
git init -q --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" remote add upstream git@github.com:kunchenguid/dotfiles.git
git -C "$repo" remote add someuser git@github.com:someuser/somerepo.git
status=0
"$GUARD" check git -C "$repo" push upstream HEAD:refs/heads/test >"$TMP_ROOT/git.out" 2>"$TMP_ROOT/git.err" || status=$?
[ "$status" -eq 2 ] || fail "protected git push should be refused locally"
[ ! -e "$remote/refs/heads/test" ] || fail "protected push unexpectedly changed the local bare remote"
pass "git push destination classification blocks the protected remote without network access"

status=0
"$GUARD" check git -C "$repo" -c remote.pushDefault=git@github.com:kunchenguid/dotfiles.git push \
  >"$TMP_ROOT/gitc1.out" 2>"$TMP_ROOT/gitc1.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c remote.pushDefault override to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c remote.origin.pushurl=git@github.com:kunchenguid/dotfiles.git push origin \
  >"$TMP_ROOT/gitc2.out" 2>"$TMP_ROOT/gitc2.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c remote.origin.pushurl override to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c remote.origin.url=git@github.com:kunchenguid/dotfiles.git push origin \
  >"$TMP_ROOT/gitc3.out" 2>"$TMP_ROOT/gitc3.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c remote.origin.url override to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c branch.main.pushRemote=git@github.com:kunchenguid/dotfiles.git push \
  >"$TMP_ROOT/gitc4.out" 2>"$TMP_ROOT/gitc4.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c branch.<name>.pushRemote override to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c branch.main.pushRemote=upstream push \
  >"$TMP_ROOT/gitc5.out" 2>"$TMP_ROOT/gitc5.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c branch.<name>.pushRemote remote-name override to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c remote.origin.pushurl= -c remote.origin.url=git@github.com:kunchenguid/dotfiles.git push origin \
  >"$TMP_ROOT/gitc6.out" 2>"$TMP_ROOT/gitc6.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c empty pushurl with a protected url override should be refused, got $status"
"$GUARD" check git -C "$repo" -c remote.pushDefault=origin push \
  || fail "git -c remote.pushDefault override to a local remote should be allowed"
"$GUARD" check git -C "$repo" -c branch.main.pushRemote=origin push \
  || fail "git -c branch.<name>.pushRemote override to a local remote should be allowed"
"$GUARD" check git -C "$repo" push origin \
  || fail "git push to a local remote without -c should be allowed"
pass "git -c config overrides are honored when resolving the push destination"

status=0
MYURL=git@github.com:kunchenguid/dotfiles.git "$GUARD" check git -C "$repo" --config-env=remote.origin.url=MYURL push origin main:main \
  >"$TMP_ROOT/gitce1.out" 2>"$TMP_ROOT/gitce1.err" || status=$?
[ "$status" -eq 2 ] || fail "git --config-env remote.origin.url override should be refused, got $status"
status=0
MYURL=git@github.com:kunchenguid/dotfiles.git "$GUARD" check git -C "$repo" --config-env remote.origin.url=MYURL push origin main:main \
  >"$TMP_ROOT/gitce2.out" 2>"$TMP_ROOT/gitce2.err" || status=$?
[ "$status" -eq 2 ] || fail "git --config-env two-arg remote.origin.url override should be refused, got $status"
MYNAME='test' "$GUARD" check git -C "$repo" --config-env=user.name=MYNAME push origin main:main \
  || fail "git --config-env for a non-destination key should be allowed"
pass "git --config-env push-destination overrides are refused when unresolvable"

status=0
"$GUARD" check git -C "$repo" -c 'url.git@github.com:kunchenguid/dotfiles.git.insteadOf=git@github.com:someuser/somerepo.git' push someuser main:main \
  >"$TMP_ROOT/gitio1.out" 2>"$TMP_ROOT/gitio1.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c url.*.insteadOf redirect to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c 'url.git@github.com:kunchenguid/dotfiles.git.pushInsteadOf=git@github.com:someuser/somerepo.git' push someuser main:main \
  >"$TMP_ROOT/gitio2.out" 2>"$TMP_ROOT/gitio2.err" || status=$?
[ "$status" -eq 2 ] || fail "git -c url.*.pushInsteadOf redirect to a protected remote should be refused, got $status"
"$GUARD" check git -C "$repo" push someuser main:main \
  || fail "git push to a non-protected remote without insteadOf should be allowed"
pass "git -c url.*.insteadOf/pushInsteadOf destination redirects are detected"

status=0
"$GUARD" check git -C "$repo" -c 'url.git@github.com:kunchenguid/dotfiles.git.insteadOf=git@github.com:someuser/somerepo.git' push git@github.com:someuser/somerepo.git main:main \
  >"$TMP_ROOT/gitio3.out" 2>"$TMP_ROOT/gitio3.err" || status=$?
[ "$status" -eq 2 ] || fail "git direct-URL insteadOf redirect to a protected remote should be refused, got $status"
status=0
"$GUARD" check git -C "$repo" -c 'url.git@github.com:kunchenguid/dotfiles.git.pushInsteadOf=git@github.com:someuser/somerepo.git' push git@github.com:someuser/somerepo.git main:main \
  >"$TMP_ROOT/gitio4.out" 2>"$TMP_ROOT/gitio4.err" || status=$?
[ "$status" -eq 2 ] || fail "git direct-URL pushInsteadOf redirect to a protected remote should be refused, got $status"
"$GUARD" check git -C "$repo" push git@github.com:someuser/somerepo.git main:main \
  || fail "git push to a direct non-protected URL without insteadOf should be allowed"
"$GUARD" check git -C "$repo" -c 'url.git@github.com:.insteadOf=https://github.com/' push git@github.com:someuser/somerepo.git main:main \
  || fail "git direct non-protected URL with a non-matching insteadOf rule should be allowed"
"$GUARD" check git -C "$repo" -c 'url.git@github.com:.insteadOf=https://github.com/' push https://github.com/someuser/somerepo.git main:main \
  || fail "git direct non-protected URL with a non-protected insteadOf base should be allowed"
pass "git direct-URL insteadOf/pushInsteadOf redirects are detected"

for ssh_url in \
  ssh://git@ssh.github.com:443/kunchenguid/dotfiles.git \
  ssh://git@github.com:22/kunchenguid/dotfiles.git \
  ssh://git@ssh.github.com/kunchenguid/dotfiles.git \
  git@ssh.github.com:kunchenguid/dotfiles.git \
  ssh.github.com/kunchenguid/dotfiles.git; do
  status=0
  "$GUARD" check git push "$ssh_url" main >"$TMP_ROOT/ssh.out" 2>"$TMP_ROOT/ssh.err" || status=$?
  [ "$status" -eq 2 ] || fail "git push to $ssh_url should be refused locally, got $status"
  status=0
  "$GUARD" pre-push upstream "$ssh_url" >"$TMP_ROOT/sshpre.out" 2>"$TMP_ROOT/sshpre.err" || status=$?
  [ "$status" -eq 2 ] || fail "pre-push for $ssh_url should be refused, got $status"
  [ ! -e "$remote/refs/heads/test" ] || fail "ssh-url push unexpectedly changed the local bare remote"
done
pass "ssh.github.com and port-qualified git URLs resolve to the protected upstream"

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

for wrapped in \
  "( gh pr create -R kunchenguid/dotfiles --title x )" \
  "bash -c 'gh pr create -R kunchenguid/dotfiles --title x'" \
  "echo \$(gh pr create -R kunchenguid/dotfiles --title x)"; do
  policy_nested=$(node "$POLICY" --root "$ROOT" --command "$wrapped")
  case "$policy_nested" in
    deny*) ;;
    *) fail "primary shell policy allowed a nested protected write: $wrapped -> $policy_nested" ;;
  esac
done
policy_nested_read=$(node "$POLICY" --root "$ROOT" --command '( gh-axi pr view 48 -R kunchenguid/dotfiles )')
[ "$policy_nested_read" = allow ] || fail "primary shell policy blocked a nested read-only operation: $policy_nested_read"
pass "primary shell policy classifies protected writes inside groups, subshells, and -c payloads"

for flow in \
  'if true; then gh pr create -R kunchenguid/dotfiles --title x; fi' \
  'for x in 1; do gh pr create -R kunchenguid/dotfiles --title x; done' \
  'while false; do gh pr create -R kunchenguid/dotfiles --title x; done' \
  'case x in x) gh pr create -R kunchenguid/dotfiles --title x ;; esac' \
  'time gh pr create -R kunchenguid/dotfiles --title x' \
  '! gh pr create -R kunchenguid/dotfiles --title x' \
  'if true; then sudo gh pr create -R kunchenguid/dotfiles --title x; fi' \
  'for x in 1; do env gh pr create -R kunchenguid/dotfiles --title x; done' \
  'while true; do nohup gh pr create -R kunchenguid/dotfiles --title x; done' \
  'time sudo gh pr create -R kunchenguid/dotfiles --title x' \
  '! sudo gh pr create -R kunchenguid/dotfiles --title x'; do
  policy_flow=$(node "$POLICY" --root "$ROOT" --command "$flow")
  case "$policy_flow" in
    deny*) ;;
    *) fail "primary shell policy allowed a control-flow protected write: $flow -> $policy_flow" ;;
  esac
done
deep_open=$(printf '(%0.s' {1..14})
deep_close=$(printf ')%0.s' {1..14})
policy_deep=$(node "$POLICY" --root "$ROOT" --command "${deep_open}gh pr create -R kunchenguid/dotfiles --title x${deep_close}")
case "$policy_deep" in
  deny*) ;;
  *) fail "primary shell policy allowed a deeply nested protected write: $policy_deep" ;;
esac
policy_flow_read=$(node "$POLICY" --root "$ROOT" --command 'if gh pr view 48 -R kunchenguid/dotfiles; then echo ok; fi')
[ "$policy_flow_read" = allow ] || fail "primary shell policy blocked a read-only control-flow operation: $policy_flow_read"
policy_flow_echo=$(node "$POLICY" --root "$ROOT" --command 'for f in 1; do echo gh; done')
[ "$policy_flow_echo" = allow ] || fail "primary shell policy blocked a control-flow echo: $policy_flow_echo"
policy_flow_wrap_read=$(node "$POLICY" --root "$ROOT" --command 'if true; then sudo gh pr view 48 -R kunchenguid/dotfiles; fi')
[ "$policy_flow_wrap_read" = allow ] || fail "primary shell policy blocked a read-only wrapped control-flow operation: $policy_flow_wrap_read"
pass "primary shell policy fails closed on control-flow and deeply nested protected writes"

for payload in \
  'echo <(gh pr create -R kunchenguid/dotfiles --title x)' \
  'f() { gh pr create -R kunchenguid/dotfiles --title x; }; f' \
  "bash <<< 'gh pr create -R kunchenguid/dotfiles --title x'" \
  'eval "gh pr create -R kunchenguid/dotfiles --title x"' \
  "eval \"gh pr create -R kunchenguid/dotfiles --title \$x\""; do
  policy_payload=$(node "$POLICY" --root "$ROOT" --command "$payload")
  case "$policy_payload" in
    deny*) ;;
    *) fail "primary shell policy allowed a nested protected write: $payload -> $policy_payload" ;;
  esac
done
policy_heredoc=$(node "$POLICY" --root "$ROOT" --command $'bash <<\'EOF\'\ngh pr create -R kunchenguid/dotfiles --title x\nEOF')
case "$policy_heredoc" in
  deny*) ;;
  *) fail "primary shell policy allowed a heredoc protected write: $policy_heredoc" ;;
esac
policy_proc_read=$(node "$POLICY" --root "$ROOT" --command 'echo <(gh pr view 48 -R kunchenguid/dotfiles)')
[ "$policy_proc_read" = allow ] || fail "primary shell policy blocked a read-only process substitution: $policy_proc_read"
policy_eval_read=$(node "$POLICY" --root "$ROOT" --command 'eval "gh pr view 48 -R kunchenguid/dotfiles"')
[ "$policy_eval_read" = allow ] || fail "primary shell policy blocked a read-only eval: $policy_eval_read"
pass "primary shell policy classifies nested process, function, heredoc, herestring, and eval payloads"

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
status=0
FM_ROOT_OVERRIDE="$primary" "$primary/bin/fm-upstream-write-pretool-check.sh" \
  --command "\$'\\x67\\x68' pr create -R kunchenguid/dotfiles --title accidental" \
  >"$TMP_ROOT/ansi.out" 2>"$TMP_ROOT/ansi.err" || status=$?
[ "$status" -eq 2 ] || fail "plain primary PreToolUse transport should deny the ANSI-C quoted protected write, got $status"
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

: >"$LOG"
status=0
FM_HOME="$AUTH_HOME" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$words" -- \
  gh issue transfer 123 kunchenguid/otherrepo -R kunchenguid/dotfiles \
  >"$TMP_ROOT/xfer.out" 2>"$TMP_ROOT/xfer.err" || status=$?
[ "$status" -eq 2 ] || fail "authorized transfer to an out-of-scope protected destination should be refused"
[ "$(wc -l <"$LOG" | tr -d ' ')" = "0" ] || fail "out-of-scope transfer reached the forge stub"
assert_contains "$(cat "$TMP_ROOT/xfer.err")" "outside the named --repo scope" \
  "out-of-scope transfer refusal did not name the scope boundary"
: >"$LOG"
FM_HOME="$AUTH_HOME" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$words" -- \
  gh issue transfer 123 kunchenguid/dotfiles -R kunchenguid/dotfiles \
  || fail "authorized transfer within the named repo scope should run"
assert_contains "$(cat "$LOG")" "issue transfer 123 kunchenguid/dotfiles -R kunchenguid/dotfiles" \
  "in-scope transfer did not reach the forge stub"

echo "# all fm-upstream-write-guard tests passed"
