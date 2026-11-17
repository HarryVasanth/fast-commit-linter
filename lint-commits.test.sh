#!/bin/bash
# Self-check for lint-commits.sh. Run: ./lint-commits.test.sh
# Uses bash 3.2-safe syntax so it also runs on macOS.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/lint-commits.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '✅ %s\n' "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '❌ %s\n   %s\n' "$1" "$2"
	if [ -n "${OUT:-}" ]; then
		printf '%s\n' "$OUT" | sed 's/^/   | /'
	fi
}

# run <expected-exit> <needle-or-empty> <description> [VAR=value...]
run() {
	local expected=$1 needle=$2 desc=$3
	shift 3
	OUT=$(env -i PATH="$PATH" HOME="${HOME:-}" "$@" "$SCRIPT" 2>&1)
	CODE=$?
	if [ "$CODE" -ne "$expected" ]; then
		fail "$desc" "expected exit $expected, got $CODE"
	elif [ -n "$needle" ] && [[ $OUT != *"$needle"* ]]; then
		fail "$desc" "output does not contain: $needle"
	else
		pass "$desc"
	fi
}

# --- 🎯 Conventional Commits ------------------------------------------------

run 0 "" "valid title" 'INPUT_PR_TITLE=feat(auth): add login'
run 0 "" "breaking change marker" 'INPUT_PR_TITLE=feat(api)!: drop v1'
run 0 "" "emoji subject" 'INPUT_PR_TITLE=feat: 🎉 add party mode'
run 1 "" "plain sentence is rejected" 'INPUT_PR_TITLE=Added login'
run 1 "" "missing space after colon" 'INPUT_PR_TITLE=feat:add login'
run 1 "" "empty description" 'INPUT_PR_TITLE=feat: '
run 1 "" "double space after colon" 'INPUT_PR_TITLE=feat:  add login'
run 1 "" "trailing space" 'INPUT_PR_TITLE=feat: add login '
run 1 "" "unknown type" 'INPUT_PR_TITLE=wip: draft'
run 1 "" "uppercase type" 'INPUT_PR_TITLE=Feat: add login'
run 1 "" "empty scope" 'INPUT_PR_TITLE=feat(): add login'
run 0 "" "slash in scope" 'INPUT_PR_TITLE=feat(api/v2): add login'

# --- 🏷️ Types and scopes ----------------------------------------------------

run 0 "" "custom types" 'INPUT_ALLOWED_TYPES=feat,wip' 'INPUT_PR_TITLE=wip(ui): draft'
run 0 "" "spaces in type list" 'INPUT_ALLOWED_TYPES=feat, fix' 'INPUT_PR_TITLE=fix: crash'
run 1 "" "regex chars in type rejected" 'INPUT_ALLOWED_TYPES=feat|x' 'INPUT_PR_TITLE=feat: x'
run 1 "invalid type" "bad type error" 'INPUT_ALLOWED_TYPES=feat,(bad' 'INPUT_PR_TITLE=feat: x'
run 1 "at least one type" "comma-only type list" 'INPUT_ALLOWED_TYPES=,' 'INPUT_PR_TITLE=feat: x'
run 0 "" "scope allowlist match" 'INPUT_SCOPES=api,ui' 'INPUT_PR_TITLE=feat(api): x'
run 1 "" "scope allowlist miss" 'INPUT_SCOPES=api,ui' 'INPUT_PR_TITLE=feat(db): x'
run 1 "at least one scope" "comma-only scope list" 'INPUT_SCOPES=,' 'INPUT_PR_TITLE=feat: x'
run 1 "scope is required" "scope required" 'INPUT_REQUIRE_SCOPE=true' 'INPUT_PR_TITLE=feat: x'
run 0 "" "scope required, present" 'INPUT_REQUIRE_SCOPE=true' 'INPUT_PR_TITLE=feat(api): x'

# --- 📏 Length and custom regex ---------------------------------------------

run 0 "" "subject at max length" 'INPUT_MAX_SUBJECT_LENGTH=10' 'INPUT_PR_TITLE=feat: abcd'
run 1 "" "subject over max length" 'INPUT_MAX_SUBJECT_LENGTH=10' 'INPUT_PR_TITLE=feat: abcde'
run 1 "must be a non-negative integer" "bad length input" 'INPUT_MAX_SUBJECT_LENGTH=-1' 'INPUT_PR_TITLE=feat: x'
run 0 "" "custom regex match" 'INPUT_CUSTOM_REGEX=^[A-Z]+: .+' 'INPUT_PR_TITLE=ABC: x'
run 1 "" "custom regex miss" 'INPUT_CUSTOM_REGEX=^[A-Z]+: .+' 'INPUT_PR_TITLE=abc: x'
run 1 "not a valid extended regex" "invalid custom regex" 'INPUT_CUSTOM_REGEX=([a-z' 'INPUT_PR_TITLE=feat: x'

# --- 📝 Commit messages -----------------------------------------------------

