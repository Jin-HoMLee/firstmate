#!/usr/bin/env bash
# Explicit local code-root binding: real registry/spawn owners, fake terminal
# and Pi executables only. These are command-rendering/isolation tests, NOT a
# native extension, live backend, primary-handoff or safeguard acceptance test.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-shared-code)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS PI_CODING_AGENT_DIR

new_shared_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/code/.pi/extensions" "$w/parent/"{data,state,config,projects} "$w/fakebin" "$w/user-home"
  git init -q -b main "$w/code"
  printf 'shared instruction sentinel\n' > "$w/code/AGENTS.md"
  ln -s "$ROOT/bin" "$w/code/bin"
  : > "$w/code/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$w/code/.pi/extensions/fm-primary-turnend-guard.ts"
  git -C "$w/code" add -A
  git -C "$w/code" commit -qm 'synthetic shared source'
  touch "$w/parent/state/.last-watcher-beat"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  list-windows) [ ! -f "$FM_FAKE_WORLD/windows" ] || cat "$FM_FAKE_WORLD/windows" ;;
  new-window)
    previous=
    for arg in "$@"; do
      if [ "$previous" = -n ]; then printf '%s\n' "$arg" >> "$FM_FAKE_WORLD/windows"; fi
      previous=$arg
    done ;;
  display-message) printf 'firstmate\n' ;;
  send-keys)
    previous=
    for arg in "$@"; do
      if [ "$previous" = -l ]; then
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; arg=$(cat "$staged") ;;
        esac
        case "$arg" in *FM_ROOT_OVERRIDE=*) printf '%s\n' "$arg" > "$FM_FAKE_WORLD/launch" ;; esac
      fi
      previous=$arg
    done ;;
esac
SH
  cat > "$w/fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in --help)
  printf '%s\n' '--approve --tui-mode'
  [ -f "$FM_FAKE_WORLD/no-session-dir" ] || printf '%s\n' '--session-dir'
  exit 0 ;;
esac
printf 'cwd=%s\nhome=%s\nroot=%s\nharness=%s\naccount_dir=%s\n' "$(pwd -P)" "$FM_HOME" "$FM_ROOT_OVERRIDE" "$FM_PI_HARNESS" \
  "${PI_CODING_AGENT_DIR:-unset}" > "$FM_FAKE_WORLD/probe"
printf '%s\n' "$@" >> "$FM_FAKE_WORLD/probe"
SH
  chmod +x "$w/fakebin/tmux" "$w/fakebin/pi"
  ln -s pi "$w/fakebin/pi-signed"
  ln -s "$(command -v node)" "$w/fakebin/node"
  printf '%s\n' "$w"
}

add_retained_home() {
  local w=$1 id=$2 home="$1/$2"
  mkdir -p "$home/"{data,state,config,projects,bin}
  git init -q -b main "$home"
  printf 'retained old instruction\n' > "$home/AGENTS.md"
  printf 'old source\n' > "$home/bin/old-source"
  git -C "$home" add -A
  git -C "$home" commit -qm 'retained history'
  printf 'unfinished tracked work\n' >> "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  printf '%s\n' "$id-private" > "$home/data/private-sentinel"
  printf '%s\n' "$id-configuration" > "$home/config/private-sentinel"
  printf -- '- %s - synthetic (root: %s; home: %s; scope: test; projects: none; added 2026-01-01)\n' \
    "$id" "$w/code" "$home" >> "$w/parent/data/secondmates.md"
}

shared_spawn() {
  local w=$1 id=$2 harness=$3
  PATH="$w/fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    HOME="$w/user-home" PI_CODING_AGENT_DIR="$w/user-home/.pi/agent" \
    FM_FAKE_WORLD="$w" FM_HOME="$w/parent" FM_ROOT_OVERRIDE="$w/code" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_TRACE_CONTEXT=off \
    "$ROOT/bin/fm-spawn.sh" "$id" "$w/$id" --secondmate --harness "$harness"
}

