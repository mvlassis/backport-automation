#!/usr/bin/env bash
#
# Backport helper for .github/workflows/backport-track-1.0.yml
#
# All git logic lives here rather than inline in the workflow so that it can be
# exercised locally without a GitHub round-trip. See test-backport.sh.
#
# Outputs are written to $GITHUB_OUTPUT when that variable is set (i.e. in CI),
# and to stdout otherwise.
#
# Environment:
#   TARGET_BRANCH  branch to backport onto          (default: track/1.0)
#   REMOTE         remote holding the branches      (default: origin)
#   BEFORE_SHA     push event "before" sha
#   AFTER_SHA      push event "after" sha
#
# Local usage examples:
#
#   TARGET_BRANCH=track/1.0 BEFORE_SHA=$a AFTER_SHA=$b \
#     .github/scripts/backport.sh resolve-commits
#
#   # Tier 2: tune the Copilot prompt against a real conflict, no CI minutes.
#   npm install -g @github/copilot
#   GH_TOKEN=$(gh auth token) copilot --allow-all-tools --log-level none \
#     -p "$(.github/scripts/backport.sh prompt "$sha")"

set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-track/1.0}"
REMOTE="${REMOTE:-origin}"
ZERO_SHA="0000000000000000000000000000000000000000"

# Emit "key=value" to $GITHUB_OUTPUT if set, otherwise to stdout.
emit() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

# Emit a multi-line value using a heredoc delimiter.
emit_multiline() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf '%s<<__BACKPORT_EOF__\n' "$key"
      printf '%s\n' "$value"
      printf '__BACKPORT_EOF__\n'
    } >> "$GITHUB_OUTPUT"
  else
    printf '%s<<__BACKPORT_EOF__\n%s\n__BACKPORT_EOF__\n' "$key" "$value"
  fi
}

die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# True when $1 is a merge commit.
is_merge() {
  [ "$(git rev-list --count --no-walk --merges "$1")" -gt 0 ]
}

# ---------------------------------------------------------------------------
# target-exists: does the backport target branch exist on the remote?
# ---------------------------------------------------------------------------
cmd_target_exists() {
  if git rev-parse --verify "${REMOTE}/${TARGET_BRANCH}" >/dev/null 2>&1; then
    emit exists true
  else
    printf '::warning::Branch %s does not exist, nothing to backport to.\n' "$TARGET_BRANCH"
    emit exists false
  fi
}

# ---------------------------------------------------------------------------
# resolve-commits: which commits should be backported?
#
# Normally the BEFORE_SHA..AFTER_SHA range, oldest first. Falls back to just
# AFTER_SHA when BEFORE_SHA is the all-zeros sentinel (new branch), when it is
# unknown locally (force push), or when the range contains only merge commits.
# ---------------------------------------------------------------------------
cmd_resolve_commits() {
  [ -n "${AFTER_SHA:-}" ] || die "AFTER_SHA is required"

  local before="${BEFORE_SHA:-$ZERO_SHA}" shas

  if [ "$before" = "$ZERO_SHA" ] || ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
    shas="$AFTER_SHA"
  else
    shas="$(git rev-list --reverse --no-merges "${before}..${AFTER_SHA}" || true)"
    # A merge commit at the tip still needs backporting, but --no-merges drops
    # it. Fall back to the tip so it is picked with -m 1.
    if [ -z "$shas" ]; then
      shas="$AFTER_SHA"
    fi
  fi

  emit_multiline shas "$shas"
}

# ---------------------------------------------------------------------------
# prepare-branch: create the backport branch off the target.
# ---------------------------------------------------------------------------
cmd_prepare_branch() {
  [ -n "${AFTER_SHA:-}" ] || die "AFTER_SHA is required"

  local short branch
  short="$(git rev-parse --short "$AFTER_SHA")"
  branch="backport/${TARGET_BRANCH//\//-}/${short}"

  git checkout -q -B "$branch" "${REMOTE}/${TARGET_BRANCH}"
  emit name "$branch"
}

