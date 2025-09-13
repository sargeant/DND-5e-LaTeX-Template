#!/usr/bin/env zsh
set -euo pipefail

# Build a fresh throwaway integration branch by merging local branches
# with an inline priority list, then all remaining branches
# (excluding dev/main/integration).
#
# Defaults:
#   base branch: main
#   integration branch name: integration
#   priority list: defined below in PRIORITY_BRANCHES
#
# Options:
#   --base <name>          Base branch to start from (default: main)
#   --branch <name>        Name of integration branch (default: integration)
#   --squash               Use squash merges
#   --push                 Push integration to origin when done
#   --reset                Recreate branch even if it exists (fresh build)
#   --no-union             Do not add union merge rule for .gitignore
#   --dry-run              Print actions without executing merges
#
# Example:
#   bin/integrate.zsh --reset --squash --push

BASE=main
TARGET=integration
SQUASH=0
PUSH=0
RESET=0
USE_UNION=1
DRYRUN=0

# Inline priority list: merged before all others if present
# Customize here as needed.
PRIORITY_BRANCHES=(
  local/gitignore-changes
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)        BASE=${2:?}; shift 2 ;;
    --branch)      TARGET=${2:?}; shift 2 ;;
    --squash)      SQUASH=1; shift ;;
    --push)        PUSH=1; shift ;;
    --reset)       RESET=1; shift ;;
    --no-union)    USE_UNION=0; shift ;;
    --dry-run)     DRYRUN=1; shift ;;
    -h|--help)
      sed -n '1,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "[integration] base=$BASE target=$TARGET squash=$SQUASH push=$PUSH reset=$RESET union=$USE_UNION dry=$DRYRUN"

git rev-parse --is-inside-work-tree >/dev/null

# Ensure clean working tree
if ! git diff-index --quiet HEAD --; then
  echo "Working tree not clean; commit or stash changes first." >&2
  exit 1
fi

# Ensure base exists
if ! git show-ref --verify --quiet refs/heads/$BASE; then
  echo "Base branch '$BASE' not found." >&2
  exit 1
fi

# Create/reset target branch from base
if git show-ref --verify --quiet refs/heads/$TARGET; then
  if [[ $RESET -eq 1 ]]; then
    echo "Resetting $TARGET to $BASE"
    git checkout "$BASE"
    git branch -D "$TARGET" || true
    git checkout -b "$TARGET" "$BASE"
  else
    echo "Using existing $TARGET (no reset). To rebuild fresh, pass --reset"
    git checkout "$TARGET"
  fi
else
  echo "Creating $TARGET from $BASE"
  git checkout -b "$TARGET" "$BASE"
fi

# Add union merge for .gitignore on integration branch only
if [[ $USE_UNION -eq 1 ]]; then
  attrfile=.gitattributes
  need_commit=0
  if [[ -f $attrfile ]]; then
    if ! rg -n "\\.gitignore merge=union" -S "$attrfile" >/dev/null 2>&1; then
      echo ".gitignore merge=union" >> "$attrfile"; need_commit=1
    fi
  else
    echo ".gitignore merge=union" > "$attrfile"; need_commit=1
  fi
  if [[ $need_commit -eq 1 && $DRYRUN -eq 0 ]]; then
    git add "$attrfile"
    git commit -m "chore(integration): prefer union merges for .gitignore"
  fi
fi

# Build ordered list: priority branches (if present) first
ORDERED=()
for p in "${PRIORITY_BRANCHES[@]}"; do
  if git show-ref --verify --quiet "refs/heads/$p"; then
    ORDERED+="$p"
  else
    echo "[note] priority branch '$p' not found; skipping"
  fi
done

# Collect remaining branches
ALL=( $(git for-each-ref --format='%(refname:short)' refs/heads) )
EXCL=( "$BASE" "$TARGET" dev )

contains() { local x=$1; shift; for y in "$@"; do [[ $x == $y ]] && return 0; done; return 1; }

REMAIN=()
for b in "${ALL[@]}"; do
  if contains "$b" "${EXCL[@]}"; then continue; fi
  if contains "$b" "${ORDERED[@]}"; then continue; fi
  REMAIN+="$b"
done

MERGE_LIST=( "${ORDERED[@]}" "${REMAIN[@]}" )

echo "Merge order (first ${#ORDERED[@]}, then ${#REMAIN[@]} others):"
for b in "${MERGE_LIST[@]}"; do echo "  - $b"; done

merge_branch() {
  local b=$1
  local msg="integration: merge $b"
  if [[ $DRYRUN -eq 1 ]]; then
    echo "[dry] git merge ${SQUASH:+--squash} --no-ff -m '$msg' $b"
    return 0
  fi
  if [[ $SQUASH -eq 1 ]]; then
    git merge --squash "$b" || true
    if git diff --cached --quiet; then
      echo "[info] nothing to commit from $b (already merged?)"
      git merge --abort >/dev/null 2>&1 || true
      return 0
    fi
    git commit -m "$msg (squash)"
  else
    set +e
    git merge --no-ff -m "$msg" "$b"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      conflicts=$(git diff --name-only --diff-filter=U || true)
      only_gitignore=0
      if [[ -n "$conflicts" ]]; then
        local cnt=$(echo "$conflicts" | wc -l | tr -d ' ')
        if [[ $cnt -eq 1 && "$conflicts" == ".gitignore" ]]; then
          only_gitignore=1
        fi
      fi
      if [[ $only_gitignore -eq 1 ]]; then
        echo "[auto] resolving .gitignore via union"
        tmp=$(mktemp)
        { git show :2:.gitignore 2>/dev/null || true; git show :3:.gitignore 2>/dev/null || true; } | sort -u > "$tmp"
        cp "$tmp" .gitignore
        rm -f "$tmp"
        git add .gitignore
        git commit -m "$msg (.gitignore union)"
      else
        echo "[error] merge conflicts in $b. Resolve manually and re-run." >&2
        exit 1
      fi
    fi
  fi
}

for b in "${MERGE_LIST[@]}"; do
  echo "\n--- merging $b ---"
  merge_branch "$b"
done

if [[ $PUSH -eq 1 && $DRYRUN -eq 0 ]]; then
  git push -u origin "$TARGET"
fi

echo "\nIntegration complete on branch '$TARGET'."

