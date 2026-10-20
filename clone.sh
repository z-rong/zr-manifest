#!/usr/bin/env bash
#
# clone.sh - clone every project listed in the manifest using plain `git clone`.
#
# For machines that have no `repo` tool installed. Reads default.xml, resolves
# <include>, <remote>, <default>, <project> and <remove-project>, then clones
# each project into its manifest path.
#
# Usage:
#   ./clone.sh [OPTIONS] [DEST_DIR]
#
# Options:
#   -b BRANCH   checkout this revision for every project (overrides manifest)
#   -d DEPTH    shallow clone depth for every project (overrides clone-depth)
#   -j JOBS     clone JOBS projects in parallel (default: 1)
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
JOBS=1
DRY_RUN=0

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
DEST=${1:-.}

[ -f "$MANIFEST" ] || { echo "error: manifest not found: $MANIFEST" >&2; exit 1; }
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo "error: -j expects a positive integer" >&2; exit 2; }
command -v python3 >/dev/null || { echo "error: python3 is required to parse the manifest" >&2; exit 1; }

# Flatten the manifest into: url <TAB> path <TAB> revision <TAB> clone-depth
PROJECTS=$(python3 -I - "$MANIFEST" <<'PY'
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

clone_one() {
    local url=$1 path=$2 rev=$3 depth=$4
    local target="$DEST/$path"

    if [ -e "$target" ]; then
        printf '%s[skip]%s %s already exists\n' "$C_WARN" "$C_OFF" "$path"
        return 0
    fi

    [ -n "$BRANCH" ] && rev=$BRANCH
    [ -n "$DEPTH" ]  && depth=$DEPTH
    [ -n "$depth" ] || depth=""

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
        printf '%s[fail]%s %s\n' "$C_ERR" "$C_OFF" "$path" >&2
        note_failure "$path"
        return 1
    fi

    if [ -n "$rev" ]; then
        if ! git -C "$target" rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
            # Not in the shallow/HEAD fetch (an older commit, or an unadvertised
            # ref): fetch it by name and let the retry below check it out.
            git -C "$target" fetch --quiet origin "$rev" 2>/dev/null || true
        fi
        if ! git -C "$target" checkout --quiet "$rev"; then
            printf '%s[fail]%s %s: cannot checkout %s\n' "$C_ERR" "$C_OFF" "$path" "$rev" >&2
            note_failure "$path"
            return 1
        fi
    fi
    printf '%s[ ok ]%s %s\n' "$C_INFO" "$C_OFF" "$path"
}

# Depth and revision are per-project; strip CR defensively for manifests edited on Windows.
while IFS=$'\t' read -r url path rev depth; do
    path=${path%$'\r'}
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
    printf '%s%d project(s) failed to clone:%s\n' "$C_ERR" "$(ls "$FAILED_DIR" | wc -l)" "$C_OFF" >&2
    cat "$FAILED_DIR"/* | sed 's/^/  - /' >&2
    exit 1
fi

echo
echo "all projects cloned into $DEST"