# ---------------------------------------------------------------------------
# cherry-pick: apply each commit, stopping at the first conflict.
#
# Never fails the job: the conflict is reported via outputs so the workflow can
# hand over to Copilot.
# ---------------------------------------------------------------------------
cmd_cherry_pick() {
  local log="${CHERRY_PICK_LOG:-/tmp/cherry-pick.log}"
  local conflict=false conflict_sha="" sha rc
  local -a pick_args

  : > "$log"

  while read -r sha; do
    [ -n "$sha" ] || continue

    pick_args=()
    if is_merge "$sha"; then
      pick_args=(-m 1)
    fi

    rc=0
    git cherry-pick -x "${pick_args[@]}" "$sha" >>"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      conflict=true
      conflict_sha="$sha"
      break
    fi
  done

  cat "$log"
  emit conflict "$conflict"
  emit conflict_sha "$conflict_sha"
}

# ---------------------------------------------------------------------------
# prompt <sha>: the instruction given to the Copilot CLI.
#
# Printed by the script (rather than inlined in the workflow) so that local
# prompt tuning and CI use byte-identical text.
# ---------------------------------------------------------------------------
cmd_prompt() {
  local sha="${1:-}"
  [ -n "$sha" ] || die "usage: backport.sh prompt <sha>"

  local subject
  subject="$(git log -1 --format=%s "$sha")"

  cat <<EOF
You are inside a git repository that is in the middle of a \`git cherry-pick\` of
commit ${sha} ("${subject}") from the \`main\` branch onto the older
\`${TARGET_BRANCH}\` branch. The cherry-pick stopped because of conflicts.

Your task:
1. Inspect the situation with \`git status\`, \`git diff\`, and \`git show ${sha}\`.
2. Resolve every conflicted file. Preserve the intent of the original commit, but
   adapt it to the APIs, structure and conventions that exist on
   \`${TARGET_BRANCH}\` -- do not blindly copy the \`main\` version.
3. Do not delete unrelated code and do not leave any conflict markers
   (\`<<<<<<<\`, \`=======\`, \`>>>>>>>\`) behind.
4. \`git add\` the resolved files and run
   \`git -c core.editor=true cherry-pick --continue\`.
5. If the commit is genuinely not applicable to \`${TARGET_BRANCH}\`, run
   \`git cherry-pick --abort\` and print exactly BACKPORT_NOT_APPLICABLE.

Do not push anything, do not create pull requests, do not amend or rewrite any
other commits, and do not change branches.
EOF
}

# ---------------------------------------------------------------------------
# verify: is the working tree in a state we are willing to publish?
#
# ok=false,empty=true   -> nothing was backported (commit not applicable)
# ok=false,empty=false  -> genuine failure, the workflow opens an issue
# ---------------------------------------------------------------------------
cmd_verify() {
  if git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null \
    || [ -d "$(git rev-parse --git-path sequencer)" ]; then
    printf '::error::Cherry-pick is still in progress; the resolution did not complete.\n'
    emit ok false
    emit empty false
    return 0
  fi

  if git grep -nI -e '^<<<<<<< ' -e '^>>>>>>> ' -- . >/dev/null 2>&1; then
    printf '::error::Conflict markers remain in the tree.\n'
    emit ok false
    emit empty false
    return 0
  fi

  if [ -z "$(git log "${REMOTE}/${TARGET_BRANCH}..HEAD" --oneline)" ]; then
    printf '::warning::Nothing was backported (commit not applicable to %s).\n' "$TARGET_BRANCH"
    emit ok false
    emit empty true
    return 0
  fi

  emit ok true
  emit empty false
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    target-exists)   cmd_target_exists "$@" ;;
    resolve-commits) cmd_resolve_commits "$@" ;;
    prepare-branch)  cmd_prepare_branch "$@" ;;
    cherry-pick)     cmd_cherry_pick "$@" ;;
    prompt)          cmd_prompt "$@" ;;
    verify)          cmd_verify "$@" ;;
    *)
      printf 'usage: %s {target-exists|resolve-commits|prepare-branch|cherry-pick|prompt|verify}\n' \
        "${0##*/}" >&2
      exit 2
      ;;
  esac
}

main "$@"
