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
if [ "${1:-}" = api ]; then
  shift
  expect_value=0
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$arg" in
      --repo|--repo=*) printf 'unknown flag: --repo\n' >&2; exit 64 ;;
      --method|--header|--raw-field|--field|--input|--jq|--template|--hostname|--cache|--preview) expect_value=1 ;;
      --) break ;;
      --*) ;;
      -?*)
        short=${arg#-}
        while [ -n "$short" ]; do
          option=${short%"${short#?}"}
          short=${short#?}
          case "$option" in
            R) printf 'unknown shorthand flag: R\n' >&2; exit 64 ;;
            X|H|f|F|q|t|p) [ -n "$short" ] || expect_value=1; break ;;
          esac
        done
        ;;
    esac
  done
fi
exit 0
SH
  chmod +x "$STUBS/$tool"
done

for tool in gh gh-axi; do
  status=0
  FM_TEST_FORGE_LOG="$TMP_ROOT/cli-contract.log" "$STUBS/$tool" api graphql --repo kunchenguid/dotfiles \
    >"$TMP_ROOT/cli-contract.out" 2>"$TMP_ROOT/cli-contract.err" || status=$?
  [ "$status" -eq 64 ] || fail "synthetic API consumer must reject the unsupported repository flag"
  FM_TEST_FORGE_LOG="$TMP_ROOT/cli-contract.log" "$STUBS/$tool" api graphql --template --repo --raw-field='query={viewer{login}}' \
    || fail "synthetic API consumer must distinguish owned template data from repository flags"
done
pass "synthetic API boundary enforces the real repository-flag contract with option ownership"

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
expect_allowed gh api --method GET /repos/kunchenguid/dotfiles/commits -f sha=main -f path=bin -F per_page=100
expect_allowed gh api /repos/kunchenguid/dotfiles/commits -f sha=main -F per_page=100 --method GET
expect_allowed gh api /repos/kunchenguid/dotfiles/commits --method=GET --field=sha=main
expect_allowed gh api /repos/kunchenguid/dotfiles/commits -XGET -fsha=main
expect_allowed gh api /repos/kunchenguid/dotfiles/commits -fsha=main -X get
expect_allowed gh api /repos/kunchenguid/dotfiles/commits --method HEAD --raw-field=sha=main
expect_allowed gh api /repos/kunchenguid/dotfiles/commits --method GET --input /dev/null
expect_allowed gh-axi api GET /repos/kunchenguid/dotfiles/commits -f sha=main
expect_refused gh api /repos/kunchenguid/dotfiles/issues -f title=test
expect_refused gh api /repos/kunchenguid/dotfiles/issues --field=title=test
expect_refused gh api /repos/kunchenguid/dotfiles/issues -ftitle=test
expect_allowed gh api /repos/Jin-HoMLee/dotfiles/issues -f title=intended
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

expect_refused gh api graphql -R someuser/somerepo -f 'query=mutation { createRepository(input:{name:"x", ownerId:"id"}) }'
expect_allowed gh api graphql -f 'query={ organization(login:"kunchenguid"){ id } }'
pass "GraphQL reads remain available while mutations and API repository flags are refused"

mutation='query=mutation { addComment(input:{subjectId:"protected-PR-node-id",body:"text"}) { clientMutationId } }'
query='query={ organization(login:"kunchenguid"){ id } }'
for tool in gh gh-axi; do
  expect_refused "$tool" api --method POST graphql -f "$mutation"
  expect_refused "$tool" api -X POST graphql -f "$mutation"
  expect_refused "$tool" api --hostname github.com --method POST graphql -f "$mutation"
  expect_refused "$tool" api -H 'Accept: application/vnd.github+json' graphql -f "$mutation"
  expect_refused "$tool" api -f "$mutation" --method POST graphql
  expect_refused "$tool" api --cache 1h --preview test --jq . graphql -f "$mutation"
  expect_refused "$tool" api --input /dev/null graphql
  expect_allowed "$tool" api --method POST graphql -f "$query"
  expect_allowed "$tool" api -X POST -f "$query" graphql
  expect_allowed "$tool" api -H 'Accept: application/vnd.github+json' graphql -f "$query"
  expect_allowed "$tool" api --hostname github.com --method GET /repos/kunchenguid/dotfiles/commits -f sha=main
  expect_allowed "$tool" api --method POST /repos/Jin-HoMLee/dotfiles/issues -f title=intended
done
expect_refused gh-axi api POST graphql -f "$mutation"
expect_allowed gh-axi api POST graphql -f "$query"
expect_refused gh-axi api POST /repos/kunchenguid/dotfiles/issues -f title=test
pass "API option values do not hide GraphQL endpoints or change permitted reads and fork writes"

for endpoint in graphql /graphql https://api.github.com/graphql \
  'https://API.GITHUB.COM:443/graphql?test=1' http://api.github.com/graphql; do
  for tool in gh gh-axi; do
    expect_refused "$tool" api --method POST "$endpoint" -f "$mutation"
    expect_allowed "$tool" api --method POST "$endpoint" -f "$query"
  done
  expect_refused gh-axi api POST "$endpoint" -f "$mutation"
  expect_allowed gh-axi api POST "$endpoint" -f "$query"
done
pass "equivalent GraphQL destinations preserve mutation refusal and permitted reads"

for tool in gh gh-axi; do
  for option in -f -F --field --raw-field; do
    expect_refused "$tool" api graphql "$option" "$mutation"
    expect_allowed "$tool" api graphql "$option" "$query"
    expect_refused "$tool" api graphql "$option=$mutation"
    expect_allowed "$tool" api graphql "$option=$query"
  done
  expect_refused "$tool" api graphql "-f$mutation"
  expect_refused "$tool" api graphql "-F$mutation"
  expect_allowed "$tool" api graphql "-f$query"
  expect_allowed "$tool" api graphql "-F$query"
  for option in --template --header --jq --cache --preview --hostname; do
    expect_refused "$tool" api graphql -f "$mutation" "$option" 'query=sent'
    expect_refused "$tool" api graphql "$option" 'query=sent' -f "$mutation"
    expect_allowed "$tool" api graphql -f "$query" "$option" "$mutation"
  done
  expect_refused "$tool" api graphql --template='query=sent'
  expect_refused "$tool" api graphql --raw-field=query=@synthetic-not-opened.graphql
  expect_allowed "$tool" api graphql --raw-field='query={viewer{login}}' --template=plain
  expect_allowed "$tool" api graphql --template --input --raw-field="$query"
done
pass "only owning query-field options establish payloads across separate and attached forms"

