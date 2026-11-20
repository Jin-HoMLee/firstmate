import os, pathlib, subprocess, sys
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/jin-holee/.no-mistakes/evidence/01M7WABRMAXE1T7J3D2NWZ0YME')
PLANS = {
 'shared-evidence': ('fm-shared-code', 'test_local_shared_registry_is_explicit_and_disjoint', [
  'test_four_homes_share_rendered_code_not_private_state_or_history',
  'test_prepared_reference_view_keeps_native_home_and_private_semantics']),
 'update': ('fm-update', 'test_registry_only_reference_update_uses_overridden_data', [
  'test_registry_only_reference_update_uses_overridden_data',
  'test_reference_update_rejects_malformed_registry_entries',
  'test_prepared_reference_updates_keep_the_recognized_layout',
  'test_shared_update_uses_lifecycle_locks_and_pins_its_target',
  'test_reference_update_respects_route_and_view_ownership',
  'test_shared_code_update_rebinds_from_code_not_retained_home']),
 'fleet': ('fm-fleet-sync', 'test_shared_primary_source_uses_the_update_owner', ['test_shared_primary_source_uses_the_update_owner']),
 'session': ('fm-session-start', 'test_context_digest_absent_empty_present', [
  'test_bootstrap_phase_markers_stream_without_child_output',
  'test_bootstrap_phase_markers_respect_read_only_and_reemit',
  'test_bootstrap_phase_markers_survive_the_existing_runtime_bound']),
 'relaunch': ('fm-control-relaunch', 'test_relaunch_off_opencode_removes_tracked_wiring', [
  'test_shared_code_relaunch_keeps_custody_and_rebuilds_native_binding',
  'test_shared_code_relaunch_refuses_unsupported_profile_before_stop',
  'test_shared_code_relaunch_refuses_unverified_native_storage_before_stop',
  'test_shared_code_relaunch_preserves_unmapped_native_settings_before_stop',
  'test_shared_code_relaunch_refuses_binding_removal_before_stop',
  'test_shared_code_relaunch_refuses_missing_native_wiring_before_stop',
  'test_herdr_reference_view_keeps_existing_session_and_refuses_unknown_identity']),
 'safety': ('fm-secondmate-safety', 'test_fm_home_parameterization', [
  'test_reseed_preserves_declared_local_shared_code_root',
  'test_shared_code_retirement_refuses_even_with_force',
  'test_forced_parent_retirement_preserves_shared_code_descendant']),
 'sync': ('fm-secondmate-sync', 'test_shared_code_sweep_keeps_old_source_and_requires_native_refresh', [
  'test_shared_code_sweep_keeps_old_source_and_requires_native_refresh',
  'test_shared_code_pending_nudge_does_not_substitute_for_native_refresh']),
 'tasks': ('fm-tasks-axi', 'test_shared_code_keeps_four_home_backlogs_separate', ['test_shared_code_keeps_four_home_backlogs_separate']),
 'pins': ('fm-harness-precedence', 'test_shared_code_reads_each_home_pin_without_copying_source', ['test_shared_code_reads_each_home_pin_without_copying_source'])
}
key = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else 'current'
suite, first, names = PLANS[key]
if mode == 'before-override': names = names[:1]
if mode == 'before-malformed': names = names[1:2]
source = (ROOT/'tests'/f'{suite}.test.sh').read_text()
# Select existing executable test functions; no source-text assertions are tests.
prefix = source.split('\n'+first+'\n', 1)[0]+'\n'
assert prefix != source+'\n', 'selection boundary not found'
setup = ''
if key == 'safety':
    setup += f'export FM_ROOT_OVERRIDE="{ROOT}/.nm-test-tmp/contained-source"\n'
if mode.startswith('before'):
    setup += f'ROOT="{ROOT}/.nm-test-tmp/before"\n'
    if key == 'update': setup += 'UPDATE="$ROOT/bin/fm-update.sh"\n'