run 0 "" "valid commit list" $'INPUT_COMMIT_MESSAGES=fix: a\nchore: b'
run 1 "" "invalid commit list" $'INPUT_COMMIT_MESSAGES=fix: a\nupdate stuff'
run 0 "" "CRLF commit list" $'INPUT_COMMIT_MESSAGES=fix: a\r\nchore: b\r'
run 0 "" "merge commit ignored" 'INPUT_COMMIT_MESSAGES=Merge branch main'
run 0 "" "revert commit ignored" 'INPUT_COMMIT_MESSAGES=Revert "feat: x"'
run 1 "" "merge commit checked when ignore off" 'INPUT_IGNORE_REGEX=' 'INPUT_COMMIT_MESSAGES=Merge branch main'
run 0 "" "empty commit list with title" 'INPUT_COMMIT_MESSAGES=' 'INPUT_PR_TITLE=feat: x'
run 0 "" "zero-one-edu types" 'INPUT_ALLOWED_TYPES=add,delete,update,fix,bump,security,refactor,style,test,docs,chore,perf,ci,build,revert' 'INPUT_PR_TITLE=add(api): thing'
run 1 "nothing to lint" "no input at all"

# --- ⏭️ Skips ---------------------------------------------------------------

run 0 "" "bot skipped" 'INPUT_GITHUB_ACTOR=dependabot[bot]' 'INPUT_PR_TITLE=Bad title'
run 1 "" "bot check disabled" 'INPUT_IGNORE_BOTS=false' 'INPUT_GITHUB_ACTOR=dependabot[bot]' 'INPUT_PR_TITLE=Bad title'
run 0 "" "skip label" 'INPUT_LABELS=skip-lint,bug' 'INPUT_SKIP_LABELS=skip-lint' 'INPUT_PR_TITLE=Bad title'
run 1 "" "skip label absent" 'INPUT_LABELS=bug' 'INPUT_SKIP_LABELS=skip-lint' 'INPUT_PR_TITLE=Bad title'
run 0 "" "comma-only skip labels" 'INPUT_SKIP_LABELS=,' 'INPUT_PR_TITLE=feat: x'
run 0 "" "draft skipped" 'INPUT_IGNORE_DRAFTS=true' 'INPUT_IS_DRAFT=true' 'INPUT_PR_TITLE=Bad title'
run 1 "" "draft checked when not ignored" 'INPUT_IS_DRAFT=true' 'INPUT_PR_TITLE=Bad title'

# --- 🙋 Required metadata ---------------------------------------------------

run 1 "assign at least one assignee" "assignee required" 'INPUT_REQUIRE_ASSIGNEES=true' 'INPUT_PR_TITLE=feat: x'
run 0 "" "assignee present" 'INPUT_REQUIRE_ASSIGNEES=true' 'INPUT_ASSIGNEES=alice' 'INPUT_PR_TITLE=feat: x'
run 1 "add at least one label" "label required" 'INPUT_REQUIRE_LABELS=true' 'INPUT_PR_TITLE=feat: x'
run 0 "" "label present" 'INPUT_REQUIRE_LABELS=true' 'INPUT_LABELS=bug' 'INPUT_PR_TITLE=feat: x'

# --- 🌱 Commit range collection ---------------------------------------------

repo="$TMP/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'feat: one'
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'bad two'
head=$(git -C "$repo" rev-parse HEAD)

OUT=$(cd "$repo" && env -i PATH="$PATH" HOME="${HOME:-}" \
	INPUT_BASE_SHA="$base" INPUT_HEAD_SHA="$head" "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 1 ]; then pass "collected range fails on bad commit"; else fail "collected range fails on bad commit" "exit $CODE"; fi

OUT=$(cd "$repo" && env -i PATH="$PATH" HOME="${HOME:-}" \
	INPUT_PR_TITLE='fix: ok' INPUT_BASE_SHA="$base" INPUT_HEAD_SHA="$base" "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 0 ]; then pass "empty range still lints title"; else fail "empty range still lints title" "exit $CODE"; fi

OUT=$(cd "$repo" && env -i PATH="$PATH" HOME="${HOME:-}" \
	INPUT_BASE_SHA=deadbeef INPUT_HEAD_SHA="$head" "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 1 ] && [[ $OUT == *"not available locally"* ]]; then
	pass "missing sha gives a clear error"
else
	fail "missing sha gives a clear error" "exit $CODE"
fi

OUT=$(cd "$repo" && env -i PATH="$PATH" HOME="${HOME:-}" \
	INPUT_BASE_SHA="$base" "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 1 ] && [[ $OUT == *"must be set together"* ]]; then
	pass "base_sha without head_sha fails"
else
	fail "base_sha without head_sha fails" "exit $CODE"
fi

# --- 📤 Outputs and summary -------------------------------------------------

outfile="$TMP/outputs"
sumfile="$TMP/summary"
env -i PATH="$PATH" HOME="${HOME:-}" GITHUB_OUTPUT="$outfile" GITHUB_STEP_SUMMARY="$sumfile" \
	INPUT_PR_TITLE='bad title' "$SCRIPT" >/dev/null 2>&1 || true

if grep -q '^failed=true$' "$outfile" && grep -q '^invalid_count=1$' "$outfile"; then
	pass "writes failed and invalid_count outputs"
else
	fail "writes failed and invalid_count outputs" "outputs: $(cat "$outfile")"
fi
if grep -q 'bad title' "$sumfile"; then
	pass "writes invalid message to step summary"
else
	fail "writes invalid message to step summary" "summary: $(cat "$sumfile")"
fi

# --- 🏁 Result --------------------------------------------------------------

echo
printf '✅ %d passed · ❌ %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