for tool in gh gh-axi; do
  for flag in --include --silent --paginate --slurp --verbose -i; do
    expect_refused "$tool" api graphql "$flag" --template --help -f "$mutation"
    expect_refused "$tool" api graphql "$flag" --template -h -f "$mutation"
    expect_allowed "$tool" api graphql "$flag" --template --help -f "$query"
    expect_allowed "$tool" api graphql "$flag" --help -f "$mutation"
    expect_allowed "$tool" api graphql "$flag" -h -f "$mutation"
  done
  for option in --template -t --header -H --jq -q --cache --preview -p --hostname; do
    expect_refused "$tool" api graphql --include "$option" --help -f "$mutation"
    expect_allowed "$tool" api graphql --include "$option" --help -f "$query"
  done
  expect_refused "$tool" api graphql --include --template=--help -f "$mutation"
  expect_refused "$tool" api graphql --include -t--help -f "$mutation"
  expect_allowed "$tool" api graphql --include --template --help -f "$mutation" --help
  expect_allowed "$tool" api --help
  expect_allowed "$tool" api /repos/kunchenguid/dotfiles/commits --include --template --help --method GET -f sha=main
  for option in -R --repo; do
    expect_refused "$tool" api graphql "$option" Jin-HoMLee/dotfiles -f "$query"
    expect_refused "$tool" api graphql "$option=Jin-HoMLee/dotfiles" -f "$query"
    expect_refused "$tool" "$option" Jin-HoMLee/dotfiles api graphql -f "$query"
  done
done
pass "API help exemptions respect option ownership and non-consuming boolean flags"

for tool in gh gh-axi; do
  for field_flag in f F; do
    expect_refused "$tool" api /repos/kunchenguid/dotfiles/issues "-i$field_flag" title=x
    expect_refused "$tool" api "-i$field_flag" title=x /repos/kunchenguid/dotfiles/issues
    expect_refused "$tool" api /repos/kunchenguid/dotfiles/issues "-i${field_flag}title=x"
    expect_allowed "$tool" api "-i$field_flag" sha=main /repos/kunchenguid/dotfiles/commits -X GET
    expect_allowed "$tool" api -X GET /repos/kunchenguid/dotfiles/commits "-i${field_flag}=sha=main"
    expect_allowed "$tool" api /repos/Jin-HoMLee/dotfiles/issues "-i$field_flag" title=intended
    expect_refused "$tool" api "-i$field_flag" "$mutation" graphql
    expect_allowed "$tool" api "-i$field_flag" "$query" graphql
  done
  for option in -it -it=--help -it--help -iH; do
    case "$option" in
      -it|-iH)
        expect_refused "$tool" api "$option" --help graphql -f "$mutation"
        expect_allowed "$tool" api "$option" --help graphql -f "$query"
        ;;
      *)
        expect_refused "$tool" api "$option" graphql -f "$mutation"
        expect_allowed "$tool" api "$option" graphql -f "$query"
        ;;
    esac
  done
  expect_refused "$tool" api -iX POST /repos/kunchenguid/dotfiles/issues -f title=x
  expect_allowed "$tool" api -iXGET /repos/kunchenguid/dotfiles/commits -f sha=main
  expect_allowed "$tool" api graphql -ih -f "$mutation"
  expect_allowed "$tool" api graphql --help=true -f "$mutation"
  expect_refused "$tool" api graphql --help=false -f "$mutation"
  expect_refused "$tool" api graphql --future-option --help -f "$query"
  expect_refused "$tool" api /repos/kunchenguid/dotfiles/issues -izf title=x
  expect_refused "$tool" pr create -R kunchenguid/dotfiles --draft --title --help --body text
  expect_refused "$tool" pr create -R kunchenguid/dotfiles -dt --help --body text
  expect_refused "$tool" pr create -R kunchenguid/dotfiles --draft=false --title=--help --body text
  expect_refused "$tool" pr create -R kunchenguid/dotfiles --future-option --help
  expect_allowed "$tool" pr create -R kunchenguid/dotfiles --draft --help
  expect_allowed "$tool" pr create -R kunchenguid/dotfiles -dh
  expect_allowed "$tool" pr create -R Jin-HoMLee/dotfiles --draft --title --help --body text
  expect_allowed "$tool" pr view 48 -R kunchenguid/dotfiles
done
pass "short clusters and non-API help share bounded option ownership without hiding mutations"

input_body="$TMP_ROOT/graphql-input.json"
printf '%s\n' '{"query":"mutation { addComment(input:{subjectId:\"protected-PR-node-id\",body:\"text\"}) { clientMutationId } }"}' >"$input_body"
for tool in gh gh-axi; do
  for endpoint in graphql /graphql https://api.github.com/graphql; do
    expect_refused "$tool" api "$endpoint" --input "$input_body" --template 'query=sent'
    expect_refused "$tool" api "$endpoint" --template 'query=sent' --input="$input_body"
    expect_refused "$tool" api "$endpoint" --input "$input_body" --raw-field="$query"
    expect_refused "$tool" api "$endpoint" --raw-field="$query" --input "$input_body"
    expect_refused "$tool" api "$endpoint" --input "$TMP_ROOT/nonexistent-input.json" --template 'query=sent'
  done
done
pass "unverified GraphQL input bodies remain refused without inspecting their contents"

for endpoint in graphql /graphql https://api.github.com/graphql; do
  policy_graphql_write=$(node "$POLICY" --root "$ROOT" --command "gh api --method POST $endpoint -f '$mutation'")
  case "$policy_graphql_write" in
    deny*) ;;
    *) fail "primary shell policy allowed a GraphQL mutation through $endpoint: $policy_graphql_write" ;;
  esac
  policy_graphql_read=$(node "$POLICY" --root "$ROOT" --command "gh api $endpoint --raw-field='$query' --template '$mutation'")
  [ "$policy_graphql_read" = allow ] || fail "primary shell policy blocked an attached GraphQL read: $policy_graphql_read"
  for tool in gh gh-axi; do
    policy_graphql_write=$(node "$POLICY" --root "$ROOT" --command "$tool api $endpoint --include --template --help -f '$mutation'")
    case "$policy_graphql_write" in
      deny*) ;;
      *) fail "primary shell policy treated a template value as help: $policy_graphql_write" ;;
    esac
    for command in \
      "$tool api $endpoint --include --template --help -f '$query'" \
      "$tool api $endpoint --include --help -f '$mutation'"; do
      policy_graphql_read=$(node "$POLICY" --root "$ROOT" --command "$command")
      [ "$policy_graphql_read" = allow ] || fail "primary shell policy blocked genuine API help or a read: $policy_graphql_read"
    done
  done
done
pass "primary shell policy shares endpoint and query-option classification"

for tool in gh gh-axi; do
  for command in \
    "$tool api /repos/kunchenguid/dotfiles/issues -if title=x" \
    "$tool api -iF '$mutation' graphql" \
    "$tool api graphql -it --help -f '$mutation'" \
    "$tool pr create -R kunchenguid/dotfiles --draft --title --help --body text"; do
    verdict=$(node "$POLICY" --root "$ROOT" --command "$command")
    case "$verdict" in deny*) ;; *) fail "primary policy lost option ownership: $command -> $verdict" ;; esac
  done
  for command in \
    "$tool api -if sha=main /repos/kunchenguid/dotfiles/commits -X GET" \
    "$tool api graphql -it --help -f '$query'" \
    "$tool pr create -R kunchenguid/dotfiles --draft --help" \
    "$tool pr create -R Jin-HoMLee/dotfiles --draft --title --help --body text"; do
    verdict=$(node "$POLICY" --root "$ROOT" --command "$command")
    [ "$verdict" = allow ] || fail "primary policy blocked supported help, read or fork operation: $verdict"
  done
