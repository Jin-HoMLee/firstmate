#!/usr/bin/env bash
# Git push-vector evidence for the protected-upstream write guard, using a
# real local repository with real git (no network). The guard's `check`
# classifier is local-only: it must refuse before any network access.
set -u

ROOT=/Users/jin-holee/.no-mistakes/worktrees/6810fa9ca453/01M5BGB8RK8GVJP31M37NQX3YN
GUARD="$ROOT/bin/fm-upstream-write-guard.sh"
TMP=$(cd "$(mktemp -d)" && pwd -P)
repo="$TMP/repo"
remote="$TMP/remote.git"

git init -q "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" commit -q --allow-empty -m init
git init -q --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" remote add upstream git@github.com:kunchenguid/dotfiles.git
git -C "$repo" remote add someuser git@github.com:someuser/somerepo.git

echo '1. git push to the protected upstream remote is refused'
"$GUARD" check git -C "$repo" push upstream HEAD:refs/heads/test
echo "[exit=$?]"

echo
echo '2. --git-dir / --work-tree / --namespace before push fail closed'
for flag in "--git-dir=$repo/.git" "--work-tree=$repo" "--namespace=test"; do
  "$GUARD" check git -C "$repo" $flag push origin main:main
  echo "  $flag -> [exit=$?]"
done

echo
echo '3. mixed-case --config-env destination key is refused (was a bypass)'
MYURL=git@github.com:kunchenguid/dotfiles.git \
  "$GUARD" check git -C "$repo" --config-env=remote.origin.pushUrl=MYURL push origin main:main
echo "[exit=$?]"

echo
echo '4. a normal push to a non-protected local remote stays allowed'
"$GUARD" check git -C "$repo" push origin HEAD:refs/heads/test
echo "[exit=$?]"
git -C "$repo" push -q origin HEAD:refs/heads/test 2>/dev/null && echo "  (local push reached the bare remote)"

chmod -R u+w "$TMP" 2>/dev/null || true
rm -rf "$TMP"
