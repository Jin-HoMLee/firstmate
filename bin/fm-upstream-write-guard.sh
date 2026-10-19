#!/usr/bin/env bash
# Block GitHub repository writes to github.com/kunchenguid/* before the
# network mutation starts.
#
# Public interfaces:
#   fm-upstream-write-guard.sh install-shims <directory>
#     Recreates <directory> with gh and gh-axi wrappers. Put it first on PATH.
#   fm-upstream-write-guard.sh cli <shim-directory> <gh|gh-axi> [args...]
#     Wrapper entrypoint. Read operations pass through. Repository mutations
#     require an explicit repository selector, and protected repositories stop.
#   fm-upstream-write-guard.sh pre-push <remote-name> <remote-url>
#     Git pre-push entrypoint. Protected GitHub remotes stop before git sends
#     ref updates. The hook consumes no stdin, so a chained project hook keeps
#     the complete ref stream.
#   fm-upstream-write-guard.sh check <gh|gh-axi|git> [args...]
#     Local-only classifier used by the primary PreToolUse guard.
#   fm-upstream-write-guard.sh authorize --repo <owner/name>
#       --captain-words-file <path> -- <gh|gh-axi|git> [args...]
#     The only override. It is primary-only, requires an exact protected repo,
#     exact captain words in a regular file, and a command whose locally proved
#     destination is that same repo. It writes an audit record before executing.
#
# The classifier never contacts GitHub. For gh and gh-axi, every repository
# mutation must name its repository with -R/--repo, a GitHub URL, or an API
# /repos/<owner>/<repo>/ path. This deliberately refuses mutation commands that
# rely on fork-aware default resolution: gh may select a fork's parent even
# when origin is the personal fork. Read-only commands stay available with or
# without a selector.
# Note: git push --no-verify skips the pre-push check and is an accepted, deliberate-action-only residual.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
PROTECTED_OWNER=kunchenguid

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

normalize_repo() {
  local value=$1 host path lower_value
  value=${value%/}
  value=${value%.git}
  case "$(lower "$value")" in
    https://*|http://*|ssh://*|git://*|git+ssh://*|ssh+git://*)
      host=${value#*://}
      host=${host#*@}
      path=${host#*/}
      host=${host%%/*}
      host=${host%%:*}
      case "$(lower "$host")" in
        github.com|ssh.github.com|api.github.com) ;;
        *) return 1 ;;
      esac
      value=$path
      ;;
  esac
  lower_value=$(lower "$value")
  case "$lower_value" in
    git@github.com:*|git@ssh.github.com:*|github.com:*|ssh.github.com:*) value=${value#*:} ;;
    github.com/*|ssh.github.com/*) value=${value#*/} ;;
  esac
  value=${value#repos/}
  value=${value#/repos/}
  value=${value#/}
  value=${value%%\?*}
  value=${value%%\#*}
  # API paths carry more segments; owner/name is the repository identity.
  case "$value" in */*) value=$(printf '%s' "$value" | awk -F/ '{print $1 "/" $2}') ;; *) return 1 ;; esac
  case "$value" in
    */*) ;;
    *) return 1 ;;
  esac
  case "$value" in *[!A-Za-z0-9_.-/-]*|*//*|/*|*/|*/*/*) return 1 ;; esac
  printf '%s\n' "$(lower "${value%%/*}")/${value#*/}"
}

repo_is_protected() {
  local repo
  repo=$(normalize_repo "$1" 2>/dev/null) || return 1
  [ "${repo%%/*}" = "$PROTECTED_OWNER" ]
}

fork_org() {
  local arg expect_org=0 protected=0
  for arg in "$@"; do
    if [ "$expect_org" -eq 1 ]; then
      expect_org=0
      [ "$(lower "$arg")" = "$PROTECTED_OWNER" ] && protected=1
      continue
    fi
    case "$arg" in
      --org) expect_org=1 ;;
      --org=*) [ "$(lower "${arg#--org=}")" = "$PROTECTED_OWNER" ] && protected=1 ;;
    esac
  done
  [ "$protected" -eq 1 ]
}

repo_destination() {
  local sub=$1 arg expect_flag_value=0
  shift
  for arg in "$@"; do
    if [ "$expect_flag_value" -eq 1 ]; then
      expect_flag_value=0
      continue
    fi
    case "$sub" in
      create|view)
        case "$arg" in
          -t|--template) expect_flag_value=1; continue ;;
          --template=*|-t?*) continue ;;
        esac
        ;;
    esac
    case "$arg" in
      -b|--branch|-q|--jq|-d|--description|-h|--homepage|-s|--source|-R|--repo|-g|--gitignore|-l|--license|-r|--remote|-p|--team|--json|--fork-name|--org|--remote-name|--default-branch|--add-topic|--remove-topic|--squash-merge-commit-message|--visibility)
        expect_flag_value=1
        continue
        ;;
      --branch=*|--jq=*|--description=*|--homepage=*|--source=*|--repo=*|--gitignore=*|--license=*|--remote=*|--team=*|--json=*|--fork-name=*|--org=*|--remote-name=*|--default-branch=*|--add-topic=*|--remove-topic=*|--squash-merge-commit-message=*|--visibility=*)
        continue
        ;;
      -b?*|-q?*|-d?*|-h?*|-s?*|-R?*|-g?*|-l?*|-r?*|-p?*)
        continue
        ;;
    esac
    case "$arg" in
      -*) continue ;;
      */*) set_target "$arg" repo-positional; break ;;
    esac
  done
}

issue_transfer_destination() {
  local arg expect_repo=0
  for arg in "$@"; do
    if [ "$expect_repo" -eq 1 ]; then expect_repo=0; continue; fi
    case "$arg" in
      -R|--repo) expect_repo=1; continue ;;
      --repo=*|-R?*) continue ;;
      -*) continue ;;
      http://*|https://*) continue ;;
      */*) printf '%s\n' "$arg"; return 0 ;;
    esac
  done
  return 1
}