done
pass "primary policy retains option ownership for clustered API and draft PR commands"

parent_shims=$SHIMS
child_shims="$TMP_ROOT/child-shims"
"$GUARD" install-shims "$child_shims" || fail "child guard shims should install"
cat >"$TMP_ROOT/guard-hops.sh" <<'SH'
FM_TEST_GUARD_HOPS=$(( ${FM_TEST_GUARD_HOPS:-0} + 1 ))
export FM_TEST_GUARD_HOPS
if [ "$FM_TEST_GUARD_HOPS" -gt 12 ]; then
  printf 'guard delegation cycled\n' >&2
  exit 97
fi
SH
SHIMS="$child_shims:$parent_shims:$child_shims"
for tool in gh gh-axi; do
  BASH_ENV="$TMP_ROOT/guard-hops.sh" FM_TASK_ID=nested-worker expect_allowed "$tool" pr view 48 --repo kunchenguid/dotfiles
  BASH_ENV="$TMP_ROOT/guard-hops.sh" FM_TASK_ID=nested-worker expect_allowed "$tool" pr create --repo Jin-HoMLee/dotfiles --title intended
  BASH_ENV="$TMP_ROOT/guard-hops.sh" FM_TASK_ID=nested-worker expect_refused "$tool" pr merge 48 --repo kunchenguid/dotfiles
  BASH_ENV="$TMP_ROOT/guard-hops.sh" FM_TASK_ID=nested-worker expect_refused "$tool" api --method POST graphql -f "$mutation"
done
SHIMS=$parent_shims
pass "nested guard directories delegate reads and personal-fork writes without cycling or permitting upstream writes"

expect_refused gh-axi pr create --title accidental
expect_refused gh pr create --title accidental
assert_contains "$(cat "$TMP_ROOT/err")" "must name its exact repository" \
  "omitted-repository refusal did not explain fork-aware default protection"
pass "both GitHub CLIs refuse the omitted-repository PR-create path"

body_url=https://github.com/Jin-HoMLee/dotfiles/issues/1
for tool in gh gh-axi; do
  for option in --title --body; do
    expect_refused "$tool" pr create "$option=$body_url"
    expect_refused "$tool" pr create "$option" "$body_url"
    expect_allowed "$tool" pr create -R Jin-HoMLee/dotfiles "$option=$body_url"
    expect_refused "$tool" pr create -R kunchenguid/dotfiles "$option=$body_url"
    for command in \
      "$tool pr create --title=Fix $option=$body_url" \
      "$tool pr create -R '' $option=$body_url" \
      "$tool pr create --unproved-option $body_url"; do
      verdict=$(node "$POLICY" --root "$ROOT" --command "$command")
      case "$verdict" in deny*) ;; *) fail "primary policy used option data as a repository: $verdict" ;; esac
    done
  done
  expect_refused "$tool" pr create --title=Fix --body="$body_url"
  expect_refused "$tool" pr create -R '' --body="$body_url"
  expect_refused "$tool" pr create -R Jin-HoMLee/dotfiles --unproved-option "$body_url"
  expect_allowed "$tool" pr create --help
  expect_allowed "$tool" pr view 48 -R kunchenguid/dotfiles --template "$body_url"
  verdict=$(node "$POLICY" --root "$ROOT" --command "$tool pr create -R Jin-HoMLee/dotfiles --title=Fix --body=$body_url")
  [ "$verdict" = allow ] || fail "primary policy blocked a proved fork destination with URL-valued content"
done
pass "only owned explicit selectors establish mutation targets, never attached title or body data"

for tool in gh gh-axi; do
  for top in pr issue; do
    case "$top" in pr) path=pull ;; issue) path=issues ;; esac
    for owner in kunchenguid Jin-HoMLee; do
      url="https://github.com/$owner/dotfiles/$path/48"
      expect_refused "$tool" "$top" close "$url" -R Jin-HoMLee/dotfiles
      expect_refused "$tool" "$top" close "$url" -R kunchenguid/firstmate
      verdict=$(node "$POLICY" --root "$ROOT" --command "$tool $top close $url -R Jin-HoMLee/dotfiles")
      case "$verdict" in deny*) ;; *) fail "primary policy ignored an overriding positional selector: $verdict" ;; esac
      expect_allowed "$tool" "$top" view "$url" -R Jin-HoMLee/dotfiles
      expect_allowed "$tool" "$top" close "$url" -R Jin-HoMLee/dotfiles --help
    done
    expect_allowed "$tool" "$top" close 48 -R Jin-HoMLee/dotfiles
    expect_refused "$tool" "$top" close 48 -R kunchenguid/dotfiles
    expect_allowed "$tool" "$top" create -R Jin-HoMLee/dotfiles --title=Fix --body="$body_url"
  done
done
pass "PR and issue URL mutations refuse overriding selectors while identifiers, URL-valued content and reads remain supported"

for command in \
  'REPO=kunchenguid/dotfiles; gh pr create -R "$REPO" --title=Fix' \
  'Q=mutation; gh api graphql -f "query=$Q"' \
  'REPO=Jin-HoMLee/dotfiles; gh pr create -R "$REPO" --title=Fix'; do
  verdict=$(node "$POLICY" --root "$ROOT" --command "$command")
  case "$verdict" in deny*) ;; *) fail "unproved GitHub arguments received a read/write exemption: $verdict" ;; esac
done
pass "primary GitHub argument expansion does not establish a destination or verified query"

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

expect_refused gh repo create myrepo
expect_allowed gh repo create myorg/myrepo
expect_refused gh repo create kunchenguid/newrepo
expect_refused gh repo create KUNCHENGUID/newrepo
expect_allowed gh repo create Jin-HoMLee/myrepo --source kunchenguid/dotfiles
expect_allowed gh repo create Jin-HoMLee/myrepo --template kunchenguid/dotfiles
expect_allowed gh repo create Jin-HoMLee/myrepo --source=kunchenguid/dotfiles
expect_allowed gh repo create Jin-HoMLee/myrepo -s kunchenguid/dotfiles
expect_allowed gh repo create myorg/myrepo --source kunchenguid/dotfiles
expect_refused gh repo create kunchenguid/newrepo --source Jin-HoMLee/dotfiles
pass "gh repo create keeps protected --source/--template inputs distinct from its destination"

expect_allowed gh repo unarchive someuser/somerepo
expect_refused gh repo unarchive kunchenguid/dotfiles
pass "gh repo unarchive mirrors archive: non-protected destinations are allowed"