if key == 'update':
    setup += '''
eval "$(declare -f run_update | /usr/bin/awk 'NR==1{sub(/run_update/, "original_run_update")} {print}')"
run_update() {
  local w=$1 before after output rc=0
  before=$(git -C "$w/main" rev-parse HEAD)
  output=$(original_run_update "$@") || rc=$?
  after=$(git -C "$w/main" rev-parse HEAD)
  {
    printf '\\n=== %s ===\\ncommand: FM_HOME=<fixture>/home FM_ROOT_OVERRIDE=<fixture>/main FM_DATA_OVERRIDE=%s bin/fm-update.sh\\n' "${w##*/}" "${FM_DATA_OVERRIDE:-unset}"
    printf '%s\\nexit=%s\\nsource_HEAD_before=%s\\nsource_HEAD_after=%s\\n' "$output" "$rc" "$before" "$after"
    if [ -d "$w/shared" ]; then
      printf 'retained_home_HEAD=%s\\nAGENTS_reference=%s\\n' "$(git -C "$w/shared" rev-parse HEAD)" "$(readlink "$w/shared/AGENTS.md" || true)"
      if [ -e "$w/home/state/shared.meta" ]; then
        grep '^code_' "$w/home/state/shared.meta" || true
      else
        printf 'launch_metadata=absent\\n'
      fi
    fi
  } >> "$FM_PHASE_EVIDENCE/update-cli-$FM_PHASE_MODE.log"
  printf '%s\\n' "$output"
  return "$rc"
}
'''
# tee preserves the streaming timing contract of the synthetic digest entrypoint.
if key == 'session':
    setup += '''
eval "$(declare -f run_session_start | /usr/bin/awk 'NR==1{sub(/run_session_start/, "original_run_session_start")} {print}')"
run_session_start() {
  set -o pipefail
  original_run_session_start "$@" | tee -a "$FM_PHASE_EVIDENCE/startup-digest.log"
}
'''
body = prefix + setup + '\n' + '\n'.join(names)+'\n'
if key == 'fleet':
    # A non-mutating observer captures the public CLI output, not source bytes.
    body = body.replace('"$ROOT/bin/fm-fleet-sync.sh" "$code" 2>/dev/null)', '"$ROOT/bin/fm-fleet-sync.sh" "$code" 2>/dev/null | tee -a "$FM_PHASE_EVIDENCE/fleet-cli-$FM_PHASE_MODE.log")')
if key == 'shared-evidence':
    body += '''
python3 - "$TMP_ROOT" "$FM_PHASE_EVIDENCE/shared-home-bindings.log" <<'PY'
import pathlib, subprocess, sys
root, dest = map(pathlib.Path, sys.argv[1:])
def git(home, *args):
    return subprocess.check_output(['git', '-C', str(home), *args], text=True).strip()
with dest.open('w') as out:
    out.write('Synthetic command-rendering evidence only: shell-only Pi/tmux doubles, no live agent or service.\\n')
    for world in sorted(root.iterdir()):
        if not world.is_dir(): continue
        out.write('\\n=== '+world.name+' ===\\n')
        for meta in sorted((world/'parent'/'state').glob('*.meta')):
            out.write('\\nParent launch record '+meta.name+'\\n')
            values = dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
            for key in ('home','worktree','harness','code_root','code_head','code_native_cwd'):
                out.write(key+'='+values.get(key,'<absent>')+'\\n')
            home = pathlib.Path(values['home'])
            out.write('retained_HEAD='+git(home,'rev-parse','HEAD')+'\\n')
            original = home/'data/reference-originals/AGENTS.md'
            if not original.exists(): original=home/'AGENTS.md'
            out.write('retained_instruction_bytes='+repr(original.read_text())+'\\n')
            out.write('private_data='+repr((home/'data/private-sentinel').read_text())+'\\n')
            out.write('private_configuration='+repr((home/'config/private-sentinel').read_text())+'\\n')
        probe=world/'probe'
        if probe.exists():
            out.write('\\nLast executed native-command suffix response:\\n'+probe.read_text())
PY
'''
script = ROOT/'tests'/f'.nm-focused-{key}-{mode}.sh'
script.write_text(body)
env = os.environ.copy()
env.update(TMPDIR=str(ROOT/'.nm-test-tmp'), FM_TEST_SKIP_ORPHAN_REAP='1', FM_PHASE_EVIDENCE=str(EVIDENCE), FM_PHASE_MODE=mode)
try:
    result = subprocess.run(['bash',str(script)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (ROOT/'.nm-test-tmp'/f'{key}-{mode}.log').write_text(result.stdout)
    print(result.stdout, end='')
    print(f'FOCUSED_RESULT {key} {mode} exit={result.returncode}')
    sys.exit(result.returncode)
finally:
    script.unlink(missing_ok=True)
