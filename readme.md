# 🎯 Fast Commit Linter

Lint PR titles, commit messages and PR metadata against
[Conventional Commits](https://www.conventionalcommits.org/).

No Docker. No Node. No token. One bash script that runs in milliseconds, on
GitHub-hosted and self-hosted runners.

## ✨ Why use this

- ⚡️ **Instant.** A composite action with native bash regex matching. No `npm install`, no image pull.
- 🧩 **One action, three checks.** PR title, every commit in the range, and required assignee/label.
- 🤖 **Bot and draft aware.** Dependabot, Renovate, `[bot]` accounts and drafts can be skipped.
- 💥 **Breaking changes.** Supports `feat(api)!: drop v1`, which most hand-written regexes miss.
- 🔍 **Real feedback.** Each failure says why it failed and what was expected.
- 📊 **Step summary.** A Markdown table of invalid messages, plus outputs for later steps.
- 🔐 **No extra access.** No token and no permissions needed. The PR event payload has the labels and assignees.
- 🪶 **Portable.** Linux, macOS and Windows (Git Bash), bash 3.2+.

## 🚀 Quick start

```yaml
name: "🔎 Lint commits"

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # Needed to read the base commit
      - uses: HarryVasanth/fast-commit-linter@v1
        with:
          base_sha: ${{ github.event.pull_request.base.sha }}
          head_sha: ${{ github.event.pull_request.head.sha }}
```

The PR title defaults to the event title. With `base_sha` and `head_sha` set,
every commit in the PR is checked too. Without them, only the title is checked.

To check only a list of messages and skip git, pass `commit_messages`
instead:

```yaml
- uses: HarryVasanth/fast-commit-linter@v1
  with:
    commit_messages: |
      feat(api): add login endpoint
      fix: handle empty response
```

## 📥 Inputs

| Input | Description | Default |
| --- | --- | --- |
| `pr_title` | 🔖 PR title to validate | the event PR title |
| `commit_messages` | 📝 Newline-separated subjects. Overrides `base_sha`/`head_sha` | none |
| `allowed_types` | 🏷️ Comma-separated commit types | `feat,fix,docs,style,refactor,perf,test,build,ci,chore,revert` |
| `scopes` | 🔍 Comma-separated scope allowlist. Empty allows any scope | none |
| `require_scope` | 🔒 Require a scope on every message | `false` |
| `custom_regex` | 🧪 Full POSIX ERE override for the message check | none |
| `ignore_regex` | ⏭️ Subjects matching this ERE are skipped. Empty checks all | merge, revert, fixup, squash, amend |
| `ignore_bots` | 🤖 Skip dependabot, renovate, github-actions and `*[bot]` | `true` |
| `github_actor` | 🙋 Actor used for bot detection | the event actor |
| `skip_labels` | 🏷️ Comma-separated labels that skip the whole run | none |
| `assignees` | 👥 Comma-separated assignees | the event assignees |
| `require_assignees` | 🙋 Fail when the PR has no assignee | `false` |
| `labels` | 🏷️ Comma-separated labels | the event labels |
| `require_labels` | 🏷️ Fail when the PR has no label | `false` |
| `is_draft` | 📄 Whether the PR is a draft | the event draft flag |
| `ignore_drafts` | 📄 Skip draft PRs | `false` |
| `base_sha` | 🌱 Base commit. Set with `head_sha` to check the range | none |
| `head_sha` | 🌱 Head commit. Set with `base_sha` to check the range | none |
| `max_subject_length` | 📏 Max subject characters. `0` disables | `0` |

`assignees` and `labels` read the event payload. No GitHub token or API call is
made, so the action also works on fork PRs with a read-only token.

## 📤 Outputs

| Output | Description |
| --- | --- |
| `failed` | `true` when any message or required metadata check failed |
| `skipped` | `true` when the whole run was skipped (bot, draft or skip label) |
| `skip_reason` | Why the run was skipped |
| `valid_count` | Number of messages that passed |
| `invalid_count` | Number of messages that failed |
| `skipped_count` | Number of commits skipped by `ignore_regex` |
| `invalid_messages` | Newline-separated invalid messages |

```yaml
- uses: HarryVasanth/fast-commit-linter@v1
  id: lint
  with:
    pr_title: "feat(api): add login"

- if: steps.lint.outputs.failed != 'true'
  run: echo "Checked ${{ steps.lint.outputs.valid_count }} messages"
```

## ✅ What is checked

A message must look like this:

```
<type>[optional scope][!]: <description>
```

Examples that pass:

```
feat(api): add login endpoint
fix(parser)!: reject empty input
chore: bump dependencies
```

The rules:

- 🏷️ The type must be in `allowed_types`. Types are case-sensitive.
- 🔍 A scope is optional and may contain letters, digits, `_`, `.`, `/` and `-`.
- 💥 `!` may appear before the colon to mark a breaking change.
- `: ` needs exactly one space, and the description cannot start or end with whitespace.
- 📏 `max_subject_length` is opt-in. Emoji count as one character.
- ⏭️ Merge commits, `Revert "..."`, `fixup!`, `squash!` and `amend!` are skipped by default, so a
  merge does not fail the lint. Set `ignore_regex: ""` to check them.

Nothing to lint is an error. If the PR title is empty and no commits are
collected, the action fails instead of passing silently.

## 🏛️ One-step PR compliance

A compliance check often needs three things: an assignee, a label and a valid
commit format. This action does all three in one step, and it checks every
commit in the PR range, not just the last one.

```yaml
name: "📋 Check PR Compliance"

on:
  pull_request:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled, assigned, unassigned]

jobs:
  compliance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: HarryVasanth/fast-commit-linter@v1
        with:
          allowed_types: "feat,fix,docs,style,refactor,perf,test,build,ci,chore,revert,security"
          base_sha: ${{ github.event.pull_request.base.sha }}
          head_sha: ${{ github.event.pull_request.head.sha }}
          require_assignees: "true"
          require_labels: "true"
```

Because it is one action, you get:

- 🧹 Empty commit ranges handled. No phantom invalid commit.
- 💥 The `!` breaking-change marker accepted.
- 🏷️ Any type or scope list you configure, instead of a hard-coded regex.
- 📊 One step summary with per-message reasons.
- 🤖 Bots and drafts skipped without extra `if:` conditions.

To keep a project convention, set `allowed_types` and, if needed, `scopes`.
For example, `scopes: "api,ui,db"` rejects `feat(internal): ...`.

## 🧪 Examples

### ❌ Invalid title

```
🎯 Fast Commit Linter
🏷️  Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

::error::❌ Invalid PR Title: "Added login" — expected <type>[optional scope][!]: <description>
❌ Invalid PR Title: "Added login"
   ↳ expected <type>[optional scope][!]: <description>

❌ Validation failed: 1 issue(s)
   Format: <type>[optional scope][!]: <description>
   Example: feat(api): add authentication endpoint
   Example: fix!: drop the legacy schema
   Allowed types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert
```

### ⏭️ Skipped

```
🎯 Fast Commit Linter
...
::notice::✅ Skipping lint: automated account (dependabot[bot])
```

The step passes, `skipped=true`, and `skip_reason` explains why.

### 🙋 Required metadata

```
🎯 Fast Commit Linter
🏷️  Types: feat, fix, ...
::error::❌ Assignees: assign at least one assignee
❌ Assignees: assign at least one assignee

❌ Validation failed: 1 issue(s)
```

### 🏷️ Skip a PR with a label

```yaml
- uses: HarryVasanth/fast-commit-linter@v1
  with:
    skip_labels: "skip-lint,no-commit-check"
```

Label matching is case-insensitive.

## 🧰 Local use

The script reads `INPUT_*` variables, so it runs outside GitHub Actions. When
`GITHUB_OUTPUT` is not set, outputs are printed as plain lines.

```bash
INPUT_PR_TITLE="feat(api): add login" ./lint-commits.sh

INPUT_COMMIT_MESSAGES=$'fix: crash\nchore: bump deps' ./lint-commits.sh

INPUT_ALLOWED_TYPES="feat,fix,wip" \
INPUT_PR_TITLE="wip(ui): draft" \
./lint-commits.sh
```

Run the self-check (54 cases, bash 3.2 compatible):

```bash
./lint-commits.test.sh
```

## ⚠️ Limits

- 📝 `commit_messages` is one subject per line. Bodies and footers are not parsed. Set
  `base_sha`/`head_sha` to let git collect the subjects.
- 🌱 Commit collection needs `fetch-depth: 0` (or enough history) for the base commit.
  A missing SHA fails with a clear message.
- 🔎 GitHub shows at most 10 `::error::` annotations per step. Every invalid message is
  still printed to the log and the summary.
- 🧾 The step summary lists up to 50 invalid messages. The log always lists all of them.
- 🧪 `custom_regex` replaces the format check only. `max_subject_length` still applies.

## 🔐 Security

- **No runtime downloads.** The action runs the script from its own repository.
- **No token.** Labels and assignees come from the event payload.
- **Untrusted text stays text.** Titles and commit messages are never evaluated. Workflow
  commands are escaped, and Markdown table cells have pipes and backticks removed.
- **Pin a version.** Reference a release tag rather than a branch, and bump it
  deliberately:

```yaml
- uses: HarryVasanth/fast-commit-linter@v1
```