expect_refused gh repo create kunchenguid/newrepo -h https://example.com
expect_refused gh repo create -h https://example.com kunchenguid/newrepo
expect_refused gh repo edit kunchenguid/dotfiles -h https://example.com
expect_allowed gh repo create Jin-HoMLee/myrepo -h https://example.com
expect_allowed gh repo create --help
expect_allowed gh repo edit --help
pass "gh repo create/edit parse -h as --homepage, not help, while --help stays allowed"

expect_refused gh repo edit -h https://github.com/someuser/somerepo kunchenguid/dotfiles
expect_refused gh repo edit --homepage https://github.com/someuser/somerepo kunchenguid/dotfiles
expect_refused gh repo edit --default-branch feature/x kunchenguid/dotfiles
expect_refused gh repo edit -h https://github.com/someuser/somerepo
expect_allowed gh repo create Jin-HoMLee/myrepo --source https://github.com/kunchenguid/dotfiles
expect_allowed gh repo create Jin-HoMLee/myrepo --template https://github.com/kunchenguid/dotfiles
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

policy_repo_own=$(node "$POLICY" --root "$ROOT" --command 'gh repo create Jin-HoMLee/myrepo')
[ "$policy_repo_own" = allow ] || fail "primary shell policy blocked own-account repo creation: $policy_repo_own"
policy_repo_protected=$(node "$POLICY" --root "$ROOT" --command 'gh repo create kunchenguid/newrepo')
case "$policy_repo_protected" in
  deny*) ;;
  *) fail "primary shell policy allowed a protected repo creation: $policy_repo_protected" ;;
esac
policy_create_source=$(node "$POLICY" --root "$ROOT" --command 'gh repo create Jin-HoMLee/myrepo --source kunchenguid/dotfiles')
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

push_home="$TMP_ROOT/push-policy-home"
protected_clone="$push_home/projects/upstream"
push_stubs="$TMP_ROOT/push-stubs"
push_log="$TMP_ROOT/mock-push.log"
real_git=$(command -v git)
fm_git_init_commit "$push_home"
fm_git_init_commit "$protected_clone"
git -C "$push_home" remote add origin git@github.com:Jin-HoMLee/dotfiles.git
git -C "$protected_clone" remote add origin git@github.com:kunchenguid/dotfiles.git
fork_url=https://github.com/Jin-HoMLee/dotfiles.git
git -C "$protected_clone" config 'url.git@github.com:kunchenguid/dotfiles.git.pushInsteadOf' "$fork_url"
mkdir -p "$push_stubs"
: >"$push_log"
cat >"$push_stubs/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = push ]; then
    printf 'mock push: %s\n' "$*" >>"$FM_TEST_PUSH_LOG"
    exit 0
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
chmod +x "$push_stubs/git"

expect_push_policy() {
  local expected=$1 command=$2 verdict before
  before=$(wc -l <"$push_log" | tr -d ' ')
  verdict=$(
    cd "$push_home" || exit 1
    FM_TEST_REAL_GIT="$real_git" FM_TEST_PUSH_LOG="$push_log" PATH="$push_stubs:$PATH" \
      node "$POLICY" --root "$ROOT" --command "$command"
  ) || fail "primary push policy did not return a decision"
  case "$expected/$verdict" in
    deny/deny*) ;;
    allow/allow)
      (
        cd "$push_home" || exit 1
        FM_TEST_REAL_GIT="$real_git" FM_TEST_PUSH_LOG="$push_log" PATH="$push_stubs:$PATH" \
          bash -c "$command"
      ) >"$TMP_ROOT/mock-push.out" 2>"$TMP_ROOT/mock-push.err" || fail "allowed mock push did not execute: $command"
      before=$((before + 1))
      ;;
    *) fail "primary push policy expected $expected for $command, got $verdict" ;;
  esac
  [ "$(wc -l <"$push_log" | tr -d ' ')" -eq "$before" ] || fail "unexpected mock push count for $command"
}

for command in \
  '(cd projects/upstream && git -C . push origin HEAD)' \
  '(cd projects/upstream && git -C. push origin HEAD)' \
  '(cd projects/upstream && git push origin HEAD)' \
  'env -C projects/upstream git push origin HEAD' \
  'env -Cprojects/upstream git -C . push origin HEAD' \
  'env --chdir projects/upstream git push origin HEAD' \
  'env --chdir=projects/upstream git push origin HEAD' \
  'env -iC projects/upstream git push origin HEAD' \
  'if true; then env -C projects/upstream git -C . push origin HEAD; fi' \
  "env -C '$protected_clone' sh -c 'git -C . push origin HEAD'" \
  "git -C '$protected_clone' push origin HEAD" \
  "git -C '$protected_clone' -C . push origin HEAD" \
  "git -C'$protected_clone' -C. push origin HEAD" \
  "git -C '$protected_clone' -C '' push origin HEAD" \
  "git -C '$push_home' -C projects/upstream push origin HEAD" \
  "(cd projects/upstream && git push '$fork_url' HEAD)" \
  "env -C projects/upstream git push '$fork_url' HEAD" \
  "git -C '$protected_clone' -C . push '$fork_url' HEAD"; do
  expect_push_policy deny "$command"
done
for command in \
  'git -C . push origin HEAD' \
  'env FIXTURE=1 git -C . push origin HEAD' \
  "(cd projects/upstream && git -C '$push_home' push origin HEAD)" \
  "(cd projects/upstream && git -C'$push_home' push origin HEAD)" \
  "git -C '$push_home' -C . push origin HEAD" \
  "git -C '$protected_clone' -C '$push_home' push origin HEAD" \
  "(cd projects/upstream && git -C '$push_home' -C . push '$fork_url' HEAD)" \
  "git -C '$push_home' push '$fork_url' HEAD"; do
  expect_push_policy allow "$command"
done
for command in \
  '(cd projects/upstream && git -C . status --short)' \
  'env -C projects/upstream git status --short' \
  "env -C projects/upstream git -C '$push_home' push origin HEAD" \
  "env --chdir=projects/upstream git -C '$push_home' push origin HEAD"; do
  verdict=$(cd "$push_home" && node "$POLICY" --root "$ROOT" --command "$command")
  [ "$verdict" = allow ] || fail "primary policy blocked a read or an independently anchored fork push: $verdict"
done
pass "primary push policy refuses unresolved directory context while retaining reads and anchored fork pushes"

for flag in -C -Cattached; do
  case "$flag" in
    -C) directory_args=(-C "$protected_clone" -C .) ;;
    *) directory_args=("-C$protected_clone" -C.) ;;
  esac
  for destination in origin "$fork_url"; do
    status=0
    (cd "$push_home" && "$GUARD" check git "${directory_args[@]}" push "$destination" HEAD) \
      >"$TMP_ROOT/sequential.out" 2>"$TMP_ROOT/sequential.err" || status=$?
    [ "$status" -eq 2 ] || fail "shared guard resolved repeated $flag against the wrong repository"
  done
done
(cd "$push_home" && "$GUARD" check git -C "$push_home" -C . push origin HEAD) \
  || fail "shared guard rejected sequential -C in a personal fork"
