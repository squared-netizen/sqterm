#!/usr/bin/env bash
# vendor_framework.sh: copy the squared framework from the package into
# sqterm. The one direction framework code travels: package -> sqterm.
#
#   tools/vendor_framework.sh              the package commit in SQUARED_REV
#   tools/vendor_framework.sh --latest     the package's last commit; records it
#   tools/vendor_framework.sh --dry-run    say what would happen
#
# Options:
#   --package DIR   the squared resources repo
#                   (default ~/projects/squared-pg/resources/.squared)
#   --force         replace squared/ even if it differs from the package
#                   commit it came from (it is backed up first)
#
# sqterm's copy of squared-examples' tool, for a repo that is one workspace
# (squared/ at its root) rather than a folder of them. The same policy: the
# package is the only place framework code changes, so this takes committed
# package code only (git archive of a commit), stops if squared/ differs from
# the commit it came from (SQUARED_REV; --force overrides, with a backup), and
# writes only the files that changed, keeping the framework's build output
# (every directory under squared/build/). It also updates
# mk/pkg_squared_core.mk, which the package owns, and SQUARED_REV. Commit all
# three.
#
# Runs from anywhere: the repo is found from this script's own path.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PKG_REPO=$HOME/projects/squared-pg/resources/.squared
TREE=packages/package.squared-core/tree
LATEST=0
DRY=0
FORCE=0
need() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case $1 in
    --latest) LATEST=1 ;;
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --package) need "$@"; PKG_REPO=$2; shift ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
die() { printf 'stop: %s\n' "$*" >&2; exit 1; }
read_rev() { if [ -f "$1" ]; then tr -d ' \t\r\n' <"$1"; fi; }

git -C "$PKG_REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || die "no squared repo at $PKG_REPO (pass --package DIR)"
git -C "$PKG_REPO" cat-file -e "HEAD:$TREE/squared" 2>/dev/null \
  || die "$PKG_REPO has no $TREE/squared at HEAD"
[ -d "$here/sq_app" ] || die "$here is not a squared workspace (no sq_app/)"

# A framework tree's files, skipping build output, the marker and backups.
fw_files() {
  (cd "$1" && find . \( \( -path './build/*' -type d \) -o -path ./.vendored-rev \
    -o -name '*.bak.*' \) -prune -o -type f -print | LC_ALL=C sort)
}

STAMP=$(date +%Y%m%d-%H%M%S)-$$
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sqvendor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# sync_tree <from> <to> <backup dir>: make <to> hold exactly <from>'s files
# (build output aside), writing only those that differ.
sync_tree() {
  local from=$1 to=$2 backup=$3 f changed=0 added=0 removed=0 kept=0
  fw_files "$from" >"$TMP/new"
  fw_files "$to" >"$TMP/old"
  while IFS= read -r f; do
    if [ -f "$to/$f" ] && cmp -s "$from/$f" "$to/$f"; then
      kept=$((kept + 1))
      continue
    fi
    if [ -f "$to/$f" ]; then
      changed=$((changed + 1))
      mkdir -p "$(dirname "$backup/$f")"
      cp -p "$to/$f" "$backup/$f"
    else
      added=$((added + 1))
    fi
    mkdir -p "$(dirname "$to/$f")"
    rm -f "$to/$f"
    # Not cp -p: a written file is new now, so make rebuilds what uses it.
    cp "$from/$f" "$to/$f"
    if [ -x "$from/$f" ]; then chmod 755 "$to/$f"; else chmod 644 "$to/$f"; fi
  done <"$TMP/new"
  while IFS= read -r f; do
    removed=$((removed + 1))
    mkdir -p "$(dirname "$backup/$f")"
    mv "$to/$f" "$backup/$f"
  done < <(LC_ALL=C comm -13 "$TMP/new" "$TMP/old")
  find "$to" \( -path "$to/build/*" -type d \) -prune -o \
    -type d -empty -print 2>/dev/null | LC_ALL=C sort -r | while IFS= read -r d; do
    [ "$d" = "$to" ] || rmdir "$d" 2>/dev/null || true
  done
  echo "  squared/: $changed changed, $added new, $removed removed, $kept unchanged (build output kept)"
  [ $((changed + removed)) = 0 ] || echo "  replaced and removed files backed up to ${backup#"$HOME"/}"
}