test_local_shared_registry_is_explicit_and_disjoint() {
  local w home
  w=$(new_shared_world registry)
  add_retained_home "$w" sm
  home="$w/sm"
  secondmate_registry_validate_bindings "$w/parent/data/secondmates.md" secondmate_registry_path_key sm "$home" \
    || fail "$SECONDMATE_REGISTRY_ERROR"
  assert_equals "$w/code" "$SECONDMATE_REGISTRY_MATCH_ROOT" 'explicit local root parsed'
  assert_equals 0 "$SECONDMATE_REGISTRY_MATCH_REMOTE" 'local root is not a remote route'
  secondmate_registry_parse_line "- legacy - unchanged (home: $home; scope: test; projects: none; added 2026-01-01)" \
    || fail 'legacy row stopped parsing'
  assert_equals '' "$SECONDMATE_REGISTRY_ROOT" 'legacy root must stay absent'
  printf -- '- sm - unsafe (root: %s; home: %s; scope: test; projects: none; added 2026-01-01)\n' "$home" "$home" > "$w/bad-registry"
  if secondmate_registry_validate_bindings "$w/bad-registry" secondmate_registry_path_key; then fail 'overlapping root accepted'; fi
  printf -- '- sm - unsafe (root: relative; home: %s; scope: test; projects: none; added 2026-01-01)\n' "$home" > "$w/bad-registry"
  if secondmate_registry_validate_bindings "$w/bad-registry" secondmate_registry_path_key; then fail 'relative root accepted'; fi
  printf -- '- sm - unsafe (root: /; home: %s; scope: test; projects: none; added 2026-01-01)\n' "$home" > "$w/bad-registry"
  if secondmate_registry_validate_bindings "$w/bad-registry" secondmate_registry_path_key; then fail 'filesystem root accepted'; fi
  pass 'shared-code registry keeps legacy/local/remote placement distinct and rejects unsafe local roots'
}

test_binding_is_sticky_and_recorded_recovery_is_scoped() {
  local w reg root
  w=$(new_shared_world binding)
  add_retained_home "$w" sm
  reg="$w/parent/data/secondmates.md"
  root="$w/code"
  secondmate_local_code_binding "$reg" sm "$w/sm" "$root" '' || fail "$SECONDMATE_REGISTRY_ERROR"
  assert_equals "$root" "$SECONDMATE_LOCAL_CODE_ROOT" 'declared binding resolves'
  secondmate_local_code_binding "$w/missing-registry" sm "$w/sm" "$root" "$root" \
    || fail 'recorded binding must survive absent-registry recovery'
  printf -- '- sm - legacy (home: %s; scope: test; projects: none; added 2026-01-01)\n' "$w/sm" > "$reg"
  if secondmate_local_code_binding "$reg" sm "$w/sm" "$root" "$root"; then fail 'activated binding silently reverted'; fi
  if secondmate_local_code_binding "$w/missing-registry" sm "$w/sm" "$w/sm" "$root"; then fail 'another owner root accepted'; fi
  git -C "$root" worktree add -q --detach "$w/task-code" HEAD
  if secondmate_local_code_binding "$w/missing-registry" sm "$w/sm" "$w/task-code" "$w/task-code"; then
    fail 'task copy accepted as maintained shared code'
  fi
  pass 'recorded binding recovery cannot silently change owner, change root, or fall back to old home source'
}

test_binding_metadata_is_unambiguous() {
  local w meta head
  w=$(new_shared_world metadata)
  meta="$w/binding.meta"
  head=$(git -C "$w/code" rev-parse HEAD)
  printf 'code_root=%s\ncode_head=%s\n' "$w/code" "$head" > "$meta"
  assert_equals "$w/code" "$(secondmate_code_root_from_meta "$meta")" 'root metadata round trip'
  assert_equals "$head" "$(secondmate_code_head_from_meta "$meta")" 'launch HEAD metadata round trip'
  printf 'code_root=%s\n' "$w/code" >> "$meta"
  if secondmate_code_root_from_meta "$meta" >/dev/null; then fail 'duplicate root metadata accepted'; fi
  printf 'code_head=--not-a-commit\n' > "$meta"
  if secondmate_code_head_from_meta "$meta" >/dev/null; then fail 'non-object launch HEAD accepted'; fi
  printf 'code_root=\n' > "$meta"
  if secondmate_code_root_from_meta "$meta" >/dev/null; then fail 'empty activated root accepted'; fi
  pass 'shared-code metadata refuses duplicate, empty and non-object activation fields'
}