(cd "$push_home" && "$GUARD" check git -C "$protected_clone" -C "$push_home" push "$fork_url" HEAD) \
  || fail "shared guard rejected an absolute -C reset to a personal fork"
pass "shared push classification preserves sequential directory and URL-rewrite configuration"

expect_shared_push_refused() {
  local status=0
  "$GUARD" check git "$@" >"$TMP_ROOT/single-target.out" 2>"$TMP_ROOT/single-target.err" || status=$?
  [ "$status" -eq 2 ] || fail "shared guard accepted an unproved or multiple push destination: $*"
}

rewrite_repos=()
for rewrite in insteadOf pushInsteadOf; do
  rewrite_repo="$TMP_ROOT/rewrite-$rewrite"
  rewrite_repos+=("$rewrite_repo")
  fm_git_init_commit "$rewrite_repo"
  git -C "$rewrite_repo" remote add origin "$fork_url"
  git -C "$rewrite_repo" config "url.git@github.com:kunchenguid.$rewrite" https://github.com/Jin-HoMLee
  expect_shared_push_refused -C "$rewrite_repo" push "$fork_url" HEAD
  expect_shared_push_refused -C "$rewrite_repo" push origin HEAD
  expect_push_policy deny "git -C '$rewrite_repo' push '$fork_url' HEAD"
  expect_push_policy deny "git -C '$rewrite_repo' push origin HEAD"
  safe_rewrite_repo="$TMP_ROOT/safe-rewrite-$rewrite"
  fm_git_init_commit "$safe_rewrite_repo"
  git -C "$safe_rewrite_repo" remote add origin https://github.com/rewrite-source/dotfiles.git
  git -C "$safe_rewrite_repo" config "url.git@github.com:Jin-HoMLee.$rewrite" https://github.com/rewrite-source
  expect_shared_push_refused -C "$safe_rewrite_repo" push https://github.com/rewrite-source/dotfiles.git HEAD
  expect_push_policy allow "git -C '$safe_rewrite_repo' push origin HEAD"
done
pass "direct URL rewrites are unsupported while named remotes use Git's complete effective destination"

multi_repos=()
for destinations in protected mixed personal duplicate; do
  multi_repo="$TMP_ROOT/multi-$destinations"
  multi_repos+=("$multi_repo")
  fm_git_init_commit "$multi_repo"
  git -C "$multi_repo" remote add origin "$fork_url"
  case "$destinations" in
    protected) first=git@github.com:kunchenguid/firstmate.git; second=git@github.com:kunchenguid/dotfiles.git ;;
    mixed) first=$fork_url; second=git@github.com:kunchenguid/dotfiles.git ;;
    personal) first=$fork_url; second=git@github.com:Jin-HoMLee/firstmate.git ;;
    duplicate) first=$fork_url; second=$fork_url ;;
  esac
  git -C "$multi_repo" config --add remote.origin.pushurl "$first"
  git -C "$multi_repo" config --add remote.origin.pushurl "$second"
  expect_shared_push_refused -C "$multi_repo" push origin HEAD
  expect_push_policy deny "git -C '$multi_repo' push origin HEAD"
done
pass "complete multi-push destination sets are refused, regardless of ordering or ownership"

for command in \
  'OWNER=kunchenguid; git push "https://github.com/${OWNER}/dotfiles.git" HEAD' \
  'REMOTE=origin; git push "$REMOTE" HEAD' \
  'git push "$(printf origin)" HEAD' \
  'git push https://github.com/{Jin-HoMLee,kunchenguid}/dotfiles.git HEAD' \
  "REPO='$push_home'; git -C \"\$REPO\" push origin HEAD" \
  'nice -10 git push "https://github.com/${OWNER}/dotfiles.git" HEAD'; do
  expect_push_policy deny "$command"
done
expect_shared_push_refused -C "$push_home" push 'https://github.com/${OWNER}/dotfiles.git' HEAD
expect_shared_push_refused -C "$push_home" push '' HEAD
expect_shared_push_refused -C "$push_home" push --repo=origin --repo=origin HEAD
expect_shared_push_refused -C "$push_home" push origin --repo=origin HEAD
expect_shared_push_refused -C "$protected_clone" push origin -o --help HEAD
expect_shared_push_refused -C "$protected_clone" push --unproved-option --help origin HEAD
for command in \
  'OWNER=kunchenguid; git ls-remote "https://github.com/${OWNER}/dotfiles.git"' \
  'git push --help' \
  'git status --help'; do
  verdict=$(cd "$push_home" && node "$POLICY" --root "$ROOT" --command "$command")
  [ "$verdict" = allow ] || fail "literal-destination restriction blocked a safe read or genuine help: $verdict"
done
expect_push_policy allow "git push \"$fork_url\" HEAD"
pass "primary pushes require literal arguments and explicit proved destinations without evaluating expansions"

for command in \
  'verb=push; git "$verb" https://github.com/kunchenguid/dotfiles.git HEAD' \
  'verb=status; git "$verb" --short' \
  'verb=push; git -C . "$verb" origin HEAD' \
  'git "$(printf push)" origin HEAD' \
  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=git@github.com:kunchenguid/dotfiles.git git push origin HEAD' \
  'env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=git@github.com:kunchenguid/dotfiles.git git push origin HEAD' \
  "GIT_DIR='$protected_clone/.git' git push origin HEAD" \
  "HOME='$TMP_ROOT/unproved-home' git push origin HEAD" \
  "GIT_CONFIG_COUNT=1 sh -c 'git -C \"$push_home\" push origin HEAD'" \
  'env --unset=GIT_CONFIG_COUNT git push origin HEAD' \
  'env -i git push origin HEAD' \
  "env -iC projects/upstream git -C '$push_home' push origin HEAD" \
  'sudo git push origin HEAD'; do
  expect_push_policy deny "$command"
done
for command in \
  'path=README.md; git status --short "$path"' \
  'branch=main; git log -1 "$branch"' \
  'path=push; git -c user.name=push status --short "$path"' \
  'GIT_CONFIG_COUNT=1 git status --short' \
  'env -i git status --short' \
  'git --help'; do
  verdict=$(cd "$push_home" && node "$POLICY" --root "$ROOT" --command "$command")
  [ "$verdict" = allow ] || fail "proved literal Git read or help command was refused: $verdict"
done
expect_push_policy allow 'FIXTURE=1 git push origin HEAD'
expect_push_policy allow 'git push origin HEAD'
pass "Git requires a proved literal subcommand and refuses unproved push environments without evaluating them"

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
"$GUARD" check git -C "$repo" -c remote.pushDefault=origin push origin \
  || fail "git -c remote.pushDefault with an explicit local remote should be allowed"
"$GUARD" check git -C "$repo" -c branch.main.pushRemote=origin push origin \
  || fail "git -c branch.<name>.pushRemote with an explicit local remote should be allowed"
status=0
"$GUARD" check git -C "$repo" push >"$TMP_ROOT/default.out" 2>"$TMP_ROOT/default.err" || status=$?
[ "$status" -eq 2 ] || fail "git push without an explicit destination must refuse defaults"
"$GUARD" check git -C "$repo" push origin \
  || fail "git push to a local remote without -c should be allowed"
