# Targeted source-only behavior evidence

Target: `86c53b38389d7e7602b7dddd620bb50c425168cf`.
Comparison base: `427056c4181c41074ad24f051f79919330df0fa5`.
The latest review fixes were also tested against their immediate predecessor, `bfde0709` (`HEAD^`).

## What the product artifacts show

- [Current update CLI and persisted state](update-cli-current.log): a registry-only prepared consumer under `FM_DATA_OVERRIDE` blocks publication while its lifecycle lock is owned, then blocks an incompatible new managed path even without launch metadata. Missing-date and truncated entries stop publication. Ordinary prose permits publication. Content-only updates advance common source while leaving retained history and recorded launch identity unchanged. Added/removed/type/alias/unreadable layouts stop before advancement. A publication-time moving remote ref cannot replace the inspected commit. Consumer refresh preserves private policy and refuses custom conflicts.
- [Project-refresh CLI](fleet-cli-current.log): recorded/declared consumers route to the update owner; malformed/unsafe inventories stop source publication; ordinary prose, legacy and remote routes retain supported refresh behavior. The existing test additionally verifies ordinary project refresh is unaffected in every case.
- [Four-home launch records, retained bytes, and fake native-command responses](shared-home-bindings.log): one common code root is selected for four separate homes, with separate private data/configuration and retained unfinished instructions. Prepared references retain home-local cwd and native session semantics. These are shell-only Pi/tmux doubles, not proof of real native loading.
- [Synthetic startup digest](startup-digest.log): fixed phase labels and elapsed entry/exit times around the two existing boundaries, with captured child output replayed after return. The focused test observes the entry while each child is deliberately blocked and verifies no child output bypasses capture. Timeout cases retain entry without claiming exit/completion under the existing requested aggregate bound. All records and sentinels in this transcript are freshly generated test data.

## Failure reproduction before the fixes

The three new regression paths each fail against executable source archived from `HEAD^` and pass against the target:

1. [Override regression](update-cli-before-override.log): the old update advances source despite a fixture-owned lifecycle lock and an overridden registry-only consumer (`exit=0`, different before/after HEAD).
2. [Malformed entry regression](update-cli-before-malformed.log): the old update removes a referenced managed path despite a missing-date registry row (`exit=0`, different before/after HEAD).
3. [Project-refresh regression](fleet-cli-before.log): the old fleet refresh advances the missing-date case instead of refusing unreadable routing.

These expected predecessor failures are not target failures.

## Exact focused execution

The transient runner was removed after testing; [focused-reproduction.py](focused-reproduction.py) preserves its exact selector lists and evidence observers.
It retains each existing suite's setup and test functions and executes only the named functions, rather than running the full repository suite.
Observers capture public CLI output and fixture state; they do not replace assertions with implementation-source inspection.
Run it from the repository root after creating `.nm-test-tmp`.
Its evidence destination is this run's absolute evidence directory.

Commands run:

```sh
TMPDIR="$PWD/.nm-test-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/fm-shared-code.test.sh
python3 .nm-test-tmp/run-focused.py update
python3 .nm-test-tmp/run-focused.py fleet
python3 .nm-test-tmp/run-focused.py relaunch
python3 .nm-test-tmp/run-focused.py session
python3 .nm-test-tmp/run-focused.py sync
python3 .nm-test-tmp/run-focused.py safety
python3 .nm-test-tmp/run-focused.py tasks
python3 .nm-test-tmp/run-focused.py pins
TMPDIR="$PWD/.nm-test-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/fm-contributions-arm.test.sh
python3 .nm-test-tmp/run-focused.py update before-override
python3 .nm-test-tmp/run-focused.py update before-malformed
python3 .nm-test-tmp/run-focused.py fleet before
python3 .nm-test-tmp/run-focused.py shared-evidence
```

Predecessor source was created inside the worktree using:

```sh
mkdir -p .nm-test-tmp/before
git archive HEAD^ bin AGENTS.md .agents/skills | tar -x -C .nm-test-tmp/before
```

### Contained safety-fixture setup correction

The initial safety selection stopped at the intended production guard: its reseed fixture was inside the actual source root because TMPDIR was deliberately confined to this worktree.
No source bug or production guard was changed.
The successful retry exported `FM_ROOT_OVERRIDE` to a separate, committed synthetic source fixture within this worktree, making the seeded home a sibling rather than a descendant of its source root.
That fixture was prepared as follows:

```sh
mkdir -p .nm-test-tmp/contained-source
git archive HEAD bin AGENTS.md .agents/skills | tar -x -C .nm-test-tmp/contained-source
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C .nm-test-tmp/contained-source init -q -b main
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C .nm-test-tmp/contained-source add -A
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C .nm-test-tmp/contained-source -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm 'contained fixture source'
```

The retry verified route preservation on reseed and refusals of direct/descendant shared-home retirement, including `--force`.
Other selected checks exercised same-session identity continuity/refusal before stop, native configuration preservation, startup synchronization and stale-nudge refusal, independent four-home backlog writes and configuration resolution, and authenticated contribution-check refresh.

## Scope and boundaries

This is validation of the accepted source-only change, not execution of installation convergence or a live readiness retry.
No installed home, protected private input, diagnostic lab, real account/session, live lifecycle/service, global configuration, or system package was changed or intentionally inspected.
Only new synthetic fixtures were seeded, updated, or removed.
No native GUI or browser surface changed; the relevant end-user evidence is CLI output and persisted synthetic records, so no screenshot was captured.
No lint, formatter, static-analysis, push, PR, CI or pipeline-control phase was run.
All transient fixture/source copies and selection scripts were removed from the worktree; evidence remains here.
