#!/usr/bin/env bash
# Registered old-code consumers: real producer and authenticated registration
# owners in contained fixture homes. No real registrations, agents or network.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions-arm)

new_consumer_world() {
  local w="$TMP_ROOT/$1" dir entry
  mkdir -p "$w/code/bin" "$w/home/"{bin,state,data,config,projects} \
    "$w/home/retained data" "$w/home/retained config" "$w/fakebin" "$w/user-home"
  for dir in "$w/code/bin" "$w/home/bin"; do
    for entry in "$ROOT/bin/"*; do ln -s "$entry" "$dir/${entry##*/}"; done
  done
  printf '# Backlog\n\n## Queued\n' > "$w/home/data/backlog.md"
  printf '# Backlog\n\n## Queued\n' > "$w/home/retained data/backlog.md"
  # Spy on the canonical helper, then run its actual empty-ownership projection.
  rm "$w/code/bin/fm-fleet-snapshot.sh"
  cat > "$w/code/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s|%s\n' "$FM_ROOT_OVERRIDE" "$FM_HOME" "$FM_STATE_OVERRIDE" \
  "$FM_DATA_OVERRIDE" "$FM_CONFIG_OVERRIDE" "${FM_CONTRIBUTIONS_BUDGET:-}" \
  "${FM_CONTRIBUTIONS_REPLY_AGE:-}" >> "$FM_TEST_CONSUMER_PROBE"
exec "$FM_TEST_REAL_ROOT/bin/fm-fleet-snapshot.sh" "$@"
SH
  chmod +x "$w/code/bin/fm-fleet-snapshot.sh"
  printf '#!/bin/sh\nexit 1\n' > "$w/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$w/fakebin/no-mistakes"
  cat > "$w/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'unexpected forge call\n' >> "$FM_TEST_NETWORK_PROBE"
exit 99
SH
  ln -s gh "$w/fakebin/gh-axi"
  chmod +x "$w/fakebin/"*
  printf '%s\n' "$w"
}

consumer_call() {
  local w=$1 root=$2; shift 2
  HOME="$w/user-home" PATH="$w/fakebin:$PATH" FM_TEST_REAL_ROOT="$ROOT" \
    FM_TEST_CONSUMER_PROBE="$w/probe" FM_TEST_NETWORK_PROBE="$w/network" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$w/home/state" \
    FM_DATA_OVERRIDE="$w/home/data" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_CONTRIBUTIONS_BUDGET=1 FM_CONTRIBUTIONS_REPLY_AGE=999 \
    "$root/bin/fm-contributions.sh" "$@"
}

seed_registered_old_check() {
  local w=$1 format=${2:-current}
  HOME="$w/user-home" PATH="$w/fakebin:$PATH" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
    FM_DATA_OVERRIDE="$w/home/retained data" FM_CONFIG_OVERRIDE="$w/home/retained config" \
    FM_CONTRIBUTIONS_BUDGET=7 FM_CONTRIBUTIONS_REPLY_AGE=123 \
    "$w/home/bin/fm-contributions.sh" arm >/dev/null
  if [ "$format" = legacy ]; then
    # Materialize the previous producer's no-root-export format ONLY in this
    # fixture. Its trust record is always produced by the real registrar.
    awk '!/^export FM_ROOT_OVERRIDE=/' "$w/home/state/contributions.check.sh" > "$w/legacy-check"
    chmod 700 "$w/legacy-check"
    mv "$w/legacy-check" "$w/home/state/contributions.check.sh"
    FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
      "$ROOT/bin/fm-check-register.sh" contributions >/dev/null
  fi
  fm_custom_check_registered "$w/home/state" contributions || fail 'old fixture check is not registered'
}

test_refresh_preserves_private_bindings_and_policy_without_owned_rows() {
  local w format flag expected before after
  for format in legacy current; do
    for flag in --refresh-existing --if-owned; do
      w=$(new_consumer_world "$format $flag")
      seed_registered_old_check "$w" "$format"
      before=$(fm_custom_check_sha256 "$w/home/state/contributions.check.sh")
      consumer_call "$w" "$w/code" arm "$flag" > "$w/arm.log" 2>&1 \
        || fail "could not refresh $format $flag: $(cat "$w/arm.log")"
      after=$(fm_custom_check_sha256 "$w/home/state/contributions.check.sh")
      assert_not_equals "$before" "$after" 'old executable source was replaced'
      fm_custom_check_registered "$w/home/state" contributions || fail 'refreshed bytes are not authenticated'
      assert_grep "exec $(printf '%q' "$w/code/bin/fm-contributions.sh") poll" \
        "$w/home/state/contributions.check.sh" 'consumer executes the maintained source'
      # Execute the actual registered empty-ownership poll under deliberately
      # wrong inherited selectors. The shim must select its retained home and
      # configuration, not the parent/caller's environment or old code root.
      HOME="$w/user-home" PATH="$w/fakebin:$PATH" FM_TEST_REAL_ROOT="$ROOT" \
        FM_TEST_CONSUMER_PROBE="$w/probe" FM_TEST_NETWORK_PROBE="$w/network" \
        FM_ROOT_OVERRIDE="$w/home" FM_HOME="$w/wrong-home" FM_STATE_OVERRIDE="$w/wrong-state" \
        FM_DATA_OVERRIDE="$w/wrong-data" FM_CONFIG_OVERRIDE="$w/wrong-config" \
        FM_CONTRIBUTIONS_BUDGET=2 FM_CONTRIBUTIONS_REPLY_AGE=888 \
        bash "$w/home/state/contributions.check.sh" > "$w/poll.log" 2>&1 \
        || fail "refreshed registered poll failed: $(cat "$w/poll.log")"
      expected="$w/code|$w/home|$w/home/state|$w/home/retained data|$w/home/retained config|7|123"
      assert_equals "$expected" "$(cat "$w/probe")" 'source changes without changing private selectors or stored policy'
      [ ! -e "$w/network" ] || fail 'empty-ownership source refresh contacted a forge'
      consumer_call "$w" "$w/code" arm "$flag" >/dev/null || fail 'repeat refresh failed'
      assert_equals "$after" "$(fm_custom_check_sha256 "$w/home/state/contributions.check.sh")" 'refresh is byte-stable'
    done
  done
  pass 'registered legacy/current checks refresh from maintained source with private selectors and policy unchanged'
}

test_absent_checks_are_not_invented() {
  local w flag
  for flag in --refresh-existing --if-owned; do
    w=$(new_consumer_world "absent $flag")
    consumer_call "$w" "$w/code" arm "$flag" >/dev/null || fail 'empty ownership refresh failed'
    [ ! -e "$w/home/state/contributions.check.sh" ] || fail 'an unowned check was invented'
    [ ! -e "$w/home/state/contributions.check-trust" ] || fail 'an unowned registration was invented'
    [ ! -e "$w/network" ] || fail 'empty registration lookup contacted a forge'
  done
  pass 'refresh does not invent a check or registration when none was owned'
}

test_untrusted_or_custom_checks_are_preserved_and_refused() {
  local w variant before_check before_trust rc
  for variant in untrusted custom custom-no-newline custom-selector nul; do
    w=$(new_consumer_world "$variant")
    seed_registered_old_check "$w"
    case "$variant" in
      custom-no-newline) printf '# preserved custom suffix' >> "$w/home/state/contributions.check.sh" ;;
      custom-selector)
        awk -v target="$w/unexpected-side-effect" '/^export FM_DATA_OVERRIDE=/ {print "export FM_DATA_OVERRIDE=$(touch " target ")";next}{print}' \
          "$w/home/state/contributions.check.sh" > "$w/changed-check"
        chmod 700 "$w/changed-check"
        mv "$w/changed-check" "$w/home/state/contributions.check.sh" ;;
      nul) printf '\0' >> "$w/home/state/contributions.check.sh" ;;
      *) printf '# preserved custom suffix\n' >> "$w/home/state/contributions.check.sh" ;;
    esac
    if [ "$variant" != untrusted ]; then
      FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
        "$ROOT/bin/fm-check-register.sh" contributions >/dev/null
    fi
    before_check=$(fm_custom_check_sha256 "$w/home/state/contributions.check.sh")
    before_trust=$(fm_custom_check_sha256 "$w/home/state/contributions.check-trust")
    rc=0
    consumer_call "$w" "$w/code" arm --refresh-existing > "$w/refusal.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "$variant existing check was rewritten"
    assert_equals "$before_check" "$(fm_custom_check_sha256 "$w/home/state/contributions.check.sh")" 'existing check bytes preserved'
    assert_equals "$before_trust" "$(fm_custom_check_sha256 "$w/home/state/contributions.check-trust")" 'existing trust bytes preserved'
    assert_grep 'leaving its files unchanged' "$w/refusal.log" 'source/config conflict is explicit'
    [ ! -e "$w/network" ] || fail 'refused check was executed'
    [ ! -e "$w/unexpected-side-effect" ] || fail 'private selector was evaluated instead of treated as data'
    [ -z "$(find "$w/home/state" -name '.fm-custom-check.*' -print)" ] || fail 'authenticated snapshot leaked'
  done
  pass 'untrusted or unsupported custom checks remain unchanged rather than being automatically re-trusted'
}

test_refresh_preserves_private_bindings_and_policy_without_owned_rows
test_absent_checks_are_not_invented
test_untrusted_or_custom_checks_are_preserved_and_refused
