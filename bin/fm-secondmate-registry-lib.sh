#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for data/secondmates.md records.
#
# A generated local record ends with this explicit structured suffix:
#   (home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# An explicit local shared-code binding uses:
#   (root: ...; home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# Its code root must resolve to the spawning primary's code root; home stays a
# separate, already seeded operational home. Legacy local records are unchanged.
# A remote record adds its host placement before the existing fields:
#   (host: ...; root: ...; home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# Summary text and scope text are natural language and may contain parentheses
# and semicolons, so field boundaries are anchored to the suffix markers rather
# than to the first incidental punctuation.

SECONDMATE_REGISTRY_ID=
SECONDMATE_REGISTRY_SUMMARY=
SECONDMATE_REGISTRY_HOST=
SECONDMATE_REGISTRY_ROOT=
SECONDMATE_REGISTRY_HOME=
SECONDMATE_REGISTRY_SCOPE=
SECONDMATE_REGISTRY_PROJECTS=
SECONDMATE_REGISTRY_ADDED=
SECONDMATE_REGISTRY_REMOTE=0
SECONDMATE_REGISTRY_LINE=
SECONDMATE_REGISTRY_MATCH_HOST=
SECONDMATE_REGISTRY_MATCH_ROOT=
SECONDMATE_REGISTRY_MATCH_HOME=
SECONDMATE_REGISTRY_MATCH_HOME_KEY=
SECONDMATE_REGISTRY_MATCH_PROJECTS=
SECONDMATE_REGISTRY_MATCH_REMOTE=0
SECONDMATE_REGISTRY_ERROR=

secondmate_registry_lock_path() { printf '%s/.secondmate-registry.lock\n' "$1"; }
secondmate_reply_lifecycle_lock_path() { printf '%s/.remote-reply-lifecycle-%s.lock\n' "$1" "$2"; }

secondmate_registry_parse_line() {
  local line=$1
  local local_re='^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  local shared_re='^- ([A-Za-z0-9._-]+) - (.+) \(root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  local remote_re='^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  SECONDMATE_REGISTRY_ID=
  SECONDMATE_REGISTRY_SUMMARY=
  SECONDMATE_REGISTRY_HOST=
  SECONDMATE_REGISTRY_ROOT=
  SECONDMATE_REGISTRY_HOME=
  SECONDMATE_REGISTRY_SCOPE=
  SECONDMATE_REGISTRY_PROJECTS=
  SECONDMATE_REGISTRY_ADDED=
  SECONDMATE_REGISTRY_REMOTE=0
  # Parse the legacy local form first so summary prose that happens to mention
  # remote field names cannot change an existing route's placement semantics.
  if [[ "$line" =~ $local_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[6]}
  elif [[ "$line" =~ $shared_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_ROOT=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[6]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[7]}
    [ -n "$SECONDMATE_REGISTRY_ROOT" ] || return 1
  elif [[ "$line" =~ $remote_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOST=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_ROOT=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[6]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[7]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[8]}
    SECONDMATE_REGISTRY_REMOTE=1
  else
    return 1
  fi
  [ -n "$SECONDMATE_REGISTRY_HOME" ] || return 1
  [ -n "$SECONDMATE_REGISTRY_SCOPE" ] || return 1
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    [ -n "$SECONDMATE_REGISTRY_HOST" ] || return 1
    [ -n "$SECONDMATE_REGISTRY_ROOT" ] || return 1
  fi
  return 0
}

secondmate_registry_line_for_id() {
  local reg=$1 id=$2 line count=0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "- $id" ] || case "$line" in "- $id "*) ;; *) continue ;; esac
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    SECONDMATE_REGISTRY_LINE=$line
  done < "$reg"
  [ "$count" -eq 1 ] || return 1
  secondmate_registry_parse_line "$SECONDMATE_REGISTRY_LINE"
}

secondmate_registry_field() {
  local reg=$1 id=$2 key=$3
  secondmate_registry_line_for_id "$reg" "$id" || return 1
  case "$key" in
    host) printf '%s\n' "$SECONDMATE_REGISTRY_HOST" ;;
    root) printf '%s\n' "$SECONDMATE_REGISTRY_ROOT" ;;
    home) printf '%s\n' "$SECONDMATE_REGISTRY_HOME" ;;
    scope) printf '%s\n' "$SECONDMATE_REGISTRY_SCOPE" ;;
    projects) printf '%s\n' "$SECONDMATE_REGISTRY_PROJECTS" ;;
    remote) printf '%s\n' "$SECONDMATE_REGISTRY_REMOTE" ;;
    *) return 1 ;;
  esac
}

