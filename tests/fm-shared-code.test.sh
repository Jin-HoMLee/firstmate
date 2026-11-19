#!/usr/bin/env bash
# Explicit local code-root binding: real registry/spawn owners, fake terminal
# and Pi executables only. These are command-rendering/isolation tests, NOT a
# native extension, live backend, primary-handoff or safeguard acceptance test.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

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
case "${1:-}" in --help) printf '%s\n' '--approve --tui-mode'; exit 0 ;; esac
printf 'cwd=%s\nhome=%s\nroot=%s\nharness=%s\n' "$(pwd -P)" "$FM_HOME" "$FM_ROOT_OVERRIDE" "$FM_PI_HARNESS" > "$FM_FAKE_WORLD/probe"
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
    (cd "$w/$id" && HOME="$w/user-home" FM_FAKE_WORLD="$w" /bin/bash -c "$native") \
      || fail 'rendered native-command suffix failed'
    assert_grep "cwd=$w/code" "$w/probe" 'native command uses shared cwd'
    assert_grep "home=$w/$id" "$w/probe" 'native command uses its own operational home'
    assert_grep "root=$w/code" "$w/probe" 'native command retains explicit shared root'
    assert_grep "harness=$harness" "$w/probe" 'selected Pi flavor remains explicit'
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
test_missing_native_source_refuses_before_endpoint_creation