repo_subsubcommand() {
  local arg expect_repo=0 positional=0
  for arg in "$@"; do
    if [ "$expect_repo" -eq 1 ]; then expect_repo=0; continue; fi
    case "$arg" in
      -R|--repo) expect_repo=1; continue ;;
      --repo=*|-R?*) continue ;;
      -*) continue ;;
    esac
    positional=$((positional + 1))
    if [ "$positional" -le 2 ]; then continue; fi
    printf '%s\n' "$arg"
    return 0
  done
  return 1
}

TOP='' SUB='' TARGET='' TRANSFER_DEST='' MUTATION=0 REPO_SCOPED=0
set_target() {
  local candidate normalized
  candidate=$1
  normalized=$(normalize_repo "$candidate" 2>/dev/null) || return 0
  if [ -n "$TARGET" ] && [ "$(lower "$TARGET")" != "$(lower "$normalized")" ]; then
    TARGET=AMBIGUOUS
    return 0
  fi
  TARGET=$normalized
  : "$2"
}

parse_top_sub_and_target() {
  local tool=$1 arg expect_repo=0 seen_top=0 seen_sub=0 previous=
  shift
  TOP='' SUB='' TARGET='' TRANSFER_DEST=''
  for arg in "$@"; do
    if [ "$expect_repo" -eq 1 ]; then
      set_target "$arg" explicit-repository
      expect_repo=0
      previous=$arg
      continue
    fi
    case "$arg" in
      -R|--repo) expect_repo=1; previous=$arg; continue ;;
      --repo=*) set_target "${arg#--repo=}" explicit-repository ;;
      -R?*) set_target "${arg#-R}" explicit-repository ;;
      https://github.com/*|http://github.com/*|git@github.com:*|github.com/*)
        [ "$TOP" = repo ] || set_target "$arg" github-url
        ;;
    esac
    if [ "$seen_top" -eq 0 ]; then
      case "$arg" in -*) previous=$arg; continue ;; esac
      TOP=$arg
      seen_top=1
      previous=$arg
      continue
    fi
    if [ "$seen_sub" -eq 0 ]; then
      case "$arg" in -*) previous=$arg; continue ;; esac
      SUB=$arg
      seen_sub=1
    fi
    previous=$arg
  done
  [ "$expect_repo" -eq 0 ] || TARGET=AMBIGUOUS

  if [ "$TOP" = api ]; then
    for arg in "$@"; do
      case "$(lower "$arg")" in
        /repos/*|repos/*|https://api.github.com/repos/*|http://api.github.com/repos/*) set_target "$arg" api-path ;;
      esac
    done
  fi

  if [ "$TOP" = repo ]; then
    case "$SUB" in
      view|fork|edit|archive|delete|rename|sync|create) repo_destination "$SUB" "$@" ;;
    esac
  fi

  if [ "$TOP" = issue ] && [ "$SUB" = transfer ]; then
    TRANSFER_DEST=$(issue_transfer_destination "$@") || TRANSFER_DEST=''
  fi
  : "$tool" "$previous"
}

classify_gh() {
  local tool=$1 arg subsub method=GET query= query_seen=0 expect_value=0
  shift
  MUTATION=0
  REPO_SCOPED=0
  parse_top_sub_and_target "$tool" "$@"

  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      expect_value=0
      continue
    fi
    case "$arg" in
      --help|--version) return 0 ;;
      -h)
        case "$TOP/$SUB" in
          repo/create|repo/edit) expect_value=1 ;;
          *) return 0 ;;
        esac
        ;;
      --) break ;;
      -*)
        case "$arg" in
          *=*) ;;
          --*) expect_value=1 ;;
          -?) expect_value=1 ;;
          -??*) ;;
        esac
        ;;
    esac
  done
  [ -n "$TOP" ] || return 0

  case "$TOP" in
    pr)
      REPO_SCOPED=1
      case "$SUB" in list|view|status|checks|diff|checkout) ;; *) MUTATION=1 ;; esac
      ;;
    issue)
      REPO_SCOPED=1
      case "$SUB" in list|view|status) ;; subissue) [ "${3:-}" = list ] || MUTATION=1 ;; *) MUTATION=1 ;; esac
      ;;
    agent-task|agent|agent-tasks|agents)
      REPO_SCOPED=1
      case "$SUB" in list|view) ;; *) MUTATION=1 ;; esac
      ;;
    discussion)
      REPO_SCOPED=1
      case "$SUB" in list|view) ;; *) MUTATION=1 ;; esac
      ;;
    run)
      REPO_SCOPED=1
      case "$SUB" in list|view|watch|download) ;; *) MUTATION=1 ;; esac
      ;;
    workflow)
      REPO_SCOPED=1
      case "$SUB" in list|view) ;; *) MUTATION=1 ;; esac
      ;;
    release)
      REPO_SCOPED=1
      case "$SUB" in list|view|download) ;; *) MUTATION=1 ;; esac
      ;;
    label)
      REPO_SCOPED=1
      [ "$SUB" = list ] || MUTATION=1
      ;;
    ruleset)
      REPO_SCOPED=1
      case "$SUB" in list|view) ;; *) MUTATION=1 ;; esac
      ;;
    secret|variable)
      REPO_SCOPED=1
      [ "$SUB" = list ] || MUTATION=1
      ;;
    api)
      [ -n "$TARGET" ] && REPO_SCOPED=1
      for arg in "$@"; do
        case "$arg" in
          -X|--method) method=EXPECT ;;
          -X=*|--method=*) method=${arg#*=} ;;
          -X?*) method=${arg#-X} ;;
          GET|POST|PUT|PATCH|DELETE|HEAD)
            if [ "$method" = EXPECT ] || [ "$arg" = "$SUB" ]; then method=$arg; fi
            ;;
          -f|--field|-F|--raw-field|--input) [ "$method" = GET ] && method=POST ;;
          -f=*|--field=*|-F=*|--raw-field=*|--input=*) [ "$method" = GET ] && method=POST ;;
          -f?*|-F?*) [ "$method" = GET ] && method=POST ;;
          query=*) query=${arg#query=}; case "$query" in @*) query_seen=0 ;; *) query_seen=1 ;; esac ;;
        esac
      done
      method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
      if [ "$SUB" = graphql ]; then
        if [ "$query_seen" -eq 1 ]; then
          case "$query" in *mutation*) MUTATION=1 ;; *) MUTATION=0 ;; esac
        else
          MUTATION=1
        fi
      else
        case "$method" in GET|HEAD) ;; *) MUTATION=1 ;; esac
      fi
      ;;
    repo)
      case "$SUB" in
        list|view|clone|read-dir|read-file|gitignore|license|set-default|'') ;;
        deploy-key)
          subsub=$(repo_subsubcommand "$@") || subsub=''
          case "$subsub" in list) ;; *) MUTATION=1; REPO_SCOPED=1 ;; esac
          ;;
        autolink)
          subsub=$(repo_subsubcommand "$@") || subsub=''
          case "$subsub" in list|view) ;; *) MUTATION=1; REPO_SCOPED=1 ;; esac
          ;;
        fork)
          if fork_org "$@"; then
            MUTATION=1
            REPO_SCOPED=1
            TARGET=$PROTECTED_OWNER/fork
          fi
          ;;
        create) MUTATION=1; [ -n "$TARGET" ] && REPO_SCOPED=1 ;;
        *) MUTATION=1; REPO_SCOPED=1 ;;
      esac
      ;;
    stack)
      case "$SUB" in submit|merge) MUTATION=1; REPO_SCOPED=1 ;; link)
        for arg in "$@"; do [ "$arg" = --open ] && { MUTATION=1; REPO_SCOPED=1; }; done
        ;;
      esac
      ;;
    cache)
      REPO_SCOPED=1
      [ "$SUB" = delete ] && MUTATION=1
      ;;
    search|status|browse|attestation|help|completion|auth|config|alias|extension|ssh-key|gpg-key|org|gist|project|codespace|setup)
      ;;
    *)
      # Unknown official/extension commands are not assumed to mutate a repo.
      # An explicit protected selector is still refused below if they do.
      ;;
  esac
}

refuse_reason() {
  printf 'upstream-write-guard: %s\n' "$1" >&2
}

check_gh() {
  local tool=$1
  shift
  classify_gh "$tool" "$@"
  if [ "$TARGET" = AMBIGUOUS ]; then
    refuse_reason "conflicting or incomplete repository selectors; refusing before any GitHub operation"
    return 2
  fi
  if [ "$TOP" = api ] && [ "$SUB" = graphql ] && [ "$MUTATION" -eq 1 ] && [ -z "$TARGET" ]; then
    refuse_reason "gh api graphql mutation must name its exact repository with -R/--repo (query-body targets cannot be verified locally)"
    return 2
  fi
  if [ "$MUTATION" -eq 1 ] && [ "$REPO_SCOPED" -eq 1 ] && [ -z "$TARGET" ]; then
    refuse_reason "repository mutation '$tool $TOP $SUB' must name its exact repository with -R/--repo (fork-aware defaults are forbidden)"
    return 2
  fi
  if [ "$MUTATION" -eq 1 ] && [ -n "$TARGET" ] && repo_is_protected "$TARGET"; then
    refuse_reason "repository mutation against protected upstream '$TARGET' requires the exact captain-authorized interface"
    return 2
  fi
  if [ "$MUTATION" -eq 1 ] && [ -n "$TRANSFER_DEST" ] && repo_is_protected "$TRANSFER_DEST"; then
    refuse_reason "repository mutation against protected upstream '$TRANSFER_DEST' requires the exact captain-authorized interface"
    return 2
  fi
  return 0
}

GIT_REPO_DIR='' GIT_REMOTE='' GIT_REMOTE_URL='' GIT_TARGET=''
parse_git_push() {
  local arg after_push=0 expect_c=0 expect_repo=0 expect_c_override=0 candidates url target
  local -a c_overrides=()
  GIT_REPO_DIR=$PWD
  GIT_REMOTE=
  GIT_REMOTE_URL=
  GIT_TARGET=
  for arg in "$@"; do
    if [ "$expect_c" -eq 1 ]; then GIT_REPO_DIR=$arg; expect_c=0; continue; fi
    if [ "$expect_c_override" -eq 1 ]; then
      c_overrides+=( -c "$arg" )
      expect_c_override=0
      continue
    fi
    if [ "$after_push" -eq 0 ]; then
      case "$arg" in
        -C) expect_c=1 ;;
        -C?*) GIT_REPO_DIR=${arg#-C} ;;
        -c) expect_c_override=1 ;;
        push) after_push=1 ;;
      esac
      continue
    fi
    if [ "$expect_repo" -eq 1 ]; then
      GIT_REMOTE=$arg
      expect_repo=0
      break
    fi
    case "$arg" in
      --repo=*) GIT_REMOTE=${arg#--repo=}; break ;;
      --repo) expect_repo=1 ;;
      -*) ;;
      *) GIT_REMOTE=$arg; break ;;
    esac
  done
  [ "$after_push" -eq 1 ] || return 1
  if [ -z "$GIT_REMOTE" ]; then
    GIT_REMOTE=$(git -C "$GIT_REPO_DIR" "${c_overrides[@]+"${c_overrides[@]}"}" config --get remote.pushDefault 2>/dev/null || true)
    [ -n "$GIT_REMOTE" ] || GIT_REMOTE=$(git -C "$GIT_REPO_DIR" "${c_overrides[@]+"${c_overrides[@]}"}" config --get branch."$(git -C "$GIT_REPO_DIR" branch --show-current 2>/dev/null)".remote 2>/dev/null || true)
    [ -n "$GIT_REMOTE" ] || GIT_REMOTE=origin
  fi
  case "$GIT_REMOTE" in
    *://*|git@github.com:*|git@ssh.github.com:*|github.com/*|ssh.github.com/*)
      candidates=$GIT_REMOTE
      ;;
    *)
      candidates=$(git -C "$GIT_REPO_DIR" "${c_overrides[@]+"${c_overrides[@]}"}" config --get-all remote."$GIT_REMOTE".pushurl 2>/dev/null || true)
      [ -n "$candidates" ] || candidates=$(git -C "$GIT_REPO_DIR" "${c_overrides[@]+"${c_overrides[@]}"}" config --get-all remote."$GIT_REMOTE".url 2>/dev/null || true)
      ;;
  esac
  [ -n "$candidates" ] || return 2
  GIT_REMOTE_URL=
  GIT_TARGET=
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    [ -n "$GIT_REMOTE_URL" ] || GIT_REMOTE_URL=$url
    target=$(normalize_repo "$url" 2>/dev/null || true)
    [ -n "$target" ] || continue
    [ -n "$GIT_TARGET" ] || GIT_TARGET=$target
    if repo_is_protected "$target"; then
      GIT_TARGET=$target
      break
    fi
  done <<< "$candidates"
  return 0
}

check_git() {
  parse_git_push "$@"
  case $? in
    1) return 0 ;;
    2) refuse_reason "cannot resolve git push destination '$GIT_REMOTE' locally; refusing before network access"; return 2 ;;
  esac
  if [ -n "$GIT_TARGET" ] && repo_is_protected "$GIT_TARGET"; then
    refuse_reason "git push to protected upstream '$GIT_TARGET' requires the exact captain-authorized interface"
    return 2
  fi
  return 0
}

locate_real_tool() {
  local tool=$1 skip=${2:-} dir candidate
  OLD_IFS=$IFS
  IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    [ "$dir" = "$skip" ] && continue
    candidate=$dir/$tool
    [ -x "$candidate" ] || continue
    case "$candidate" in "$SCRIPT_DIR/$tool"|"$skip/$tool") continue ;; esac
    printf '%s\n' "$candidate"
    IFS=$OLD_IFS
    return 0
  done
  IFS=$OLD_IFS
  return 1
}

install_shims() {
  local dir=$1 tool quoted_guard quoted_dir tmp
  chmod u+w "$dir" 2>/dev/null || true
  rm -rf "$dir"
  mkdir -p "$dir" || return 1
  quoted_guard=$(printf '%q' "$SCRIPT_DIR/fm-upstream-write-guard.sh")
  quoted_dir=$(printf '%q' "$(CDPATH='' cd -- "$dir" && pwd -P)")
  for tool in gh gh-axi; do
    tmp=$dir/$tool
    cat >"$tmp" <<EOF
#!/usr/bin/env bash
exec $quoted_guard cli $quoted_dir $tool "\$@"
EOF
    chmod 500 "$tmp"
  done
  chmod 500 "$dir"
}

audit_authorization() {
  local repo=$1 words=$2 tool=$3
  shift 3
  local home dir stamp nonce record cmd_q arg words_hash
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
  dir=$home/state/upstream-write-authorizations
  mkdir -p "$dir" || die "cannot create upstream authorization audit directory: $dir"
  chmod 700 "$dir" 2>/dev/null || true
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  nonce="$$.$(date +%s)"
  record=$dir/$stamp-$nonce.record
  cmd_q=$tool
  for arg in "$@"; do printf -v cmd_q '%s %q' "$cmd_q" "$arg"; done
  if command -v shasum >/dev/null 2>&1; then
    words_hash=$(shasum -a 256 "$words" | awk '{print $1}')
  else
    words_hash=$(sha256sum "$words" | awk '{print $1}')
  fi
  umask 077
  {
    printf 'version=1\ncreated=%s\nrepo=%s\ncommand=%s\ncaptain_words_sha256=%s\n' "$stamp" "$repo" "$cmd_q" "$words_hash"
    printf '%s\n' 'captain_words<<EOF'
    cat "$words"
    printf '\nEOF\nresult=pending\n'
  } >"$record" || die "cannot write authorization audit record"
  printf '%s\n' "$record"
}

authorize() {
  local repo='' words='' tool actual record status normalized
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -gt 1 ] || usage; repo=$2; shift 2 ;;
      --repo=*) repo=${1#--repo=}; shift ;;
      --captain-words-file) [ "$#" -gt 1 ] || usage; words=$2; shift 2 ;;
      --captain-words-file=*) words=${1#--captain-words-file=}; shift ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ -z "${FM_TASK_ID:-}" ] || die "workers cannot authorize protected-upstream writes; route the exact captain instruction through firstmate"
  normalized=$(normalize_repo "$repo" 2>/dev/null) || die "--repo must name one exact GitHub owner/repository"
  repo_is_protected "$normalized" || die "the authorization interface is only for protected kunchenguid/* repositories"
  [ -n "$words" ] && [ -f "$words" ] && [ ! -L "$words" ] && [ -s "$words" ] || die "--captain-words-file must be a nonempty regular file"
  [ "$#" -gt 0 ] || usage
  tool=${1##*/}
  shift
  case "$tool" in
    gh|gh-axi)
      classify_gh "$tool" "$@"
      [ "$MUTATION" -eq 1 ] || die "authorized command is not a repository mutation"
      [ "$TARGET" = "$normalized" ] || die "authorized command must explicitly name exact repository '$normalized'"
      if [ -n "$TRANSFER_DEST" ] && repo_is_protected "$TRANSFER_DEST"; then
        [ "$(normalize_repo "$TRANSFER_DEST" 2>/dev/null)" = "$normalized" ] || die "authorized command's issue-transfer destination '${TRANSFER_DEST}' is outside the named --repo scope"
      fi
      ;;
    git)
      parse_git_push "$@" || die "authorized git command must be a push with a locally resolvable destination"
      [ "$GIT_TARGET" = "$normalized" ] || die "authorized git push resolves to '${GIT_TARGET:-unknown}', not '$normalized'"
      ;;
    *) die "authorized tool must be gh, gh-axi, or git" ;;
  esac
  record=$(audit_authorization "$normalized" "$words" "$tool" "$@")
  actual=$(locate_real_tool "$tool" "" 2>/dev/null) || die "cannot find the real $tool executable"
  "$actual" "$@"
  status=$?
  printf 'result=exit-%s\n' "$status" >>"$record" 2>/dev/null || true
  return "$status"
}

cmd=${1:-}
case "$cmd" in
  install-shims)
    [ "$#" -eq 2 ] || usage
    install_shims "$2"
    ;;
  cli)
    [ "$#" -ge 3 ] || usage
    shim=$2 tool=$3
    shift 3
    case "$tool" in gh|gh-axi) ;; *) usage ;; esac
    check_gh "$tool" "$@" || exit $?
    actual=$(locate_real_tool "$tool" "$shim" 2>/dev/null) || die "cannot find the real $tool executable after the guard shim"
    exec "$actual" "$@"
    ;;
  pre-push)
    [ "$#" -eq 3 ] || usage
    target=$(normalize_repo "$3" 2>/dev/null || true)
    if [ -n "$target" ] && repo_is_protected "$target"; then
      refuse_reason "git push to protected upstream '$target' is blocked before ref updates; only firstmate's exact captain-authorized interface may perform it"
      exit 2
    fi
    ;;
  check)
    [ "$#" -ge 2 ] || usage
    tool=${2##*/}
    shift 2
    case "$tool" in
      gh|gh-axi) check_gh "$tool" "$@" ;;
      git) check_git "$@" ;;
      *) exit 0 ;;
    esac
    ;;
  authorize)
    shift
    authorize "$@"
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac
