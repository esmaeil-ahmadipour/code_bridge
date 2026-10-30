#!/usr/bin/env bash
# dw v2 - Diff Direct Writer
# Reads diff.txt (next to this script), takes the FIRST LINE as the repo path,
# and applies the rest (a unified diff) to that repo, file by file.
# Requirements: bash, git. Works on Linux, macOS, WSL, Git Bash.

VERSION="2.0.0"
set -u

if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLD=""; RST=""
fi

die()  { echo "${RED}error:${RST} $*" >&2; exit 1; }
warn() { echo "${YLW}warn:${RST} $*"; }
info() { echo "${GRN}==>${RST} $*"; }

usage() {
  cat <<'EOF'
dw v2 - Diff Direct Writer

HOW IT WORKS
  1. Put your diff in diff.txt, in the same folder as this script.
  2. Line 1 of diff.txt = path of your repo (any drive / folder), e.g.
         C:\code\portfolio      or      ~/code/portfolio      or      /mnt/d/work/site
  3. Paste the diff below line 1.  Run:  dw

USAGE
  dw [options] [diff-file]

  diff-file   optional. Default: diff.txt next to the script, else ./diff.txt

OPTIONS
  -n, --dry-run     check only, change nothing
  -y, --yes         do not ask for confirmation
  -s, --strict      all-or-nothing: if any file cannot be applied, apply none
  -a, --archive     after a fully successful run, rename diff.txt to
                    diff.applied-<date>.txt
  -b, --branch N    create and switch to a new branch before applying
  -c, --commit MSG  commit the applied files with message MSG
  -r, --repo PATH   use PATH instead of line 1 of the diff file
  -u, --undo        revert the last run (repo from line 1, or -r PATH)
  -h, --help        this help
  -v, --version     version

Without --strict, every file is handled on its own: files that apply are
written, the others are reported (so you can ask for a fresh diff for them).
Files that are already applied are skipped, so running twice is safe.
EOF
}

# ---------- locate this script (follow symlinks) ----------
SRC="${BASH_SOURCE[0]}"
while [ -L "$SRC" ]; do
  d="$(cd -P "$(dirname "$SRC")" && pwd)"
  SRC="$(readlink "$SRC")"
  case "$SRC" in /*) ;; *) SRC="$d/$SRC" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SRC")" && pwd)"

# ---------- args ----------
DRY=0; YES=0; UNDO=0; STRICT=0; ARCHIVE=0
BRANCH=""; MSG=""; REPO_OPT=""; DIFF_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    -y|--yes)     YES=1 ;;
    -u|--undo)    UNDO=1 ;;
    -s|--strict)  STRICT=1 ;;
    -a|--archive) ARCHIVE=1 ;;
    -r|--repo)    shift; [ $# -gt 0 ] || die "-r needs a path"; REPO_OPT="$1" ;;
    -b|--branch)  shift; [ $# -gt 0 ] || die "-b needs a name"; BRANCH="$1" ;;
    -c|--commit)  shift; [ $# -gt 0 ] || die "-c needs a message"; MSG="$1" ;;
    -h|--help)    usage; exit 0 ;;
    -v|--version) echo "dw $VERSION"; exit 0 ;;
    -*)           die "unknown option: $1 (see --help)" ;;
    *)            [ -z "$DIFF_ARG" ] || die "only one diff file allowed"; DIFF_ARG="$1" ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || die "git is not installed"

# ---------- find the diff file ----------
DIFF_FILE=""
if [ -n "$DIFF_ARG" ]; then
  [ -f "$DIFF_ARG" ] || die "diff file not found: $DIFF_ARG"
  DIFF_FILE="$DIFF_ARG"
elif [ -f "$SCRIPT_DIR/diff.txt" ]; then
  DIFF_FILE="$SCRIPT_DIR/diff.txt"
elif [ -f "./diff.txt" ]; then
  DIFF_FILE="./diff.txt"
fi
if [ -z "$DIFF_FILE" ] && { [ "$UNDO" -eq 0 ] || [ -z "$REPO_OPT" ]; }; then
  die "diff.txt not found. Looked in: $SCRIPT_DIR and $(pwd)"
fi

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t dw)"
trap 'rm -rf "$WORK"' EXIT

# ---------- read diff.txt: line 1 = repo, rest = diff ----------
FIRST=""
: > "$WORK/rest"
if [ -n "$DIFF_FILE" ]; then
  if [ "$(head -c2 "$DIFF_FILE" | od -An -tx1 | tr -d ' \n')" = "fffe" ] && command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-16 -t UTF-8 "$DIFF_FILE" > "$WORK/in0"        # saved by PowerShell / Notepad as UTF-16
  else
    cp "$DIFF_FILE" "$WORK/in0"
  fi
  tr -d '\r' < "$WORK/in0" | LC_ALL=C sed '1s/^\xEF\xBB\xBF//' > "$WORK/in"
  [ -s "$WORK/in" ] || die "diff file is empty: $DIFF_FILE"
  FIRST="$(awk 'NF{print; exit}' "$WORK/in")"
  awk 'f{print; next} NF{f=1}' "$WORK/in" > "$WORK/rest"
fi

clean_path() {
  local p="$1"
  p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^([Rr][Ee][Pp][Oo]|[Pp][Aa][Tt][Hh]|[Pp][Rr][Oo][Jj][Ee][Cc][Tt])[[:space:]]*[:=][[:space:]]*//')"
  p="${p#\"}"; p="${p%\"}"; p="${p#\'}"; p="${p%\'}"
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  if printf '%s' "$p" | grep -Eq '^[A-Za-z]:[\\/]'; then
    if   command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$p")"
    elif command -v wslpath >/dev/null 2>&1; then p="$(wslpath -u "$p")"
    else die "'$p' is a Windows path but neither cygpath nor wslpath is available"; fi
  fi
  printf '%s' "$p"
}

if [ -n "$REPO_OPT" ]; then
  REPO_RAW="$REPO_OPT"
else
  case "$FIRST" in
    'diff --git'*|'--- '*|'+++ '*|'@@ '*|'```'*)
      die "line 1 of $DIFF_FILE must be the repo path, but it looks like diff content" ;;
  esac
  REPO_RAW="$FIRST"
fi
REPO_IN="$(clean_path "$REPO_RAW")"
[ -d "$REPO_IN" ] || die "repo folder not found: $REPO_IN   (from: $REPO_RAW)"
ROOT="$(git -C "$REPO_IN" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository: $REPO_IN"
GITDIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || die "cannot locate .git directory"
LAST="$GITDIR/dw-last.patch"
LASTP="$GITDIR/dw-last.p"

# ---------- undo ----------
if [ "$UNDO" -eq 1 ]; then
  [ -f "$LAST" ] || die "nothing to undo in $ROOT (no previous dw run)"
  UP="$(cat "$LASTP" 2>/dev/null || echo 1)"
  if git -C "$ROOT" apply -R -p"$UP" --whitespace=nowarn "$LAST" 2>/dev/null; then :
  elif git -C "$ROOT" apply -R -p"$UP" --ignore-whitespace --whitespace=nowarn "$LAST"; then :
  else die "could not reverse the last run (files changed since?)"; fi
  rm -f "$LAST" "$LASTP"
  info "last run reverted in $ROOT"
  git -C "$ROOT" status --short
  exit 0
fi

# ---------- extract the diff ----------
PATCH="$WORK/patch.diff"
: > "$PATCH"
if grep -q '^```' "$WORK/rest"; then
  awk '/^```+(diff|patch)/{in_=1; next} /^```+/{in_=0; next} in_{print}' "$WORK/rest" > "$PATCH"
fi
if [ ! -s "$PATCH" ]; then
  awk '/^diff --git |^--- /{p=1} p{print}' "$WORK/rest" | grep -v '^```' > "$PATCH"
fi
[ -s "$PATCH" ] || die "no unified diff found below line 1 of $DIFF_FILE"
grep -qE '^(diff --git |--- |\+\+\+ |@@ )' "$PATCH" || die "the text below line 1 does not look like a unified diff"

if grep -qE '^(diff --git a/|--- a/|\+\+\+ b/)' "$PATCH"; then P=1; else P=0; fi