test_native_axes_are_explicitly_bounded() {
  local harness backend
  for harness in pi pi-signed; do
    secondmate_shared_code_launch_supported "$harness" tmux || fail 'declared shared-code axis refused'
  done
  for harness in claude codex opencode grok kimi cursor omp agy muse gemini rovo devin commandcode polytoken cortex kiro hermes; do
    if secondmate_shared_code_launch_supported "$harness" tmux >/dev/null 2>&1; then fail "unimplemented shared-code adapter accepted: $harness"; fi
  done
  for backend in herdr zellij rex t3 orca; do
    if secondmate_shared_code_launch_supported pi "$backend" >/dev/null 2>&1; then fail "unimplemented shared-code backend accepted: $backend"; fi
  done
  pass 'shared-code native axis allowlist does not broaden legacy runtime support'
}

test_four_homes_share_rendered_code_not_private_state_or_history() {
  local w id harness before_head before_diff launch native marker meta index=0
  w=$(new_shared_world 'four homes')
  for id in sm1 sm2 sm3 sm4; do add_retained_home "$w" "$id"; done
  for id in sm1 sm2 sm3 sm4; do
    index=$((index + 1))
    harness=pi
    [ "$index" -le 2 ] || harness=pi-signed
    before_head=$(git -C "$w/$id" rev-parse HEAD)
    before_diff=$(git -C "$w/$id" diff HEAD -- AGENTS.md)
    shared_spawn "$w" "$id" "$harness" > "$w/spawn-$id.log" 2>&1 \
      || fail "shared spawn failed: $(cat "$w/spawn-$id.log")"
    meta="$w/parent/state/$id.meta"
    assert_grep "home=$w/$id" "$meta" 'home custody stays separate'
    assert_grep "worktree=$w/$id" "$meta" 'retained source custody stays separate'
    assert_grep "code_root=$w/code" "$meta" 'activated source binding recorded'
    assert_equals "$(git -C "$w/code" rev-parse HEAD)" "$(secondmate_code_head_from_meta "$meta")" 'launch HEAD recorded'
    launch=$(fm_test_launch_unframe "$(cat "$w/launch")")
    marker="cd -- '$w/code' && "
    case "$launch" in *"$marker"*) ;; *) fail "shared cwd missing: $launch" ;; esac
    native="$marker${launch#*"$marker"}"
    # Execute only the verbatim native-command suffix, with a shell-only fake Pi.
    # No reporter helper, real agent, extension or service is started here.
    (cd "$w/$id" && HOME="$w/user-home" PI_CODING_AGENT_DIR="$w/selected-account" FM_FAKE_WORLD="$w" /bin/bash -c "$native") \
      || fail 'rendered native-command suffix failed'
    assert_grep "cwd=$w/code" "$w/probe" 'native command uses shared cwd'
    assert_grep "home=$w/$id" "$w/probe" 'native command uses its own operational home'
    assert_grep "root=$w/code" "$w/probe" 'native command retains explicit shared root'
    assert_grep "harness=$harness" "$w/probe" 'selected Pi flavor remains explicit'
    assert_grep "account_dir=$w/selected-account" "$w/probe" 'private conversation storage does not change account selection'
    assert_grep --session-dir "$w/probe" 'native command explicitly selects its conversation namespace'
    assert_grep "$w/$id/data/pi-sessions" "$w/probe" 'native command uses a distinct private conversation directory'
    assert_equals 700 "$(fm_pr_file_mode "$w/$id/data/pi-sessions")" 'new conversation directory is private'
    assert_grep "$w/code/.pi/extensions/fm-primary-pi-watch.ts" "$w/probe" 'watch extension comes from shared source'
    assert_grep "$w/code/.pi/extensions/fm-primary-turnend-guard.ts" "$w/probe" 'turn-end extension comes from shared source'
    assert_equals "$before_head" "$(git -C "$w/$id" rev-parse HEAD)" 'retained home HEAD unchanged'
    assert_equals "$before_diff" "$(git -C "$w/$id" diff HEAD -- AGENTS.md)" 'unfinished tracked work unchanged'
    assert_equals "$id-private" "$(cat "$w/$id/data/private-sentinel")" 'private data not mixed'
    assert_equals "$id-configuration" "$(cat "$w/$id/config/private-sentinel")" 'private config not mixed'
    [ ! -e "$w/code/data/private-sentinel" ] || fail 'private state leaked into shared code'
  done
  pass 'four retained homes render/execute isolated Pi-family commands from one code root without syncing old history'
}

test_unsupported_or_unsafe_session_storage_refuses_before_endpoint_creation() {
  local w variant rc sessions before=
  for variant in missing-flag permissive-cache symlink-cache writable-parent; do
    w=$(new_shared_world "$variant")
    add_retained_home "$w" sm
    sessions="$w/sm/data/pi-sessions"
    case "$variant" in
      missing-flag) touch "$w/no-session-dir" ;;
      permissive-cache)
        mkdir "$sessions"; chmod 755 "$sessions"
        printf 'kept native history\n' > "$sessions/kept"
        before=$(git hash-object "$sessions/kept") ;;
      symlink-cache)
        mkdir "$w/foreign"
        printf 'kept foreign history\n' > "$w/foreign/kept"
        before=$(git hash-object "$w/foreign/kept")
        ln -s "$w/foreign" "$sessions" ;;
      writable-parent) chmod g+w "$w/sm/data" ;;
    esac
    rc=0
    shared_spawn "$w" sm pi > "$w/refusal.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "$variant native session setup was accepted"
    [ ! -e "$w/windows" ] || fail "$variant created an endpoint before refusing"
    case "$variant" in
      missing-flag|writable-parent) [ ! -e "$sessions" ] || fail 'refusal created native storage' ;;
      permissive-cache)
        assert_equals 755 "$(fm_pr_file_mode "$sessions")" 'existing permissions are not silently changed'
        assert_equals "$before" "$(git hash-object "$sessions/kept")" 'old cache bytes unchanged' ;;
      symlink-cache)
        [ -L "$sessions" ] || fail 'foreign native-storage pointer was replaced'
        assert_equals "$before" "$(git hash-object "$w/foreign/kept")" 'foreign cache bytes unchanged' ;;
    esac
  done
  pass 'unverified CLI and unsafe native session storage refuse before endpoint creation without account/cache repair'
}