echo "== sqterm"
if [ "$LATEST" = 1 ]; then
  rev=$(git -C "$PKG_REPO" rev-parse HEAD)
  if [ -n "$(git -C "$PKG_REPO" status --porcelain -- "$TREE")" ]; then
    echo "  note: the package has uncommitted changes; they are not taken. Commit them first."
  fi
else
  [ -f "$here/SQUARED_REV" ] || die "no SQUARED_REV; run with --latest to take the package's last commit and record it"
  want=$(read_rev "$here/SQUARED_REV")
  [ -n "$want" ] || die "SQUARED_REV is empty"
  rev=$(git -C "$PKG_REPO" rev-parse --verify -q "$want^{commit}") \
    || die "commit $want (from SQUARED_REV) is not in $PKG_REPO; pull it, or use --latest"
fi
short=${rev:0:7}

# The framework copy must be the package commit it came from.
if [ -d "$here/squared" ]; then
  came_from=$(read_rev "$here/SQUARED_REV")
  [ -n "$came_from" ] || came_from=$(git -C "$PKG_REPO" rev-parse HEAD)
  drift=""
  if ! git -C "$PKG_REPO" cat-file -e "$came_from^{commit}" 2>/dev/null; then
    drift="  (SQUARED_REV names ${came_from:0:7}, which is not in $PKG_REPO)"
  else
    rm -rf "$TMP/was"; mkdir -p "$TMP/was"
    git -C "$PKG_REPO" archive --format=tar "$came_from" "$TREE/squared" | tar -x -C "$TMP/was"
    fw_files "$TMP/was/$TREE/squared" >"$TMP/want"
    fw_files "$here/squared" >"$TMP/have"
    drift=$({
      LC_ALL=C comm -23 "$TMP/want" "$TMP/have" | sed 's|^\./|  missing   |'
      LC_ALL=C comm -13 "$TMP/want" "$TMP/have" | sed 's|^\./|  added     |'
      LC_ALL=C comm -12 "$TMP/want" "$TMP/have" | while IFS= read -r f; do
        cmp -s "$TMP/was/$TREE/squared/$f" "$here/squared/$f" || printf '  changed   %s\n' "${f#./}"
      done
    } | head -8 || true) # head may close the pipe early: not a failure
  fi
  if [ -n "$drift" ]; then
    if [ "$FORCE" = 0 ]; then
      printf '%s\n' "$drift" >&2
      die "squared/ is not the package commit it came from. Framework changes go in the package first; move them there, or rerun with --force to discard them (a backup is kept)"
    fi
    echo "  --force: replacing squared/ despite local changes (backed up)"
  fi
fi

rm -rf "$TMP/x"; mkdir -p "$TMP/x"
git -C "$PKG_REPO" archive --format=tar "$rev" "$TREE/squared" "$TREE/mk/pkg_squared_core.mk" | tar -x -C "$TMP/x"
[ -f "$TMP/x/$TREE/squared/build/common.mk" ] || die "package commit $short has no squared/build/common.mk"

current=$(read_rev "$here/SQUARED_REV")
if [ "$current" = "$rev" ] && [ -f "$here/squared/build/common.mk" ] && [ "$FORCE" = 0 ]; then
  echo "  squared/ already at $short"
else
  echo "  squared/ <- package $short$([ -n "$current" ] && [ "$current" != "$rev" ] && echo " (was ${current:0:7})")"
  if [ "$DRY" = 0 ]; then
    if [ -d "$here/squared" ]; then
      sync_tree "$TMP/x/$TREE/squared" "$here/squared" "$HOME/.cache/squared-template-backups/$STAMP/sqterm/squared"
    else
      mv "$TMP/x/$TREE/squared" "$here/squared"
    fi
  fi
fi

if ! cmp -s "$TMP/x/$TREE/mk/pkg_squared_core.mk" "$here/mk/pkg_squared_core.mk"; then
  echo "  mk/pkg_squared_core.mk <- package $short"
  if [ "$DRY" = 0 ]; then
    mkdir -p "$here/mk"
    cp "$TMP/x/$TREE/mk/pkg_squared_core.mk" "$here/mk/pkg_squared_core.mk"
  fi
fi

if [ "$(read_rev "$here/SQUARED_REV")" != "$rev" ]; then
  echo "  SQUARED_REV <- $short"
  [ "$DRY" = 1 ] || printf '%s\n' "$rev" >"$here/SQUARED_REV"
fi

if [ "$DRY" = 1 ]; then
  echo "== dry run: nothing changed"
else
  echo "== next: commit squared/, SQUARED_REV and mk/ in sqterm"
fi