# ---------- split per file ----------
CH="$WORK/chunks"; mkdir -p "$CH"
if grep -q '^diff --git ' "$PATCH"; then MODE=1; else MODE=2; fi
awk -v dir="$CH" -v mode="$MODE" '
function newchunk() { if (out != "") close(out); n++; out = sprintf("%s/%04d.diff", dir, n) }
{
  if (mode == 1) {
    if ($0 ~ /^diff --git /) newchunk()
    if (n > 0) print $0 > out
  } else {
    if (pend != "") {
      if ($0 ~ /^\+\+\+ /) { newchunk(); print pend > out; print $0 > out; pend = ""; next }
      if (n > 0) print pend > out
      pend = ""
    }
    if ($0 ~ /^--- /) { pend = $0; next }
    if (n > 0) print $0 > out
  }
}
END { if (pend != "" && n > 0) print pend > out }
' "$PATCH"
CHUNKS=( "$CH"/*.diff )
[ -e "${CHUNKS[0]}" ] || die "could not find any per-file diff"

chunk_name() {
  local f="$1" n=""
  n="$(sed -n 's/^+++ b\/\(.*\)$/\1/p' "$f" | head -n1)"
  [ -n "$n" ] || n="$(sed -n 's/^--- a\/\(.*\)$/\1/p' "$f" | head -n1)"
  [ -n "$n" ] || n="$(sed -n 's/^diff --git a\/\(.*\) b\/.*$/\1/p' "$f" | head -n1)"
  [ -n "$n" ] || n="$(sed -n 's/^+++ \([^[:space:]].*\)$/\1/p' "$f" | grep -v '^/dev/null' | head -n1)"
  printf '%s' "${n%%$'\t'*}"
}
chunk_kind() {
  if   grep -q '^new file mode' "$1";     then echo NEW
  elif grep -q '^deleted file mode' "$1"; then echo DEL
  elif grep -q '^rename from' "$1";       then echo REN
  elif grep -q '^--- /dev/null' "$1";     then echo NEW
  elif grep -q '^+++ /dev/null' "$1";     then echo DEL
  else echo MOD; fi
}
chunk_paths() {
  local out
  out="$(sed -n 's/^--- a\/\(.*\)$/\1/p; s/^+++ b\/\(.*\)$/\1/p; s/^rename from \(.*\)$/\1/p; s/^rename to \(.*\)$/\1/p' "$1" | sort -u)"
  [ -n "$out" ] || out="$(chunk_name "$1")"
  printf '%s\n' "$out"
}

# check one chunk: sets FLAG and ERR; returns 0 if it can be applied
FLAG=""; ERR=""
try_check() {
  FLAG=""
  if ERR="$(git -C "$ROOT" apply --check -p"$P" --whitespace=nowarn "$1" 2>&1)"; then return 0; fi
  if git -C "$ROOT" apply --check -p"$P" --whitespace=nowarn --ignore-whitespace "$1" >/dev/null 2>&1; then
    FLAG="--ignore-whitespace"; return 0
  fi
  return 1
}
already_applied() { git -C "$ROOT" apply --check -R -p"$P" --whitespace=nowarn "$1" >/dev/null 2>&1; }

# ---------- show the plan ----------
echo "${BLD}Diff file:${RST} $DIFF_FILE"
echo "${BLD}Repo     :${RST} $ROOT"
echo "${BLD}Files    :${RST} ${#CHUNKS[@]}"
for c in "${CHUNKS[@]}"; do echo "  [$(chunk_kind "$c")] $(chunk_name "$c")"; done
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  warn "the repo has uncommitted changes (they are left untouched)"
fi
echo

confirm() {
  [ "$YES" -eq 1 ] && return 0
  local ans=""
  printf 'Apply these changes to this repo? [Y/n] '
  if [ -r /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then read -r ans < /dev/tty
  else read -r ans || { echo; die "no terminal to ask for confirmation; use -y"; }
  fi
  case "$ans" in ""|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

if [ "$DRY" -eq 0 ]; then
  confirm || { echo "Cancelled. Nothing was changed."; exit 0; }
fi

# ---------- strict pre-check ----------
if [ "$STRICT" -eq 1 ]; then
  bad=0
  for c in "${CHUNKS[@]}"; do
    if try_check "$c" || already_applied "$c"; then :; else
      bad=$((bad+1)); echo "${RED}[FAIL]${RST} $(chunk_name "$c")"; echo "$ERR" | sed 's/^/        /'
    fi
  done
  if [ "$bad" -gt 0 ]; then
    echo; die "strict mode: $bad file(s) cannot be applied; nothing was changed"
  fi
fi

# ---------- branch ----------
if [ -n "$BRANCH" ] && [ "$DRY" -eq 0 ]; then
  git -C "$ROOT" checkout -b "$BRANCH" >/dev/null 2>&1 || die "could not create branch '$BRANCH' (already exists?)"
  info "switched to new branch $BRANCH"
fi

# ---------- apply file by file ----------
APPLIED=0; SKIPPED=0; FAILED=0
: > "$WORK/applied.patch"; : > "$WORK/applied.paths"
for c in "${CHUNKS[@]}"; do
  name="$(chunk_name "$c")"; kind="$(chunk_kind "$c")"
  if try_check "$c"; then
    note=""; [ -z "$FLAG" ] || note=" (whitespace-tolerant)"
    if [ "$DRY" -eq 1 ]; then
      echo "${GRN}[ OK ]${RST} would apply $kind $name$note"; APPLIED=$((APPLIED+1))
    elif git -C "$ROOT" apply -p"$P" --whitespace=nowarn $FLAG "$c" 2>"$WORK/err"; then
      cat "$c" >> "$WORK/applied.patch"; chunk_paths "$c" >> "$WORK/applied.paths"
      echo "${GRN}[ OK ]${RST} $kind $name$note"; APPLIED=$((APPLIED+1))
    else
      echo "${RED}[FAIL]${RST} $name"; sed 's/^/        /' "$WORK/err"; FAILED=$((FAILED+1))
    fi
  elif already_applied "$c"; then
    echo "${YLW}[SKIP]${RST} $name (already applied)"; SKIPPED=$((SKIPPED+1))
  else
    echo "${RED}[FAIL]${RST} $name"; echo "$ERR" | sed 's/^/        /'; FAILED=$((FAILED+1))
  fi
done

if [ "$DRY" -eq 0 ] && [ -s "$WORK/applied.patch" ]; then
  cp "$WORK/applied.patch" "$LAST"; echo "$P" > "$LASTP"
fi

if [ -n "$MSG" ] && [ "$DRY" -eq 0 ] && [ "$APPLIED" -gt 0 ]; then
  while IFS= read -r pth; do
    [ -n "$pth" ] && git -C "$ROOT" add -A -- "$pth" >/dev/null 2>&1
  done < "$WORK/applied.paths"
  if git -C "$ROOT" commit -q -m "$MSG"; then info "committed: $MSG"; else warn "nothing was committed"; fi
fi

echo
if [ "$DRY" -eq 1 ]; then
  echo "${BLD}Dry run:${RST} $APPLIED would apply, $SKIPPED already applied, $FAILED cannot apply (nothing was changed)"
else
  echo "${BLD}Done:${RST} $APPLIED applied, $SKIPPED skipped, $FAILED failed"
  [ "$APPLIED" -gt 0 ] && echo "Undo with: dw -u   (or: dw -u -r \"$ROOT\")"
fi
if [ "$FAILED" -gt 0 ]; then
  echo "For the failed files, send Claude their current content to get a fresh diff."
fi

if [ "$ARCHIVE" -eq 1 ] && [ "$DRY" -eq 0 ] && [ "$FAILED" -eq 0 ] && [ -n "$DIFF_FILE" ]; then
  NEWNAME="$(dirname "$DIFF_FILE")/diff.applied-$(date +%Y%m%d-%H%M%S).txt"
  mv "$DIFF_FILE" "$NEWNAME" && info "diff file archived as $(basename "$NEWNAME")"
fi

[ "$FAILED" -eq 0 ] || exit 2
exit 0
