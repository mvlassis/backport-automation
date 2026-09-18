#!/usr/bin/env bash
#
# Local test harness for backport.sh.
#
# Builds throwaway repositories under $TMPDIR and asserts every branch of the
# backport logic. No network access, no GitHub, runs in about a second.
#
#   .github/scripts/test-backport.sh
#
# Exits non-zero if any case fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKPORT="${SCRIPT_DIR}/backport.sh"

PASS=0
FAIL=0
CURRENT=""

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

start() {
  CURRENT="$1"
  printf '\n\033[1m== %s\033[0m\n' "$CURRENT"
}

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$desc"
  else
    bad "$desc (expected '$expected', got '$actual')"
  fi
}

# Run a backport.sh subcommand capturing outputs into a file, then read a key.
# Usage: run_bp <outfile> <subcommand> [args...]
run_bp() {
  local outfile="$1"; shift
  : > "$outfile"
  GITHUB_OUTPUT="$outfile" "$BACKPORT" "$@" >/dev/null 2>&1
}

# Read a single-line key from a GITHUB_OUTPUT-style file.
out_get() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

# Read a heredoc-style multiline key.
out_get_multi() {
  local file="$1" key="$2"
  awk -v k="${key}<<__BACKPORT_EOF__" '
    $0 == k { inblock = 1; next }
    inblock && $0 == "__BACKPORT_EOF__" { inblock = 0; next }
    inblock { print }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Fixture: a repo with `main` and a diverged `track/1.0`, plus a bare origin.
#
# Layout on both branches: shared.txt (identical) and api.txt (diverged, so
# edits to it conflict).
# ---------------------------------------------------------------------------
make_fixture() {
  local root bare work
  root="$(mktemp -d)"
  bare="${root}/origin.git"
  work="${root}/work"

  git init -q --bare "$bare"
  git init -q -b main "$work"

  (
    cd "$work" || exit 1
    git config user.email test@example.com
    git config user.name "Test User"
    git config commit.gpgsign false
    git remote add origin "$bare"

    printf 'shared\n' > shared.txt
    printf 'v2-api\n' > api.txt
    git add .
    git commit -qm "base"

    git checkout -q -b track/1.0
    printf 'v1-api\n' > api.txt
    git commit -qam "track/1.0: older api"

    git checkout -q main
    git push -q origin main track/1.0
  )

  printf '%s\n' "$work"
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

case_clean_pick() {
  start "clean cherry-pick"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'feature\n' > feature.txt
  git add .
  git commit -qm "add feature"
  local before after
  after="$(git rev-parse HEAD)"
  before="$(git rev-parse HEAD~1)"

  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  run_bp "$o" target-exists
  assert_eq "target branch detected" "true" "$(out_get "$o" exists)"

  run_bp "$o" resolve-commits
  assert_eq "one commit resolved" "$after" "$(out_get_multi "$o" shas)"

  run_bp "$o" prepare-branch
  assert_eq "branch name" "backport/track-1.0/$(git rev-parse --short "$after")" "$(out_get "$o" name)"

  out_get_multi "$o" shas > /dev/null
  printf '%s\n' "$after" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1
  assert_eq "no conflict" "false" "$(out_get "$o" conflict)"

  run_bp "$o" verify
  assert_eq "verify ok" "true" "$(out_get "$o" ok)"
  assert_eq "not empty" "false" "$(out_get "$o" empty)"
}

case_conflict_unresolved() {
  start "conflict left unresolved"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'v3-api\n' > api.txt
  git commit -qam "bump api"
  local after; after="$(git rev-parse HEAD)"

  local before; before="$(git rev-parse HEAD~1)"
  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  run_bp "$o" prepare-branch
  printf '%s\n' "$after" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1
  assert_eq "conflict reported" "true" "$(out_get "$o" conflict)"
  assert_eq "conflict sha reported" "$after" "$(out_get "$o" conflict_sha)"

  run_bp "$o" verify
  assert_eq "verify rejects in-progress pick" "false" "$(out_get "$o" ok)"
  assert_eq "not flagged empty" "false" "$(out_get "$o" empty)"
}

case_markers_committed() {
  start "conflict resolved but markers committed"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'v3-api\n' > api.txt
  git commit -qam "bump api"
  local after; after="$(git rev-parse HEAD)"

  local before; before="$(git rev-parse HEAD~1)"
  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  run_bp "$o" prepare-branch
  printf '%s\n' "$after" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1

  # Simulate a careless resolution: stage the file with markers intact.
  git add api.txt
  git -c core.editor=true cherry-pick --continue >/dev/null 2>&1

  run_bp "$o" verify
  assert_eq "verify rejects markers" "false" "$(out_get "$o" ok)"
  assert_eq "not flagged empty" "false" "$(out_get "$o" empty)"
}

case_conflict_resolved() {
  start "conflict resolved properly"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'v3-api\n' > api.txt
  git commit -qam "bump api"
  local after; after="$(git rev-parse HEAD)"

  local before; before="$(git rev-parse HEAD~1)"
  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  run_bp "$o" prepare-branch
  printf '%s\n' "$after" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1

  printf 'v1-api-patched\n' > api.txt
  git add api.txt
  git -c core.editor=true cherry-pick --continue >/dev/null 2>&1

  run_bp "$o" verify
  assert_eq "verify ok" "true" "$(out_get "$o" ok)"
  assert_eq "not empty" "false" "$(out_get "$o" empty)"
}

case_aborted() {
  start "cherry-pick aborted (not applicable)"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'v3-api\n' > api.txt
  git commit -qam "bump api"
  local after; after="$(git rev-parse HEAD)"

  local before; before="$(git rev-parse HEAD~1)"
  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  run_bp "$o" prepare-branch
  printf '%s\n' "$after" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1
  git cherry-pick --abort

  run_bp "$o" verify
  assert_eq "verify not ok" "false" "$(out_get "$o" ok)"
  assert_eq "flagged empty" "true" "$(out_get "$o" empty)"
}

case_merge_commit() {
  start "merged PR backports the side commits individually"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  git checkout -q -b side
  printf 'side\n' > side.txt
  git add .
  git commit -qm "side work"
  local side; side="$(git rev-parse HEAD)"
  git checkout -q main
  git merge -q --no-ff side -m "merge side"
  local after before
  after="$(git rev-parse HEAD)"
  before="$(git rev-parse HEAD^1)"

  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  # The range is not empty: --no-merges yields the branch's own commits, which
  # are cleaner to cherry-pick than the merge itself.
  run_bp "$o" resolve-commits
  assert_eq "side commit selected, not the merge" "$side" "$(out_get_multi "$o" shas)"

  run_bp "$o" prepare-branch
  printf '%s\n' "$side" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1
  assert_eq "picked without conflict" "false" "$(out_get "$o" conflict)"

  run_bp "$o" verify
  assert_eq "verify ok" "true" "$(out_get "$o" ok)"

  assert_eq "side.txt backported" "side" "$(cat side.txt 2>/dev/null)"
}

case_merge_tip_mainline() {
  start "merge tip with no range falls back to -m 1"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  git checkout -q -b side
  printf 'side\n' > side.txt
  git add .
  git commit -qm "side work"
  git checkout -q main
  git merge -q --no-ff side -m "merge side"
  local after; after="$(git rev-parse HEAD)"

  # Zero sentinel forces the fallback to the tip, which is a merge commit and so
  # must be picked with -m 1 (a bare cherry-pick of a merge errors out).
  export TARGET_BRANCH=track/1.0 AFTER_SHA="$after"
  export BEFORE_SHA="0000000000000000000000000000000000000000"
  local o="${work}/out"

  run_bp "$o" resolve-commits
  assert_eq "falls back to merge tip" "$after" "$(out_get_multi "$o" shas)"

  run_bp "$o" prepare-branch
  printf '%s\n' "$after" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1
  assert_eq "merge picked without conflict" "false" "$(out_get "$o" conflict)"

  run_bp "$o" verify
  assert_eq "verify ok" "true" "$(out_get "$o" ok)"
  assert_eq "side.txt backported" "side" "$(cat side.txt 2>/dev/null)"
}

case_zero_sentinel() {
  start "all-zeros before sha"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'feature\n' > feature.txt
  git add .
  git commit -qm "add feature"
  local after; after="$(git rev-parse HEAD)"

  export TARGET_BRANCH=track/1.0 AFTER_SHA="$after"
  export BEFORE_SHA="0000000000000000000000000000000000000000"
  local o="${work}/out"

  run_bp "$o" resolve-commits
  assert_eq "falls back to after sha" "$after" "$(out_get_multi "$o" shas)"
}

case_unknown_before() {
  start "unknown before sha (force push)"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  printf 'feature\n' > feature.txt
  git add .
  git commit -qm "add feature"
  local after; after="$(git rev-parse HEAD)"

  export TARGET_BRANCH=track/1.0 AFTER_SHA="$after"
  export BEFORE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  local o="${work}/out"

  run_bp "$o" resolve-commits
  assert_eq "falls back to after sha" "$after" "$(out_get_multi "$o" shas)"
}

case_multi_commit() {
  start "multi-commit push stops at first conflict"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  local before; before="$(git rev-parse HEAD)"

  printf 'one\n' > one.txt
  git add .
  git commit -qm "commit one"
  local c1; c1="$(git rev-parse HEAD)"

  printf 'v3-api\n' > api.txt
  git commit -qam "conflicting api bump"
  local c2; c2="$(git rev-parse HEAD)"

  printf 'three\n' > three.txt
  git add .
  git commit -qm "commit three"
  local after; after="$(git rev-parse HEAD)"

  export TARGET_BRANCH=track/1.0 BEFORE_SHA="$before" AFTER_SHA="$after"
  local o="${work}/out"

  run_bp "$o" resolve-commits
  local shas; shas="$(out_get_multi "$o" shas)"
  assert_eq "three commits, oldest first" "$(printf '%s\n%s\n%s' "$c1" "$c2" "$after")" "$shas"

  run_bp "$o" prepare-branch
  printf '%s\n' "$shas" | GITHUB_OUTPUT="$o" CHERRY_PICK_LOG="${work}/cp.log" \
    "$BACKPORT" cherry-pick >/dev/null 2>&1
  assert_eq "conflict reported" "true" "$(out_get "$o" conflict)"
  assert_eq "stops on second commit" "$c2" "$(out_get "$o" conflict_sha)"
  assert_eq "first commit applied" "one" "$(cat one.txt 2>/dev/null)"
  assert_eq "third commit not applied" "" "$(cat three.txt 2>/dev/null)"
}

case_missing_target() {
  start "missing target branch"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  local head; head="$(git rev-parse HEAD)"
  export TARGET_BRANCH=track/9.9 AFTER_SHA="$head"
  local o="${work}/out"

  run_bp "$o" target-exists
  assert_eq "absent branch detected" "false" "$(out_get "$o" exists)"
}

case_prompt() {
  start "prompt generation"
  local work; work="$(make_fixture)"
  cd "$work" || exit 1

  local sha; sha="$(git rev-parse HEAD)"
  export TARGET_BRANCH=track/1.0

  local prompt; prompt="$("$BACKPORT" prompt "$sha")"

  if printf '%s' "$prompt" | grep -q "$sha"; then
    ok "prompt mentions the sha"
  else
    bad "prompt mentions the sha"
  fi

  if printf '%s' "$prompt" | grep -q 'track/1.0'; then
    ok "prompt mentions the target branch"
  else
    bad "prompt mentions the target branch"
  fi

  if printf '%s' "$prompt" | grep -q 'BACKPORT_NOT_APPLICABLE'; then
    ok "prompt defines the abort sentinel"
  else
    bad "prompt defines the abort sentinel"
  fi
}

# ---------------------------------------------------------------------------

main() {
  [ -x "$BACKPORT" ] || chmod +x "$BACKPORT"

  case_clean_pick
  case_conflict_unresolved
  case_markers_committed
  case_conflict_resolved
  case_aborted
  case_merge_commit
  case_merge_tip_mainline
  case_zero_sentinel
  case_unknown_before
  case_multi_commit
  case_missing_target
  case_prompt

  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
