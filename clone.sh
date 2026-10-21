#!/usr/bin/env bash
#
# clone.sh - clone/sync every project listed in the manifest using plain git.
#
# A stand-in for `repo sync` on machines without the repo tool (works in
# Git Bash on Windows). Reads the manifest, resolves <include>, <remote>,
# <default>, <project> and <remove-project>, then for each project:
#
#   * not on disk      -> git clone into its manifest path
#   * already on disk  -> git fetch, then move it onto its manifest revision
#                         (local branch: fast-forward; remote branch: create
#                         a local tracking branch; tag/commit: detached HEAD)
#
# Usage:
#   ./clone.sh [OPTIONS] [DEST_DIR]
#
# Like `repo sync`, projects land next to the manifest directory: running
# ./clone.sh inside zr-manifest clones into the parent directory by default.
# Pass DEST_DIR to override.
#
# Options:
#   -b BRANCH   checkout this revision for every project (overrides manifest)
#   -d DEPTH    shallow clone depth for new clones (overrides clone-depth)
#   -j JOBS     handle JOBS projects in parallel (default: 4)
#   -m FILE     manifest file to use (default: <script dir>/default.xml)
#   -n          dry run: print the git commands without running them
#   -h          show this help
#
# Examples:
#   ./clone.sh /data/home2/zengrong/WorkSpace/zr
#   ./clone.sh -j 4 -d 1 ~/src/zr
#   ./clone.sh -b main -n .
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="$SCRIPT_DIR/default.xml"
BRANCH=""
DEPTH=""
JOBS=4
DRY_RUN=0

usage() {
    cat <<'EOF'
usage: ./clone.sh [OPTIONS] [DEST_DIR]

Clone or sync every project in the manifest, mimicking `repo sync`:
  * project missing on disk  -> git clone into its manifest path
  * project already on disk  -> fetch and move it onto its manifest revision

Projects are placed next to the manifest directory (the parent of the
directory holding this script), just like a repo workspace; DEST_DIR
overrides that location.

options:
  -b BRANCH   checkout this revision for every project (overrides manifest)
  -d DEPTH    shallow clone depth for new clones (overrides clone-depth)
  -j JOBS     handle JOBS projects in parallel (default: 4)
  -m FILE     manifest file to use (default: <script dir>/default.xml)
  -n          dry run: print the git commands without running them
  -h          show this help

examples:
  ./clone.sh /data/home2/zengrong/WorkSpace/zr
  ./clone.sh -j 4 -d 1 ~/src/zr
  ./clone.sh -b main -n .
EOF
}

while getopts ":b:d:j:m:nh" opt; do
    case "$opt" in
        b) BRANCH=$OPTARG ;;
        d) DEPTH=$OPTARG ;;
        j) JOBS=$OPTARG ;;
        m) MANIFEST=$OPTARG ;;
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        \?) echo "unknown option: -$OPTARG" >&2; usage >&2; exit 2 ;;
        :)  echo "option -$OPTARG needs an argument" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
# Default workspace root: the parent of the manifest directory, matching a
# `repo` checkout where projects sit next to .repo/.
DEST=${1:-}
[ -n "$DEST" ] || DEST=$(cd "$SCRIPT_DIR/.." && pwd)

[ -f "$MANIFEST" ] || { echo "error: manifest not found: $MANIFEST" >&2; exit 1; }
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo "error: -j expects a positive integer" >&2; exit 2; }

# Windows installs often ship only `python` or the `py` launcher, no `python3`.
PYTHON_BIN=""
for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
        PYTHON_BIN=$candidate
        break
    fi
done
[ -n "$PYTHON_BIN" ] || { echo "error: python 3 is required to parse the manifest" >&2; exit 1; }

