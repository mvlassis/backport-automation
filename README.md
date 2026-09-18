# backport-automation

Automatically backports commits landing on `main` to the `track/1.0` maintenance
branch. When a cherry-pick conflicts, the [Copilot CLI][copilot-cli] is invoked
to resolve it before the pull request is opened.

## How it works

1. A push to `main` triggers `.github/workflows/backport-track-1.0.yml`.
2. The commits in the pushed range are resolved, oldest first, and replayed onto
   a new `backport/track-1.0/<short-sha>` branch cut from `track/1.0`.
3. If every commit applies cleanly, a PR is opened against `track/1.0` with the
   `backport` label.
4. If a cherry-pick conflicts, the Copilot CLI is installed and given the
   conflicted worktree with instructions to adapt the change to the older
   branch's APIs. The resulting PR is additionally labelled `copilot-assisted`
   and `needs-review`.
5. If the conflict cannot be resolved, an issue is opened with the cherry-pick
   and Copilot logs, and the run fails.

A commit whose message contains `[skip backport]` is ignored.

## Setup

Add a `COPILOT_CLI_TOKEN` repository secret: a PAT with `repo`, `workflow` and
`copilot` scopes. It is used for checkout, push, PR and issue creation, and to
authenticate the Copilot CLI. Using a PAT rather than the built-in
`GITHUB_TOKEN` means CI still runs on the backport PRs.

Create these labels if they don't already exist:

```bash
gh label create backport         --description "Backport to a maintenance branch"      --color 1d76db
gh label create copilot-assisted --description "Conflicts resolved by the Copilot CLI" --color 8250df
gh label create needs-review     --description "Requires careful human review"         --color d93f0b
```

The workflow fails if a label is missing; this is deliberate, so a
Copilot-authored PR can never be published without its review flag.

## Layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/backport-track-1.0.yml` | Workflow definition; a thin wrapper around the script below |
| `.github/scripts/backport.sh` | All git logic, as discrete subcommands |
| `.github/scripts/test-backport.sh` | Local test harness for `backport.sh` |

The git logic lives in a script rather than inline in the YAML so that it can be
tested without a GitHub round-trip.

## Testing

The layers below are ordered by cost. Work through them in order; only the last
one needs the network.

**Static analysis** — catches invalid `${{ }}` expressions, bad step references
and shell bugs in every `run:` block:

```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
```

**Unit tests** — builds throwaway repositories under `$TMPDIR` and asserts each
path (clean pick, unresolved conflict, committed conflict markers, resolved
conflict, aborted pick, merge commits, force-push and new-branch sentinels,
multi-commit pushes). No network, about a second:

```bash
.github/scripts/test-backport.sh
```

**Prompt tuning** — iterate on the Copilot prompt against a real conflict
without spending CI minutes. Build a conflicted worktree, then run the exact
command the workflow uses:

```bash
npm install -g @github/copilot
GH_TOKEN=$(gh auth token) copilot --allow-all-tools --log-level none \
  -p "$(.github/scripts/backport.sh prompt "$sha")"
```

Use a realistic conflict, such as a renamed API on `track/1.0`. Trivial one-line
conflicts resolve regardless of prompt quality and give false confidence.

**End to end** — `workflow_dispatch` accepts `sha` and `before_sha` inputs so a
run can be replayed against any commit. Without it every retry would need a
fresh push, since `push` events cannot be replayed:

```bash
gh workflow run backport-track-1.0.yml -f sha=<sha>
gh run watch
```

Test a clean cherry-pick first to validate auth, push and PR creation before
spending anything on the Copilot path. Between runs, delete the
`backport/track-1.0/*` branches and close the PRs they opened.

[copilot-cli]: https://github.com/github/copilot-cli