secondmate_registry_path_key() {
  local path=$1 parent base
  case "$path" in /*) ;; *) return 1 ;; esac
  if [ -d "$path" ]; then
    cd "$path" && pwd -P
  else
    parent=$(dirname "$path")
    base=$(basename "$path")
    cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base"
  fi
}

secondmate_registry_validate_bindings() {
  local reg=$1 resolver=$2 expected_id=${3:-} expected_home=${4:-}
  local tmp snapshot bindings line id host root home home_key root_key duplicate_homes duplicate_ids overlaps expected_home_key
  SECONDMATE_REGISTRY_MATCH_HOST=
  SECONDMATE_REGISTRY_MATCH_ROOT=
  SECONDMATE_REGISTRY_MATCH_HOME=
  SECONDMATE_REGISTRY_MATCH_HOME_KEY=
  SECONDMATE_REGISTRY_MATCH_PROJECTS=
  SECONDMATE_REGISTRY_MATCH_REMOTE=0
  SECONDMATE_REGISTRY_ERROR=
  case "$expected_id" in *[!A-Za-z0-9._-]*) SECONDMATE_REGISTRY_ERROR="invalid secondmate id: $expected_id"; return 1 ;; esac
  if [ ! -f "$reg" ] || [ -L "$reg" ]; then
    SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-registry.XXXXXX") || {
    SECONDMATE_REGISTRY_ERROR="could not create secondmate registry validation state"
    return 1
  }
  snapshot="$tmp/registry"
  bindings="$tmp/bindings"
  if ! cat "$reg" > "$snapshot" 2>/dev/null || ! : > "$bindings"; then
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        if ! secondmate_registry_parse_line "$line"; then
          rm -rf -- "$tmp"
          SECONDMATE_REGISTRY_ERROR="malformed secondmate registry entry: $line"
          return 1
        fi
        id=$SECONDMATE_REGISTRY_ID
        host=$SECONDMATE_REGISTRY_HOST
        root=$SECONDMATE_REGISTRY_ROOT
        home=$SECONDMATE_REGISTRY_HOME
        case "$home" in
          /*) ;;
          *)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe non-absolute secondmate home for $id: $home"
            return 1
            ;;
        esac
        case "$home$host$root" in
          *$'\t'*|*$'\n'*|*$'\r'*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe secondmate route for $id"
            return 1
            ;;
        esac
        if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
          case "$host" in ''|-*|*[!A-Za-z0-9._-]*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe SSH host alias for $id: $host"
            return 1
            ;;
          esac
          case "$root" in /*) ;; *)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe non-absolute remote root for $id: $root"
            return 1
            ;;
          esac
          case "/$root/" in */../*|*/./*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote code root contains traversal components for $id: $root"
            return 1
            ;;
          esac
          case "/$home/" in */../*|*/./*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote home contains traversal components for $id: $home"
            return 1
            ;;
          esac
          case "$root$home" in *'//'*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote route contains an empty path component for $id"
            return 1
            ;;
          esac
          if [ "$root" = "$home" ]; then
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="overlapping remote root and home for $id: $root"
            return 1
          fi
          case "$home/" in "$root/"*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote home for $id is inside its code root: $home"
            return 1
            ;;
          esac
          case "$root/" in "$home/"*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote code root for $id is inside its home: $root"
            return 1
            ;;
          esac
          home_key="ssh:$host:$home"
        else
          home_key=$("$resolver" "$home" 2>/dev/null || true)
          if [ -z "$home_key" ]; then
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unresolvable secondmate home for $id: $home"
            return 1
          fi
          if [ -n "$root" ]; then
            case "$root" in /*) ;; *)
              rm -rf -- "$tmp"
              SECONDMATE_REGISTRY_ERROR="unsafe non-absolute local code root for $id: $root"
              return 1 ;;
            esac
            root_key=$("$resolver" "$root" 2>/dev/null || true)
            if [ -z "$root_key" ] || [ "$root_key" = / ] || [ "$root_key" = "$home_key" ]; then
              rm -rf -- "$tmp"
              SECONDMATE_REGISTRY_ERROR="unresolvable or overlapping local code root for $id"
              return 1
            fi
            case "$root_key/:$home_key/" in
              "$home_key/"*|*":$root_key/"*)
                rm -rf -- "$tmp"
                SECONDMATE_REGISTRY_ERROR="overlapping local code root and home for $id"
                return 1 ;;
            esac
          fi
          home_key="local:$home_key"
        fi
        printf '%s\t%s\n' "$home_key" "$id" >> "$bindings"
        if [ -n "$expected_id" ] && [ "$id" = "$expected_id" ]; then
          SECONDMATE_REGISTRY_MATCH_HOST=$host
          SECONDMATE_REGISTRY_MATCH_ROOT=$root
          SECONDMATE_REGISTRY_MATCH_HOME=$home
          SECONDMATE_REGISTRY_MATCH_HOME_KEY=$home_key
          SECONDMATE_REGISTRY_MATCH_PROJECTS=$SECONDMATE_REGISTRY_PROJECTS
          SECONDMATE_REGISTRY_MATCH_REMOTE=$SECONDMATE_REGISTRY_REMOTE
        fi
        ;;
    esac
  done < "$snapshot"
  duplicate_homes=$(awk -F '\t' '
    {
      if ($1 in owner) {
        print $1 ": " owner[$1] ", " $2
        bad=1
      } else {
        owner[$1]=$2
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate home assignment: $duplicate_homes"
    return 1
  }
  duplicate_ids=$(awk -F '\t' '
    {
      if ($2 in home) {
        print $2 ": " home[$2] ", " $1
        bad=1
      } else {
        home[$2]=$1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate id assignment: $duplicate_ids"
    return 1
  }
  overlaps=$(awk -F '\t' '
    function ancestor(a, b) { return a != b && index(b, a "/") == 1 }
    {
      for (i = 1; i <= count; i++) {
        if (ancestor($1, path[i])) {
          print $1 " (" $2 ") contains " path[i] " (" id[i] ")"
          bad=1
        } else if (ancestor(path[i], $1)) {
          print path[i] " (" id[i] ") contains " $1 " (" $2 ")"
          bad=1
        }
      }
      count++
      path[count]=$1
      id[count]=$2
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="overlapping secondmate home assignment: $overlaps"
    return 1
  }
  rm -rf -- "$tmp"
  if [ -n "$expected_id" ] && [ -z "$SECONDMATE_REGISTRY_MATCH_HOME" ]; then
    SECONDMATE_REGISTRY_ERROR="no registry binding for secondmate $expected_id"
    return 1
  fi
  if [ -n "$expected_home" ]; then
    if [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" -eq 1 ]; then
      expected_home_key="ssh:$SECONDMATE_REGISTRY_MATCH_HOST:$expected_home"
    else
      expected_home_key=$("$resolver" "$expected_home" 2>/dev/null || true)
      [ -z "$expected_home_key" ] || expected_home_key="local:$expected_home_key"
    fi
    if [ -z "$expected_home_key" ] || [ "$expected_home_key" != "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" ]; then
      SECONDMATE_REGISTRY_ERROR="secondmate $expected_id is registered at $SECONDMATE_REGISTRY_MATCH_HOME, not $expected_home"
      return 1
    fi
  fi
  return 0
}

# Local shared-code binding mechanics. code_root= in parent task metadata is
# the activated binding; a registry root: is the explicit requested binding.
# Once activated, removing/changing the route refuses instead of reverting to
# the home's retained old source. Missing registry recovery can use the record.
# Neither helper writes metadata, adopts source, nor certifies installation or
# native primary handoff. The home stays seeded and retained in place.
secondmate_code_root_from_meta() {  # <meta>; empty for a legacy/absent record
  local meta=$1
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  awk -F= '
    $1 == "code_root" { n++; value=substr($0, index($0,"=")+1) }
    END { if (n > 1 || (n == 1 && value == "")) exit 1; if (n == 1) print value }
  ' "$meta"
}

secondmate_code_head_from_meta() {  # <meta>; empty for a legacy/absent record
  local meta=$1
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  awk -F= '
    $1 == "code_head" { n++; value=substr($0, index($0,"=")+1) }
    END {
      if (n > 1 || (n == 1 && (value ~ /[^0-9a-fA-F]/ || (length(value) != 40 && length(value) != 64)))) exit 1
      if (n == 1) print value
    }
  ' "$meta"
}

SECONDMATE_LOCAL_CODE_ROOT=
secondmate_local_code_binding() {  # <registry> <id> <home> <owner-root> <recorded-root>
  local reg=$1 id=$2 home=$3 owner=$4 recorded=$5 declared='' count root top gd common recorded_real home_real
  SECONDMATE_LOCAL_CODE_ROOT=
  SECONDMATE_REGISTRY_ERROR=
  if [ -e "$reg" ] || [ -L "$reg" ]; then
    if [ ! -f "$reg" ] || [ -L "$reg" ]; then
      SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
      return 1
    fi
    count=$(awk -v id="$id" '$1 == "-" && $2 == id { n++ } END { print n+0 }' "$reg") || return 1
    if [ "$count" != 0 ]; then
      secondmate_registry_validate_bindings "$reg" secondmate_registry_path_key "$id" "$home" || return 1
      if [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" = 1 ]; then
        SECONDMATE_REGISTRY_ERROR="local shared-code binding cannot replace a remote route"
        return 1
      fi
      declared=$SECONDMATE_REGISTRY_MATCH_ROOT
    fi
    if [ -n "$recorded" ] && [ -z "$declared" ]; then
      SECONDMATE_REGISTRY_ERROR="activated shared-code binding for $id cannot be removed by a missing or legacy route"
      return 1
    fi
  fi
  [ -n "$declared$recorded" ] || return 0
  root=${declared:-$recorded}
  case "$root$recorded" in *$'\n'*|*$'\r'*|*$'\t'*)
    SECONDMATE_REGISTRY_ERROR="unsafe local shared-code path for $id"; return 1 ;;
  esac
  case "$root" in /*) ;; *) SECONDMATE_REGISTRY_ERROR="local shared-code root must be absolute"; return 1 ;; esac
  root=$(cd "$root" 2>/dev/null && pwd -P) || {
    SECONDMATE_REGISTRY_ERROR="local shared-code root is unavailable"; return 1;
  }
  if [ "$root" = / ]; then
    SECONDMATE_REGISTRY_ERROR="filesystem root cannot be a shared-code installation"
    return 1
  fi
  owner=$(cd "$owner" 2>/dev/null && pwd -P) || return 1
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" != "$owner" ]; then
    SECONDMATE_REGISTRY_ERROR="local shared-code root for $id must match the owning primary code root"
    return 1
  fi
  if [ -n "$recorded" ]; then
    case "$recorded" in /*) ;; *) SECONDMATE_REGISTRY_ERROR="recorded shared-code root must be absolute"; return 1 ;; esac
    recorded_real=$(cd "$recorded" 2>/dev/null && pwd -P) || return 1
    if [ "$recorded_real" != "$root" ]; then
      SECONDMATE_REGISTRY_ERROR="local shared-code root for $id differs from its activated binding"
      return 1
    fi
  fi
  if [ ! -f "$home_real/.fm-secondmate-home" ] || [ -L "$home_real/.fm-secondmate-home" ] \
    || [ "$(cat "$home_real/.fm-secondmate-home" 2>/dev/null)" != "$id" ]; then
    SECONDMATE_REGISTRY_ERROR="shared-code operational home is not safely marked for $id"
    return 1
  fi
  case "$home_real/" in "$root/"*) SECONDMATE_REGISTRY_ERROR="shared code overlaps the operational home"; return 1 ;; esac
  case "$root/" in "$home_real/"*) SECONDMATE_REGISTRY_ERROR="shared code overlaps the operational home"; return 1 ;; esac
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" && pwd -P) || return 1
  gd=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  if [ "$top" != "$root" ] || [ "$gd" != "$common" ] \
    || [ -e "$root/.fm-secondmate-home" ] || [ -L "$root/.fm-secondmate-home" ] \
    || [ ! -f "$root/AGENTS.md" ] || [ ! -d "$root/bin" ]; then
    SECONDMATE_REGISTRY_ERROR="shared code must be the primary code checkout, not a task or secondmate home"
    return 1
  fi
  git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1 || {
    SECONDMATE_REGISTRY_ERROR="shared code has no readable committed HEAD"; return 1;
  }
  SECONDMATE_LOCAL_CODE_ROOT=$root
}

secondmate_shared_code_launch_supported() {  # <harness> <backend>
  # Herdr relaunch requires the endpoint's existing Pi session identity (see
  # fm-spawn.sh:relaunch_resume_args). A cross-root fresh-context handoff is
  # not proved here; do not silently resume old context or freeze its status.
  case "$1:$2" in pi:tmux|pi-signed:tmux) return 0 ;; esac
  printf 'error: local shared-code launch supports Pi/pi-signed on tmux only; refusing %s/%s before replacement\n' "$1" "$2" >&2
  return 1
}

secondmate_shared_code_pi_session_cli() {  # <selected-Pi-executable>
  local help
  if help=$("$1" --help 2>&1) && printf '%s\n' "$help" | grep -E -- '(^|[[:space:]])--session-dir([^[:alnum:]_-]|$)' >/dev/null; then
    return 0
  fi
  printf 'error: selected Pi executable has no verified --session-dir support; refusing shared-code launch\n' >&2
  return 1
}

secondmate_shared_code_pi_session_dir() {  # <home> [prepare]; requires fm-pr-lib.sh
  local home=$1 directory mode sessions="$1/data/pi-sessions"
  # Keep authentication/account selection unchanged. Only conversation storage
  # moves to this home's namespace; never merge, move or rewrite old sessions.
  for directory in "$home" "$home/data"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] && [ -O "$directory" ] \
      && [ -r "$directory" ] && [ -w "$directory" ] && [ -x "$directory" ] || {
      printf 'error: shared-code native session parent is unsafe: %s\n' "$directory" >&2; return 1;
    }
    mode=$(fm_pr_file_mode "$directory") || return 1
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    [ "$((8#$mode & 0022))" -eq 0 ] || {
      printf 'error: shared-code native session parent is writable by another user: %s\n' "$directory" >&2; return 1;
    }
  done
  if [ "${2:-}" = prepare ] && [ ! -e "$sessions" ] && [ ! -L "$sessions" ]; then
    (umask 077; mkdir -- "$sessions") || return 1
  fi
  if [ -e "$sessions" ] || [ -L "$sessions" ]; then
    [ -d "$sessions" ] && [ ! -L "$sessions" ] && [ -O "$sessions" ] \
      && [ "$(fm_pr_file_mode "$sessions")" = 700 ] || {
      printf 'error: existing native session directory is not an owned private directory: %s\n' "$sessions" >&2
      return 1
    }
  fi
  printf '%s\n' "$sessions"
}

secondmate_shared_code_native_files() {  # <code-root> <retained-home>
  local root=$1 home=$2 name directory
  # Pi's project settings and system prompts follow native cwd, not FM_HOME.
  # No supported per-home project-settings mapping is implemented here. Refuse
  # before replacement instead of losing home settings or importing the source
  # owner's private settings. Presence checks only: never parse, merge or copy.
  # Even equal bytes can contain relative resource paths with different meaning.
  for directory in "$root/.pi" "$home/.pi"; do
    if [ -e "$directory" ] || [ -L "$directory" ]; then
      [ -d "$directory" ] && [ ! -L "$directory" ] || {
        printf 'error: shared-code native configuration directory is not a plain directory: %s; retained files unchanged\n' "$directory" >&2
        return 1
      }
      for name in settings.json mcp.json SYSTEM.md APPEND_SYSTEM.md; do
        if [ -e "$directory/$name" ] || [ -L "$directory/$name" ]; then
          printf 'error: shared-code native configuration mapping is unresolved: %s; retained files unchanged\n' "$directory/$name" >&2
          return 1
        fi
      done
    fi
  done
  for name in fm-primary-pi-watch.ts fm-primary-turnend-guard.ts; do
    [ -f "$root/.pi/extensions/$name" ] && [ -r "$root/.pi/extensions/$name" ] || {
      printf 'error: shared-code primary extension is unavailable: %s\n' "$root/.pi/extensions/$name" >&2
      return 1
    }
  done
}