test_retained_project_admin_and_unresolved_custody_are_not_relocated() {
  local w id i project external common before_worktrees before_index before_config before_unmerged
  local before_custody after_custody base ours theirs file
  local -a custody_files
  w=$(new_shared_world 'retained project administration')
  for id in sm1 sm2; do
    add_retained_home "$w" "$id"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w/parent" > "$w/$id/.fm-secondmate-parent"
    mkdir -p "$w/$id/state/kept.inbox/handled"
    printf 'arriving correlation and payload\n' > "$w/$id/state/kept.inbox/001.msg"
    printf 'previously handled payload\n' > "$w/$id/state/kept.inbox/handled/000.msg"
  done
  project="$w/sm1/projects/private-project"
  git init -q -b main "$project"
  printf 'private project work\n' > "$project/work.txt"
  git -C "$project" add -A
  git -C "$project" commit -qm 'synthetic retained project'
  for i in {1..9}; do
    git -C "$project" worktree add -q --detach "$w/external-$i" HEAD
  done
  printf 'unfinished private change\n' >> "$project/work.txt"
  external="$w/external-1"
  base=$(printf 'base\n' | git -C "$external" hash-object -w --stdin)
  ours=$(printf 'ours\n' | git -C "$external" hash-object -w --stdin)
  theirs=$(printf 'theirs\n' | git -C "$external" hash-object -w --stdin)
  printf '100644 %s 1\tconflict.txt\n100644 %s 2\tconflict.txt\n100644 %s 3\tconflict.txt\n' "$base" "$ours" "$theirs" \
    | git -C "$external" update-index --index-info
  before_unmerged=$(git -C "$external" ls-files --stage)
  before_index=$(git hash-object "$(git -C "$external" rev-parse --git-path index)")
  before_config=$(git hash-object "$project/.git/config")
  before_worktrees=$(git -C "$project" worktree list --porcelain)
  # Two intentionally contradictory private records point at a separate mock
  # source copy. Launching from common code must not resolve either claim.
  git -C "$w/code" worktree add -q -b mock-actual "$w/ambiguous-copy" HEAD
  printf 'kind=scout\nworktree=%s\nbranch=mock-recovery\n' "$w/ambiguous-copy" > "$w/sm1/state/preserved-claim.meta"
  printf 'kind=ship\nworktree=%s\nbranch=mock-actual\n' "$w/ambiguous-copy" > "$w/sm2/state/preserved-claim.meta"
  custody_files=()
  for id in sm1 sm2; do
    custody_files+=("$w/$id/.fm-secondmate-home" "$w/$id/.fm-secondmate-parent"
      "$w/$id/state/preserved-claim.meta" "$w/$id/state/kept.inbox/001.msg"
      "$w/$id/state/kept.inbox/handled/000.msg")
  done
  before_custody=$(for file in "${custody_files[@]}"; do git hash-object "$file"; done)
  for id in sm1 sm2; do
    shared_spawn "$w" "$id" pi > "$w/spawn-$id.log" 2>&1 \
      || fail "shared spawn with retained administration failed: $(cat "$w/spawn-$id.log")"
  done
  for i in {1..9}; do
    common=$(git -C "$w/external-$i" rev-parse --git-common-dir)
    assert_equals "$project/.git" "$common" 'external copy still depends on retained in-home Git administration'
  done
  assert_equals "$before_worktrees" "$(git -C "$project" worktree list --porcelain)" 'all nine external copies remain registered in place'
  assert_equals "$before_index" "$(git hash-object "$(git -C "$external" rev-parse --git-path index)")" 'unmerged index bytes preserved'
  assert_equals "$before_unmerged" "$(git -C "$external" ls-files --stage)" 'unmerged stages are not repaired or discarded'
  assert_equals "$before_config" "$(git hash-object "$project/.git/config")" 'private project Git configuration unchanged'
  assert_grep 'unfinished private change' "$project/work.txt" 'dirty private project content stays in place'
  after_custody=$(for file in "${custody_files[@]}"; do git hash-object "$file"; done)
  assert_equals "$before_custody" "$after_custody" 'identity, parent binding, queued/history payloads and both claims remain byte-identical'
  assert_equals mock-actual "$(git -C "$w/ambiguous-copy" branch --show-current)" 'actual branch is not renamed to resolve a claim'
  pass 'shared-code selection preserves nested project administration, nine external copies, an unmerged index and unresolved private custody'
}

test_missing_native_source_refuses_before_endpoint_creation() {
  local w rc=0
  w=$(new_shared_world missing-extension)
  add_retained_home "$w" sm
  rm "$w/code/.pi/extensions/fm-primary-pi-watch.ts"
  shared_spawn "$w" sm pi > "$w/refusal.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'missing native extension accepted'
  assert_grep 'shared-code primary extension is unavailable' "$w/refusal.log" 'concrete missing native binding surfaced'
  [ ! -e "$w/windows" ] || fail 'endpoint created before native source refusal'
  [ ! -e "$w/parent/state/sm.meta" ] || fail 'activation recorded despite missing native source'
  pass 'missing shared native wiring refuses before creating or activating a replacement'
}

test_local_shared_registry_is_explicit_and_disjoint
test_binding_is_sticky_and_recorded_recovery_is_scoped
test_binding_metadata_is_unambiguous
test_native_axes_are_explicitly_bounded
test_four_homes_share_rendered_code_not_private_state_or_history
test_unsupported_or_unsafe_session_storage_refuses_before_endpoint_creation
test_retained_project_admin_and_unresolved_custody_are_not_relocated
test_missing_native_source_refuses_before_endpoint_creation