pass "git -c config overrides are honored for explicit destinations and defaults are refused"

for flag in "--git-dir=$repo/.git" "--work-tree=$repo" "--namespace=test"; do
  status=0
  "$GUARD" check git -C "$repo" "$flag" push origin main:main \
    >"$TMP_ROOT/gitdir.out" 2>"$TMP_ROOT/gitdir.err" || status=$?
  [ "$status" -eq 2 ] || fail "git $flag before push should fail closed, got $status"
done
status=0
"$GUARD" check git -C "$repo" --git-dir "$repo/.git" push origin main:main \
  >"$TMP_ROOT/gitdir2.out" 2>"$TMP_ROOT/gitdir2.err" || status=$?
[ "$status" -eq 2 ] || fail "git --git-dir two-arg form before push should fail closed, got $status"
pass "git --git-dir/--work-tree/--namespace before push fail closed"

status=0
MYURL=git@github.com:kunchenguid/dotfiles.git "$GUARD" check git -C "$repo" --config-env=remote.origin.url=MYURL push origin main:main \
  >"$TMP_ROOT/gitce1.out" 2>"$TMP_ROOT/gitce1.err" || status=$?
[ "$status" -eq 2 ] || fail "git --config-env remote.origin.url override should be refused, got $status"
status=0
MYURL=git@github.com:kunchenguid/dotfiles.git "$GUARD" check git -C "$repo" --config-env remote.origin.url=MYURL push origin main:main \
  >"$TMP_ROOT/gitce2.out" 2>"$TMP_ROOT/gitce2.err" || status=$?
[ "$status" -eq 2 ] || fail "git --config-env two-arg remote.origin.url override should be refused, got $status"
status=0
MYURL=git@github.com:kunchenguid/dotfiles.git "$GUARD" check git -C "$repo" --config-env=remote.origin.pushUrl=MYURL push origin main:main \
  >"$TMP_ROOT/gitce3.out" 2>"$TMP_ROOT/gitce3.err" || status=$?
[ "$status" -eq 2 ] || fail "git --config-env mixed-case destination key should be refused, got $status"
status=0
MYURL=git@github.com:kunchenguid/dotfiles.git "$GUARD" check git -C "$repo" --config-env remote.origin.pushUrl=MYURL push origin main:main \
  >"$TMP_ROOT/gitce4.out" 2>"$TMP_ROOT/gitce4.err" || status=$?
[ "$status" -eq 2 ] || fail "git --config-env two-arg mixed-case destination key should be refused, got $status"
status=0
MYNAME='test' "$GUARD" check git -C "$repo" --config-env=user.name=MYNAME push origin main:main \
  >"$TMP_ROOT/gitce5.out" 2>"$TMP_ROOT/gitce5.err" || status=$?
[ "$status" -eq 2 ] || fail "variable-derived --config-env options are unsupported even for a harmless key"
pass "git --config-env options are refused without evaluating variable-derived configuration"

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
status=0
"$GUARD" check git -C "$repo" -c 'url.git@github.com:.insteadOf=https://github.com/' push https://github.com/someuser/somerepo.git main:main \
  >"$TMP_ROOT/safe-rewrite.out" 2>"$TMP_ROOT/safe-rewrite.err" || status=$?
[ "$status" -eq 2 ] || fail "rewrite-dependent direct URLs must be refused even when the replacement is unprotected"
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

PLUGIN="$ROOT/.opencode/plugins/fm-primary-upstream-write-check.js" WORKTREE="$primary" node --input-type=module <<'JS' || fail "OpenCode upstream-write hooks should enforce the existing policy on both runtimes"
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const root = process.env.WORKTREE;
assert.equal(mod.default.id, "fm.primary.upstream-write-check");
assert.equal(mod.default.server, mod.FmPrimaryUpstreamWriteCheck);
const legacy = await mod.FmPrimaryUpstreamWriteCheck({ directory: root, worktree: root });
let hook;
mod.default.setup({
  location: { project: { directory: root } },
  tool: { hook: (name, handler) => { assert.equal(name, "execute.before"); hook = handler; } },
});
assert.equal(typeof hook, "function");
const runtimes = [
  { call: (command) => legacy["tool.execute.before"]({ tool: "bash" }, { args: { command } }),
    other: (tool, command) => legacy["tool.execute.before"]({ tool }, { args: { command } }) },
  { call: (command) => hook({ tool: "shell", input: { command } }),
    other: (tool, command) => hook({ tool, input: { command } }) },
];
for (const runtime of runtimes) {
  await assert.rejects(runtime.call("gh pr merge 48 --repo kunchenguid/dotfiles"), /protected-upstream-write/);
  await assert.rejects(runtime.call(`gh api --method POST graphql -f 'query=mutation { addComment(input:{subjectId:"protected-id",body:"text"}) { clientMutationId } }'`), /protected-upstream-write/);
  await assert.rejects(runtime.call(`gh api graphql --include --template --help -f 'query=mutation { addComment(input:{subjectId:"protected-id",body:"text"}) { clientMutationId } }'`), /protected-upstream-write/);
  await runtime.call("gh api graphql --include --help");
  await runtime.call("gh api graphql --include --template --help --raw-field='query={viewer{login}}'");
  await runtime.call("gh pr view 48 --repo kunchenguid/dotfiles");
  await runtime.call(`gh api --method POST graphql -f 'query={ organization(login:"kunchenguid"){ id } }'`);
  await assert.rejects(runtime.call(`gh api --method POST https://api.github.com/graphql -f 'query=mutation { addComment(input:{subjectId:"protected-id",body:"text"}) { clientMutationId } }'`), /protected-upstream-write/);
  await assert.rejects(runtime.call("gh api /graphql --input synthetic-not-opened.json --template 'query=sent'"), /protected-upstream-write/);
  await runtime.call("gh api https://api.github.com/graphql --raw-field='query={viewer{login}}' --template 'query=mutation'");
  await runtime.call("gh pr create --repo Jin-HoMLee/dotfiles --title intended");
  for (const tool of ["read", "mcp_runner"]) await runtime.other(tool, "gh pr merge 48 --repo kunchenguid/dotfiles");
  await runtime.call(undefined);
}
console.log("ok - OpenCode 1 and 2 upstream-write hooks block protected writes and preserve reads and personal-fork writes");
JS

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

graphql_home="$TMP_ROOT/graphql-auth-home"
printf '%s\n' 'Add exactly one test comment in kunchenguid/dotfiles.' >"$TMP_ROOT/graphql-words.txt"
for tool in gh gh-axi; do
  for endpoint in graphql /graphql https://api.github.com/graphql; do
    for grant in kunchenguid/dotfiles kunchenguid/firstmate; do
      for binding in none -R --repo; do
        binding_args=()
        [ "$binding" = none ] || binding_args=("$binding" kunchenguid/dotfiles)
        before=$(wc -l <"$LOG" | tr -d ' ')
        status=0
        FM_HOME="$graphql_home/$tool" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
          "$GUARD" authorize --repo "$grant" --captain-words-file "$TMP_ROOT/graphql-words.txt" -- \
          "$tool" api --method POST "$endpoint" "${binding_args[@]+"${binding_args[@]}"}" -f "$mutation" \
          >"$TMP_ROOT/graphql-auth.out" 2>"$TMP_ROOT/graphql-auth.err" || status=$?
        [ "$status" -eq 2 ] || fail "unsupported GraphQL mutation was authorized through $endpoint"
        [ "$(wc -l <"$LOG" | tr -d ' ')" -eq "$before" ] || fail "GraphQL mutation reached the underlying CLI"
        [ ! -d "$graphql_home/$tool/state/upstream-write-authorizations" ] || fail "unsupported GraphQL mutation created an operation grant record"
      done
    done
    expect_refused "$tool" api "$endpoint" -f "$mutation"
    expect_allowed "$tool" api "$endpoint" -f "$query"
  done
  before=$(wc -l <"$LOG" | tr -d ' ')
  status=0
  FM_TASK_ID=nested-worker FM_HOME="$graphql_home/$tool" FM_TEST_FORGE_LOG="$LOG" \
    BASH_ENV="$TMP_ROOT/guard-hops.sh" PATH="$child_shims:$parent_shims:$STUBS:/usr/bin:/bin" \
    "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$words" -- \
    "$tool" api --method POST /repos/kunchenguid/dotfiles/issues -f title=test \
    >"$TMP_ROOT/nested-worker.out" 2>"$TMP_ROOT/nested-worker.err" || status=$?
  [ "$status" -eq 2 ] || fail "nested workers must not authorize upstream writes"
  [ "$(wc -l <"$LOG" | tr -d ' ')" = "$before" ] || fail "nested worker authorization reached the forge"
done
pass "GraphQL mutations remain unsupported under every grant while reads and worker authority boundaries remain intact"

for tool in gh gh-axi; do
  bounded_home="$TMP_ROOT/bounded-auth-$tool"
  for operation in api-field api-template pr-draft; do
    case "$operation" in
      api-field)
        operation_args=(api /repos/kunchenguid/dotfiles/issues -if title=test)
        operation_words='Open exactly one test issue in kunchenguid/dotfiles.'
        ;;
      api-template)
        operation_args=(api /repos/kunchenguid/dotfiles/issues -it --help -f title=test)
        operation_words='Open exactly one test issue in kunchenguid/dotfiles.'
        ;;
      pr-draft)
        operation_args=(pr create -R kunchenguid/dotfiles --draft --title --help --body text)
        operation_words='Create one draft PR titled --help with body text in kunchenguid/dotfiles.'
        ;;
    esac
    printf '%s\n' "$operation_words" >"$TMP_ROOT/bounded-words.txt"
    before=$(wc -l <"$LOG" | tr -d ' ')
    FM_HOME="$bounded_home" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:/usr/bin:/bin" \
      "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$TMP_ROOT/bounded-words.txt" -- \
      "$tool" "${operation_args[@]}" || fail "supported $operation lost exact authorization"
    [ "$(wc -l <"$LOG" | tr -d ' ')" -eq $((before + 1)) ] || fail "authorized $operation did not execute once"
  done
  [ "$(find "$bounded_home/state/upstream-write-authorizations" -name '*.record' -type f | wc -l | tr -d ' ')" = 3 ] \
    || fail "each bounded option authorization must be audited"
  for record in "$bounded_home/state/upstream-write-authorizations/"*.record; do
    assert_contains "$(cat "$record")" 'repo=kunchenguid/dotfiles' "bounded option audit omitted the exact repository"
    assert_contains "$(cat "$record")" 'result=exit-0' "bounded option audit omitted mock execution success"
  done
done

push_auth_home="$TMP_ROOT/sequential-push-auth"
printf '%s\n' 'Push HEAD to origin in kunchenguid/dotfiles.' >"$TMP_ROOT/push-words.txt"
for destination in origin "$fork_url"; do
  before=$(wc -l <"$push_log" | tr -d ' ')
  status=0
  (cd "$push_home" && FM_HOME="$push_auth_home" FM_TEST_REAL_GIT="$real_git" FM_TEST_PUSH_LOG="$push_log" PATH="$push_stubs:$PATH" \
    "$GUARD" authorize --repo kunchenguid/not-dotfiles --captain-words-file "$TMP_ROOT/push-words.txt" -- \
    git -C "$protected_clone" -C . push "$destination" HEAD) \
    >"$TMP_ROOT/sequential-auth.out" 2>"$TMP_ROOT/sequential-auth.err" || status=$?
  [ "$status" -eq 2 ] || fail "sequential directory authorization accepted the wrong protected repository"
  [ "$(wc -l <"$push_log" | tr -d ' ')" -eq "$before" ] || fail "out-of-scope sequential push executed"
done
before=$(wc -l <"$push_log" | tr -d ' ')
(cd "$push_home" && FM_HOME="$push_auth_home" FM_TEST_REAL_GIT="$real_git" FM_TEST_PUSH_LOG="$push_log" PATH="$push_stubs:$PATH" \
  "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$TMP_ROOT/push-words.txt" -- \
  git -C "$protected_clone" -C . push origin HEAD) || fail "sequential -C must support exact audited git authorization"
[ "$(wc -l <"$push_log" | tr -d ' ')" -eq $((before + 1)) ] || fail "authorized sequential push did not execute once"
record=$(find "$push_auth_home/state/upstream-write-authorizations" -name '*.record' -type f -print | head -n 1)
[ -n "$record" ] || fail "sequential push authorization omitted its audit record"
assert_contains "$(cat "$record")" 'repo=kunchenguid/dotfiles' "sequential push audit recorded the wrong repository"
assert_contains "$(cat "$record")" 'result=exit-0' "sequential push audit did not record mock execution"
pass "bounded option and sequential directory operations preserve exact authorization and auditing"