# Flatten the manifest into: url <TAB> path <TAB> revision <TAB> clone-depth
PROJECTS=$("$PYTHON_BIN" -I - "$MANIFEST" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

manifest = sys.argv[1]
projects = []          # list of dicts, in declaration order
remotes = {}           # name -> fetch url
defaults = {}          # inherited <default> attributes


def resolve_include(name):
    return os.path.normpath(os.path.join(os.path.dirname(manifest), name))


def walk(path):
    """Collect remotes/defaults/projects depth-first; <include> is merged inline."""
    for child in ET.parse(path).getroot():
        tag = child.tag
        if tag == "remote":
            remotes[child.get("name")] = child.get("fetch", "")
        elif tag == "default":
            defaults.update(child.attrib)
        elif tag == "include":
            walk(resolve_include(child.get("name")))
        elif tag == "project":
            name = child.get("name")
            if not name:
                continue
            rname = child.get("remote") or defaults.get("remote")
            fetch = remotes.get(rname, "")
            url = fetch.rstrip("/") + "/" + name if fetch else name
            projects.append({
                "name": name,
                "url": url,
                "path": child.get("path") or name,
                "revision": child.get("revision") or defaults.get("revision", ""),
                "depth": child.get("clone-depth", ""),
            })
        elif tag == "remove-project":
            name = child.get("name")
            path = child.get("path")
            projects[:] = [
                p for p in projects
                if not (p["name"] == name and (path is None or p["path"] == path))
            ]


walk(manifest)

for p in projects:
    print("\t".join((p["url"], p["path"], p["revision"] or "", p["depth"] or "")))
PY
)
# Windows python writes CRLF into pipes even when the script text is LF-only;
# strip CR so no field (notably the trailing clone-depth) carries a stray \r.
PROJECTS=${PROJECTS//$'\r'/}

[ -n "$PROJECTS" ] || { echo "error: no <project> entries in $MANIFEST" >&2; exit 1; }
mkdir -p "$DEST"

if [ -t 1 ]; then
    C_INFO=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

FAILED_DIR=$(mktemp -d)
trap 'rm -rf "$FAILED_DIR"' EXIT

# Parallel jobs write here concurrently, so each project gets its own file
# instead of appending to one shared list.
note_failure() { printf '%s\n' "$1" > "$FAILED_DIR/$(printf '%s' "$1" | tr '/' '_')"; }

fail_one() {
    printf '%s[fail]%s %s: %s\n' "$C_ERR" "$C_OFF" "$1" "$2" >&2
    note_failure "$1"
}

# Move $target onto revision $rev, mirroring what repo sync leaves behind:
#   local branch <rev>      -> check it out and fast-forward to its upstream
#   remote branch origin/<rev> -> create a local tracking branch
#   tag or commit           -> detached HEAD at <rev>
checkout_revision() {
    local target=$1 rev=$2
    if ! git -C "$target" rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
        # Not in the current fetch (an older commit, or an unadvertised ref):
        # fetch it by name and let the checks below look again.
        git -C "$target" fetch --quiet origin "$rev" 2>/dev/null || true
    fi
    if git -C "$target" show-ref --verify --quiet "refs/heads/$rev"; then
        git -C "$target" checkout --quiet "$rev" || return 1
        if git -C "$target" rev-parse --verify --quiet "@{upstream}" >/dev/null 2>&1; then
            git -C "$target" merge --quiet --ff-only || return 1
        fi
    elif git -C "$target" show-ref --verify --quiet "refs/remotes/origin/$rev"; then
        git -C "$target" checkout --quiet --track "origin/$rev" || return 1
    else
        git -C "$target" checkout --quiet "$rev" || return 1
    fi
}

# repo-sync behaviour for a project that already exists on disk.
sync_one() {
    local target=$1 rev=$2
    git -C "$target" fetch --prune --quiet origin || return 1
    if [ -z "$rev" ]; then
        # No revision pinned: fast-forward whatever branch is checked out.
        if git -C "$target" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
            git -C "$target" merge --quiet --ff-only || return 1
        fi
        return 0
    fi
    checkout_revision "$target" "$rev"
}

clone_one() {
    local url=$1 path=$2 rev=$3 depth=$4
    local target="$DEST/$path"

    [ -n "$BRANCH" ] && rev=$BRANCH
    [ -n "$DEPTH" ]  && depth=$DEPTH

    if [ -e "$target" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            printf '[sync] %s (fetch + checkout %s)\n' "$path" "${rev:-current branch}"
            return 0
        fi
        if [ ! -e "$target/.git" ]; then
            fail_one "$path" "directory exists but is not a git repository"
            return 1
        fi
        printf '%s[sync]%s %s\n' "$C_INFO" "$C_OFF" "$path"
        if ! sync_one "$target" "$rev"; then
            fail_one "$path" "sync failed (local changes or diverged branch?)"
            return 1
        fi
        printf '%s[ ok ]%s %s\n' "$C_INFO" "$C_OFF" "$path"
        return 0
    fi

    local cmd=(git clone)
    # A plain --depth clone only fetches the remote HEAD, so a manifest revision
    # on another branch would fail to check out. --no-single-branch fetches the
    # tip of every branch, which covers branch and tag revisions alike.
    if [ -n "$depth" ]; then
        cmd+=(--depth "$depth" --no-single-branch)
    fi

    if [ "$DRY_RUN" = 1 ]; then
        printf '+ (cd %q && %q' "$DEST" "${cmd[0]}"
        printf ' %q' "${cmd[@]:1}" "$url" "$path"
        [ -n "$rev" ] && printf ' && git -C %q checkout %q' "$target" "$rev"
        printf ')\n'
        return 0
    fi

    printf '%s[clone]%s %s -> %s\n' "$C_INFO" "$C_OFF" "$url" "$path"
    cmd+=("$url" "$path")
    if ! ( cd "$DEST" && "${cmd[@]}" ); then
        fail_one "$path" "clone failed"
        return 1
    fi

    if [ -n "$rev" ] && ! checkout_revision "$target" "$rev"; then
        fail_one "$path" "cannot checkout $rev"
        return 1
    fi
    printf '%s[ ok ]%s %s\n' "$C_INFO" "$C_OFF" "$path"
}

while IFS=$'\t' read -r url path rev depth; do
    if [ "$JOBS" -gt 1 ] && [ "$DRY_RUN" = 0 ]; then
        clone_one "$url" "$path" "$rev" "$depth" &
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
            wait -n || true
        done
    else
        clone_one "$url" "$path" "$rev" "$depth" || true
    fi
done <<< "$PROJECTS"

wait || true

if [ -n "$(ls -A "$FAILED_DIR")" ]; then
    echo >&2
    printf '%s%d project(s) failed:%s\n' "$C_ERR" "$(ls "$FAILED_DIR" | wc -l)" "$C_OFF" >&2
    cat "$FAILED_DIR"/* | sed 's/^/  - /' >&2
    exit 1
fi

echo
echo "all projects up to date in $DEST"