expect_unsupported_authorization() {
  local home=$1 grant=$2 status=0 forge_before push_before
  shift 2
  forge_before=$(wc -l <"$LOG" | tr -d ' ')
  push_before=$(wc -l <"$push_log" | tr -d ' ')
  FM_HOME="$home" FM_TEST_FORGE_LOG="$LOG" FM_TEST_REAL_GIT="$real_git" FM_TEST_PUSH_LOG="$push_log" \
    PATH="$push_stubs:$STUBS:$PATH" \
    "$GUARD" authorize --repo "$grant" --captain-words-file "$words" -- "$@" \
    >"$TMP_ROOT/unsupported-auth.out" 2>"$TMP_ROOT/unsupported-auth.err" || status=$?
  [ "$status" -eq 2 ] || fail "an unsupported destination was authorized: $*"
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq "$forge_before" ] || fail "unsupported authorization reached the forge"
  [ "$(wc -l <"$push_log" | tr -d ' ')" -eq "$push_before" ] || fail "unsupported authorization executed a push"
  [ ! -d "$home/state/upstream-write-authorizations" ] || fail "unsupported authorization created an operation grant record"
}
for tool in gh gh-axi; do
  expect_unsupported_authorization "$TMP_ROOT/body-auth-missing-$tool" kunchenguid/dotfiles \
    "$tool" pr create --title=Fix --body="$body_url"
  expect_unsupported_authorization "$TMP_ROOT/body-auth-mismatch-$tool" kunchenguid/firstmate \
    "$tool" pr create -R kunchenguid/dotfiles --title=Fix --body="$body_url"
  body_home="$TMP_ROOT/body-auth-supported-$tool"
  printf '%s\n' 'Create one PR titled Fix in kunchenguid/dotfiles with the supplied body.' >"$TMP_ROOT/body-words.txt"
  before=$(wc -l <"$LOG" | tr -d ' ')
  FM_HOME="$body_home" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:$PATH" \
    "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$TMP_ROOT/body-words.txt" -- \
    "$tool" pr create -R kunchenguid/dotfiles --title=Fix --body="$body_url" \
    || fail "owned body data must not override an exact supported grant"
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq $((before + 1)) ] || fail "explicit body-valued authorization did not execute once"
  record=$(find "$body_home/state/upstream-write-authorizations" -name '*.record' -type f -print | head -n 1)
  [ -n "$record" ] || fail "explicit body-valued authorization omitted its audit record"
  assert_contains "$(cat "$record")" 'repo=kunchenguid/dotfiles' "body-valued authorization recorded content as its target"
  assert_contains "$(cat "$record")" 'result=exit-0' "body-valued authorization omitted execution success"
done
for tool in gh gh-axi; do
  for top in pr issue; do
    case "$top" in pr) path=pull ;; issue) path=issues ;; esac
    for grant in kunchenguid/dotfiles kunchenguid/firstmate; do
      expect_unsupported_authorization "$TMP_ROOT/url-auth-$tool-$top-${grant##*/}" "$grant" \
        "$tool" "$top" close "https://github.com/kunchenguid/dotfiles/$path/48" -R "$grant"
    done
    expect_unsupported_authorization "$TMP_ROOT/identifier-mismatch-$tool-$top" kunchenguid/firstmate \
      "$tool" "$top" close 48 -R kunchenguid/dotfiles
    identifier_home="$TMP_ROOT/identifier-auth-$tool-$top"
    printf 'Close %s 48 in kunchenguid/dotfiles.\n' "$top" >"$TMP_ROOT/identifier-words.txt"
    before=$(wc -l <"$LOG" | tr -d ' ')
    FM_HOME="$identifier_home" FM_TEST_FORGE_LOG="$LOG" PATH="$STUBS:$PATH" \
      "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$TMP_ROOT/identifier-words.txt" -- \
      "$tool" "$top" close 48 -R kunchenguid/dotfiles || fail "ordinary identifier operation lost exact authorization"
    [ "$(wc -l <"$LOG" | tr -d ' ')" -eq $((before + 1)) ] || fail "ordinary identifier authorization did not execute once"
    record=$(find "$identifier_home/state/upstream-write-authorizations" -name '*.record' -type f -print | head -n 1)
    [ -n "$record" ] || fail "ordinary identifier authorization omitted an audit record"
    assert_contains "$(cat "$record")" 'repo=kunchenguid/dotfiles' "ordinary identifier audit named the wrong repository"
    assert_contains "$(cat "$record")" 'result=exit-0' "ordinary identifier audit omitted execution success"
  done
done
pass "exact grants cannot authorize positional URL selectors but retain audited identifier operations"

for rewrite_repo in "${rewrite_repos[@]}"; do
  expect_unsupported_authorization "$rewrite_repo/direct-auth" kunchenguid/dotfiles \
    git -C "$rewrite_repo" push "$fork_url" HEAD
  expect_unsupported_authorization "$rewrite_repo/mismatched-auth" kunchenguid/firstmate \
    git -C "$rewrite_repo" push origin HEAD
  before=$(wc -l <"$push_log" | tr -d ' ')
  FM_HOME="$rewrite_repo/named-auth" FM_TEST_REAL_GIT="$real_git" FM_TEST_PUSH_LOG="$push_log" PATH="$push_stubs:$PATH" \
    "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$TMP_ROOT/push-words.txt" -- \
    git -C "$rewrite_repo" push origin HEAD || fail "Git-resolved single named destination lost exact authorization"
  [ "$(wc -l <"$push_log" | tr -d ' ')" -eq $((before + 1)) ] || fail "named rewritten authorization did not execute once"
  record=$(find "$rewrite_repo/named-auth/state/upstream-write-authorizations" -name '*.record' -type f -print | head -n 1)
  [ -n "$record" ] || fail "named rewritten authorization omitted its audit record"
  assert_contains "$(cat "$record")" 'repo=kunchenguid/dotfiles' "named rewrite audit omitted its complete destination"
  assert_contains "$(cat "$record")" 'result=exit-0' "named rewrite audit omitted execution success"
done
for multi_repo in "${multi_repos[@]}"; do
  for grant in kunchenguid/firstmate kunchenguid/dotfiles; do
    expect_unsupported_authorization "$multi_repo/auth-${grant##*/}" "$grant" git -C "$multi_repo" push origin HEAD
  done
done
expect_unsupported_authorization "$TMP_ROOT/variable-url-auth" kunchenguid/dotfiles \
  git -C "$push_home" push 'https://github.com/${OWNER}/dotfiles.git' HEAD
pass "unsupported targets cannot execute under absent, mismatched or single-repository grants"

audit_stubs="$TMP_ROOT/audit-stubs"
mkdir -p "$audit_stubs"
cat >"$audit_stubs/gh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_FORGE_MARKER"
SH
chmod +x "$audit_stubs/gh"
for failure in directory record; do
  failed_home="$TMP_ROOT/audit-failure-$failure"
  marker="$TMP_ROOT/audit-executed-$failure"
  mkdir -p "$failed_home/state"
  if [ "$failure" = directory ]; then
    : >"$failed_home/state/upstream-write-authorizations"
  else
    mkdir -p "$failed_home/state/upstream-write-authorizations"
  fi
  status=0
  (
    if [ "$failure" = record ]; then ulimit -c 0; ulimit -f 0; fi
    FM_HOME="$failed_home" FM_TEST_FORGE_MARKER="$marker" PATH="$audit_stubs:/usr/bin:/bin" \
      "$GUARD" authorize --repo kunchenguid/dotfiles --captain-words-file "$words" -- \
      gh issue create -R kunchenguid/dotfiles --title test
  ) >"$TMP_ROOT/audit-$failure.out" 2>"$TMP_ROOT/audit-$failure.err" || status=$?
  [ "$status" -ne 0 ] || fail "authorization should fail when audit $failure fails"
  [ ! -e "$marker" ] || fail "the forge executed after audit $failure failed"
done
pass "audit directory and record failures stop before the real tool executes"

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
