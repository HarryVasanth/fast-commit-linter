#!/bin/bash
# Lint PR titles, commit messages and PR metadata.
#
# This is a composite action script. It needs bash and standard system tools;
# git is only used to collect commits from base_sha/head_sha.
# See action.yml for the inputs and readme.md for examples.

set -euo pipefail

# Count characters, not bytes, so emoji and accents are not penalised.
# bash 3.2 only counts characters when the locale is UTF-8.
probe='🎉'
for loc in C.UTF-8 en_US.UTF-8; do
	LC_ALL=$loc
	if [ "${#probe}" -eq 1 ]; then break; fi
done
export LC_ALL

# --- 🧾 Output helpers -------------------------------------------------------

error() { echo "::error::❌ $*" >&2; exit 1; }
warn() { echo "::warning::⚠️ $*"; }
notice() { echo "::notice::✅ $*"; }
debug() { if [ "${RUNNER_DEBUG:-}" = "1" ]; then echo "::debug::$*"; fi; }

# Escape data for a workflow command. Keep the message on one line.
gh_escape() {
	local s=${1-}
	s=${s//'%'/'%25'}
	s=${s//$'\r'/'%0D'}
	s=${s//$'\n'/'%0A'}
	printf '%s' "$s"
}

# Write one output. Print it when the script runs outside GitHub Actions.
write_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
	else
		printf '%s=%s\n' "$1" "$2"
	fi
}

# Write one multiline output. Use a random delimiter to keep the value intact.
write_multiline_output() {
	local delimiter
	delimiter="EOF_$(date +%s)_${RANDOM}${RANDOM}${RANDOM}"
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			printf '%s<<%s\n' "$1" "$delimiter"
			printf '%s\n' "$2"
			printf '%s\n' "$delimiter"
		} >>"$GITHUB_OUTPUT"
	else
		printf '%s=%s\n' "$1" "$2"
	fi
}

# --- 🔢 Input helpers -------------------------------------------------------

# Strip the CR that Windows shells can leave in env values.
strip_cr() { printf '%s' "${1//$'\r'/}"; }

# Strip surrounding whitespace. Use for config values, never for commit text.
trim() {
	local v
	v=$(strip_cr "${1-}")
	v=${v#"${v%%[![:space:]]*}"}
	v=${v%"${v##*[![:space:]]}"}
	printf '%s' "$v"
}

lower() { printf '%s' "$(trim "${1-}")" | tr '[:upper:]' '[:lower:]'; }

is_uint() { case ${1:-} in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Read a whole number. Set $NUM. Stop on a bad value.
num() {
	local raw=${2:-} min=${4:-0}
	if [ -z "$raw" ]; then
		raw=$3
	fi
	raw=$(trim "$raw")
	is_uint "$raw" || error "$1 must be a non-negative integer"
	[ ${#raw} -le 9 ] || error "$1 must be 999999999 or less"
	NUM=$((10#$raw))
	if [ "$NUM" -lt "$min" ]; then
		error "$1 must be at least $min"
	fi
}

# Parse a boolean. Set $BOOL.
bool() {
	case $(lower "${2:-}") in
	true | 1 | yes | on) BOOL=true ;;
	false | 0 | no | off | '') BOOL=false ;;
	*) error "$1 must be true or false" ;;
	esac
}

# Split a comma-separated list. Set $ITEMS to the non-empty trimmed entries.
ITEMS=()
split_list() {
	local item
	local -a parts
	ITEMS=()
	if [ -z "${1-}" ]; then
		return 0
	fi
	IFS=',' read -ra parts <<<"$1"
	for item in "${parts[@]}"; do
		item=$(trim "$item")
		if [ -n "$item" ]; then
			ITEMS+=("$item")
		fi
	done
}

# Compare a list entry against a value, ignoring case.
list_has() {
	local needle item
	if [ -z "${1-}" ]; then
		return 1
	fi
	needle=$(lower "${2-}")
	split_list "$1"
	if [ ${#ITEMS[@]} -eq 0 ]; then
		return 1
	fi
	for item in "${ITEMS[@]}"; do
		if [ "$(lower "$item")" = "$needle" ]; then
			return 0
		fi
	done
	return 1
}

list_count() {
	split_list "${1-}"
	printf '%s' "${#ITEMS[@]}"
}

alternation() {
	local out='' x
	for x in "$@"; do
		out+="$x|"
	done
	printf '%s' "${out%|}"
}

join_by() {
	local sep=$1 out='' x
	shift
	for x in "$@"; do
		out+="$x$sep"
	done
	printf '%s' "${out%"$sep"}"
}

join_lines() {
	local out='' x
	for x in "$@"; do
		out+="$x"$'\n'
	done
	printf '%s' "${out%$'\n'}"
}

# Make a value safe for a Markdown table cell inside backticks.
md_cell() {
	local s=${1-} pipe='|' tick='`'
	s=${s//$'\r'/}
	s=${s//$'\n'/ }
	s=${s//$pipe/\\|}
	s=${s//$tick/\'}
	printf '%s' "$s"
}

# Stop on a malformed regex instead of silently matching nothing.
# A bad regex makes [[ =~ ]] return 2 instead of 1 (no match).
check_regex() {
	local rc
	set +e
	[[ "" =~ $2 ]]
	rc=$?
	set -e
	if [ "$rc" -eq 2 ]; then
		error "$1 is not a valid extended regex: $2"
	fi
}

# --- 📥 Inputs --------------------------------------------------------------

PR_TITLE=$(strip_cr "${INPUT_PR_TITLE:-}")
COMMIT_MESSAGES=$(strip_cr "${INPUT_COMMIT_MESSAGES:-}")

ALLOWED_TYPES=$(trim "${INPUT_ALLOWED_TYPES:-}")
if [ -z "$ALLOWED_TYPES" ]; then
	ALLOWED_TYPES="feat,fix,docs,style,refactor,perf,test,build,ci,chore,revert"
fi

CUSTOM_REGEX=$(trim "${INPUT_CUSTOM_REGEX:-}")
SCOPES=$(trim "${INPUT_SCOPES:-}")
SKIP_LABELS=$(trim "${INPUT_SKIP_LABELS:-}")
BRANCH=$(trim "${INPUT_BRANCH:-}")
IGNORE_BRANCHES=$(trim "${INPUT_IGNORE_BRANCHES:-}")
ASSIGNEES=$(trim "${INPUT_ASSIGNEES:-}")
LABELS=$(trim "${INPUT_LABELS:-}")
ACTOR=$(trim "${INPUT_GITHUB_ACTOR:-}")
BASE_SHA=$(trim "${INPUT_BASE_SHA:-}")
HEAD_SHA=$(trim "${INPUT_HEAD_SHA:-}")
DESCRIPTION_CASE=$(lower "${INPUT_DESCRIPTION_CASE:-any}")
case $DESCRIPTION_CASE in
any | lower | upper) ;;
*) error "description_case must be any, lower or upper" ;;
esac

# An empty ignore_regex disables the skips. An unset one gets the defaults.
if [ -z "${INPUT_IGNORE_REGEX+x}" ]; then
	IGNORE_REGEX='^(Merge |Revert "|fixup! |squash! |amend! )'
else
	IGNORE_REGEX=$(trim "${INPUT_IGNORE_REGEX}")
fi

bool ignore_bots "${INPUT_IGNORE_BOTS:-true}"
IGNORE_BOTS=$BOOL
bool require_assignees "${INPUT_REQUIRE_ASSIGNEES:-false}"
REQUIRE_ASSIGNEES=$BOOL
bool require_labels "${INPUT_REQUIRE_LABELS:-false}"
REQUIRE_LABELS=$BOOL
bool require_scope "${INPUT_REQUIRE_SCOPE:-false}"
REQUIRE_SCOPE=$BOOL
bool ignore_drafts "${INPUT_IGNORE_DRAFTS:-false}"
IGNORE_DRAFTS=$BOOL
bool is_draft "${INPUT_IS_DRAFT:-false}"
IS_DRAFT=$BOOL
bool check_pr_title "${INPUT_CHECK_PR_TITLE:-true}"
CHECK_PR_TITLE=$BOOL
bool allow_empty "${INPUT_ALLOW_EMPTY:-false}"
ALLOW_EMPTY=$BOOL

num max_subject_length "${INPUT_MAX_SUBJECT_LENGTH:-}" 0 0
MAX_SUBJECT_LENGTH=$NUM
if [ "$MAX_SUBJECT_LENGTH" -gt 0 ] && [ "${#probe}" -ne 1 ]; then
	warn "no UTF-8 locale found: max_subject_length counts bytes, not characters"
fi

# A half-set commit range is a config error, even when commit_messages is used.
if { [ -n "$BASE_SHA" ] && [ -z "$HEAD_SHA" ]; } || { [ -z "$BASE_SHA" ] && [ -n "$HEAD_SHA" ]; }; then
	error "base_sha and head_sha must be set together"
fi

# --- 🧩 Pattern -------------------------------------------------------------

TYPES=()
SCOPE_LIST=()

if [ -n "$CUSTOM_REGEX" ]; then
	REGEX=$CUSTOM_REGEX
	check_regex custom_regex "$REGEX"
else
	split_list "$ALLOWED_TYPES"
	if [ ${#ITEMS[@]} -eq 0 ]; then
		error "allowed_types must contain at least one type"
	fi
	for t in "${ITEMS[@]}"; do
		[[ $t =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] ||
			error "invalid type '$t': use letters, digits, '_' or '-', starting with a letter"
		TYPES+=("$t")
	done

	SCOPE_PATTERN='[A-Za-z0-9_./-]+'
	if [ -n "$SCOPES" ]; then
		split_list "$SCOPES"
		if [ ${#ITEMS[@]} -eq 0 ]; then
			error "scopes must contain at least one scope"
		fi
		for s in "${ITEMS[@]}"; do
			[[ $s =~ ^[A-Za-z0-9_./-]+$ ]] ||
				error "invalid scope '$s': use letters, digits, '_', '.', '/' or '-'"
			SCOPE_LIST+=("$s")
		done
		if [ ${#SCOPE_LIST[@]} -gt 0 ]; then
			SCOPE_PATTERN="($(alternation "${SCOPE_LIST[@]}"))"
		fi
	fi

	if [ "$REQUIRE_SCOPE" = true ]; then
		SCOPE_GROUP="(\($SCOPE_PATTERN\))"
	else
		SCOPE_GROUP="(\($SCOPE_PATTERN\))?"
	fi

	REGEX="^($(alternation "${TYPES[@]}"))$SCOPE_GROUP(!)?: [^[:space:]](.*[^[:space:]])?$"
fi

if [ -n "$IGNORE_REGEX" ]; then
	check_regex ignore_regex "$IGNORE_REGEX"
fi

if [ -n "$CUSTOM_REGEX" ] && { [ -n "$SCOPES" ] || [ "$REQUIRE_SCOPE" = true ]; }; then
	warn "scopes and require_scope are ignored when custom_regex is set"
fi

debug "regex=$REGEX ignore_regex=$IGNORE_REGEX"

# --- 📊 State ---------------------------------------------------------------

VALID=0
INVALID=0
SKIPPED=0
ISSUES=0
SKIP_REASON=
SUMMARY_ROWS=()
INVALID_LABELS=()
INVALID_MSGS=()
INVALID_REASONS=()
SKIPPED_MSGS=()

emit_outputs() { # <failed> <skipped>
	if [ "$1" = true ]; then
		write_output result failed
	elif [ "$2" = true ]; then
		write_output result skipped
	else
		write_output result passed
	fi
	write_output valid_count "$VALID"
	write_output invalid_count "$INVALID"
	write_output skipped_count "$SKIPPED"
	write_output checked_count "$((VALID + INVALID))"
	write_output failed "$1"
	write_output skipped "$2"
	write_output skip_reason "$SKIP_REASON"
	if [ ${#INVALID_MSGS[@]} -gt 0 ]; then
		write_multiline_output invalid_messages "$(join_lines "${INVALID_MSGS[@]}")"
	else
		write_output invalid_messages ""
	fi
}

emit_summary() {
	local i rest
	if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
		return 0
	fi
	{
		echo "### 🎯 Commit Linter"
		echo
		if [ ${#SUMMARY_ROWS[@]} -gt 0 ]; then
			echo "| Check | Result | Detail |"
			echo "| --- | --- | --- |"
			printf '%s\n' "${SUMMARY_ROWS[@]}"
			echo
		fi
		printf '**Messages:** ✅ %s valid · ⏭️ %s skipped · ❌ %s invalid\n' \
			"$VALID" "$SKIPPED" "$INVALID"
		if [ ${#INVALID_MSGS[@]} -gt 0 ]; then
			echo
			echo "| Invalid message | Reason |"
			echo "| --- | --- |"
			for i in "${!INVALID_MSGS[@]}"; do
				if [ "$i" -ge 50 ]; then
					break
				fi
				# shellcheck disable=SC2016 # backticks are Markdown, not a command
				printf '| `%s` | `%s` |\n' \
					"$(md_cell "${INVALID_MSGS[$i]}")" \
					"$(md_cell "${INVALID_REASONS[$i]}")"
			done
			rest=$((${#INVALID_MSGS[@]} - 50))
			if [ "$rest" -gt 0 ]; then
				echo
				echo "_…and $rest more in the step log._"
			fi
		fi
		if [ ${#SKIPPED_MSGS[@]} -gt 0 ]; then
			echo
			echo "| Skipped message |"
			echo "| --- |"
			for i in "${!SKIPPED_MSGS[@]}"; do
				if [ "$i" -ge 50 ]; then
					break
				fi
				# shellcheck disable=SC2016 # backticks are Markdown, not a command
				printf '| `%s` |\n' "$(md_cell "${SKIPPED_MSGS[$i]}")"
			done
			rest=$((${#SKIPPED_MSGS[@]} - 50))
			if [ "$rest" -gt 0 ]; then
				echo
				echo "_…and $rest more in the step log._"
			fi
		fi
	} >>"$GITHUB_STEP_SUMMARY"
}

skip_run() { # <reason>
	SKIP_REASON=$1
	SUMMARY_ROWS+=("| Overall | ⏭️ | $(md_cell "$1") |")
	notice "Skipping lint: $1"
	emit_outputs false true
	emit_summary
	exit 0
}

# --- 🎯 Banner --------------------------------------------------------------

echo "🎯 Fast Commit Linter"
if [ -n "$CUSTOM_REGEX" ]; then
	printf '🔧 Pattern: %s\n' "$CUSTOM_REGEX"
else
	printf '🏷️  Types: %s\n' "$(join_by ', ' "${TYPES[@]}")"
	if [ ${#SCOPE_LIST[@]} -gt 0 ]; then
		printf '🔍 Scopes: %s\n' "$(join_by ', ' "${SCOPE_LIST[@]}")"
	fi
fi
if [ "$MAX_SUBJECT_LENGTH" -gt 0 ]; then
	printf '📏 Max subject length: %d\n' "$MAX_SUBJECT_LENGTH"
fi
if [ "$DESCRIPTION_CASE" != any ]; then
	printf '🔠 Description case: %s\n' "$DESCRIPTION_CASE"
fi
if [ -n "$IGNORE_BRANCHES" ]; then
	printf '🌿 Skip branches: %s\n' "$IGNORE_BRANCHES"
fi
if [ "$CHECK_PR_TITLE" = false ]; then
	echo "🙈 PR title: not checked"
fi

# --- ⏭️ Skip rules -----------------------------------------------------------

if [ "$IGNORE_DRAFTS" = true ] && [ "$IS_DRAFT" = true ]; then
	skip_run "draft pull request"
fi

if [ -n "$IGNORE_BRANCHES" ] && [ -n "$BRANCH" ]; then
	split_list "$IGNORE_BRANCHES"
	for pattern in "${ITEMS[@]+"${ITEMS[@]}"}"; do
		# shellcheck disable=SC2053 # branch patterns are globs on purpose
		if [[ $BRANCH == $pattern ]]; then
			skip_run "branch '$BRANCH' matches '$pattern'"
		fi
	done
fi

if [ "$IGNORE_BOTS" = true ] && [ -n "$ACTOR" ]; then
	case $(lower "$ACTOR") in
	*dependabot* | *renovate* | *github-actions* | *"[bot]"* | copilot*)
		skip_run "automated account ($ACTOR)"
		;;
	esac
fi

if [ -n "$SKIP_LABELS" ]; then
	split_list "$SKIP_LABELS"
	SKIP_LIST=()
	if [ ${#ITEMS[@]} -gt 0 ]; then
		SKIP_LIST=("${ITEMS[@]}")
	fi
	for label in "${SKIP_LIST[@]+"${SKIP_LIST[@]}"}"; do
		if list_has "$LABELS" "$label"; then
			skip_run "label '$label' is present"
		fi
	done
fi

# --- 📝 Collect messages ----------------------------------------------------

MESSAGES=()

collect_commits() {
	local base head mb line
	command -v git >/dev/null 2>&1 || error "git is required to collect commits from base_sha/head_sha"
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
		error "not a git repository: run actions/checkout before this action"
	base=$(git rev-parse --verify --quiet "${BASE_SHA}^{commit}") ||
		error "base_sha '$BASE_SHA' is not available locally: use actions/checkout with fetch-depth: 0"
	head=$(git rev-parse --verify --quiet "${HEAD_SHA}^{commit}") ||
		error "head_sha '$HEAD_SHA' is not available locally: use actions/checkout with fetch-depth: 0"
	mb=$(git merge-base "$base" "$head" 2>/dev/null) || mb=$base
	while IFS= read -r line; do
		if [ -n "$line" ]; then
			MESSAGES+=("$line")
		fi
	done < <(git log --format=%s "$mb..$head")
}

if [ -n "$COMMIT_MESSAGES" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(strip_cr "$line")
		if [ -n "$(trim "$line")" ]; then
			MESSAGES+=("$line")
		fi
	done <<<"$COMMIT_MESSAGES"
fi

# commit_messages wins when it has content. A blank list falls back to the range.
if [ ${#MESSAGES[@]} -eq 0 ] && [ -n "$BASE_SHA" ]; then
	collect_commits
	if [ ${#MESSAGES[@]} -eq 0 ]; then
		warn "no commits found between base_sha and head_sha"
	fi
fi

if [ ${#MESSAGES[@]} -eq 0 ] && { [ "$CHECK_PR_TITLE" = false ] || [ -z "$PR_TITLE" ]; }; then
	if [ "$ALLOW_EMPTY" = true ]; then
		skip_run "nothing to lint (allow_empty is on)"
	fi
	error "nothing to lint: set pr_title, commit_messages, or base_sha + head_sha"
fi

# --- 🔎 Checks --------------------------------------------------------------

check_required_list() { # <check> <csv> <enabled> <hint>
	local n
	if [ "$3" != true ]; then
		return 0
	fi
	n=$(list_count "$2")
	if [ "$n" -eq 0 ]; then
		ISSUES=$((ISSUES + 1))
		SUMMARY_ROWS+=("| $1 | ❌ | $4 |")
		echo "::error::❌ $1: $4" >&2
		printf '❌ %s: %s\n' "$1" "$4"
		return 0
	fi
	SUMMARY_ROWS+=("| $1 | ✅ | $n |")
	printf '✅ %s: %d\n' "$1" "$n"
}

check_required_list "Assignees" "$ASSIGNEES" "$REQUIRE_ASSIGNEES" "assign at least one assignee"
check_required_list "Labels" "$LABELS" "$REQUIRE_LABELS" "add at least one label"

# Print why a subject is invalid. Return 0 when there is a problem.
subject_problem() {
	local subject=$1
	if [[ ! $subject =~ $REGEX ]]; then
		if [ -n "$CUSTOM_REGEX" ]; then
			printf 'does not match custom_regex'
		elif [ "$REQUIRE_SCOPE" = true ]; then
			printf 'expected <type>(scope)[!]: <description> (a scope is required)'
		else
			printf 'expected <type>[optional scope][!]: <description>'
		fi
		return 0
	fi
	# Count characters, not bytes, so emoji subjects are not penalised.
	if [ "$MAX_SUBJECT_LENGTH" -gt 0 ] && [ "${#subject}" -gt "$MAX_SUBJECT_LENGTH" ]; then
		printf 'subject is %d characters, max is %d' "${#subject}" "$MAX_SUBJECT_LENGTH"
		return 0
	fi
	if [ "$DESCRIPTION_CASE" != any ]; then
		case $subject in
		*": "*) ;;
		*)
			# No ": " delimiter, so custom_regex owns the format.
			return 1
			;;
		esac
		local first want
		first=${subject#*: }
		first=${first:0:1}
		case $first in
		[A-Za-z]) ;;
		*) return 1 ;; # non-ASCII letters are left alone
		esac
		if [ "$DESCRIPTION_CASE" = lower ]; then
			want=$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')
		else
			want=$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')
		fi
		if [ "$first" != "$want" ]; then
			printf 'description must start with a %s-case letter (got %s)' "$DESCRIPTION_CASE" "$first"
			return 0
		fi
	fi
	return 1
}

check_message() { # <label> <subject>
	local label=$1 subject=$2 reason
	if reason=$(subject_problem "$subject"); then
		INVALID=$((INVALID + 1))
		INVALID_LABELS+=("$label")
		INVALID_MSGS+=("$subject")
		INVALID_REASONS+=("$reason")
		echo "::error::❌ Invalid $label: \"$(gh_escape "$subject")\" — $reason" >&2
		printf '❌ Invalid %s: "%s"\n   ↳ %s\n' "$label" "$subject" "$reason"
	else
		VALID=$((VALID + 1))
		printf '✅ Valid %s: "%s"\n' "$label" "$subject"
	fi
}

check_subject() { # <label> <subject>
	local label=$1 subject
	subject=$(strip_cr "${2%%$'\n'*}")
	if [ -n "$IGNORE_REGEX" ] && [[ $subject =~ $IGNORE_REGEX ]]; then
		SKIPPED=$((SKIPPED + 1))
		SKIPPED_MSGS+=("$subject")
		printf '⏭️  Skipped %s: "%s"\n' "$label" "$subject"
		return 0
	fi
	check_message "$label" "$subject"
}

# --- 🚀 Run -----------------------------------------------------------------

if [ "$CHECK_PR_TITLE" = true ] && [ -n "$PR_TITLE" ]; then
	echo
	check_subject "PR Title" "$PR_TITLE"
fi

if [ ${#MESSAGES[@]} -gt 0 ]; then
	echo
	echo "::group::📝 Checking ${#MESSAGES[@]} commit message(s)"
	for message in "${MESSAGES[@]}"; do
		check_subject "Commit" "$message"
	done
	echo "::endgroup::"
fi

TOTAL_ISSUES=$((INVALID + ISSUES))

if [ "$TOTAL_ISSUES" -gt 0 ]; then
	echo
	printf '❌ Validation failed: %d issue(s)\n' "$TOTAL_ISSUES"
	echo "   Format: <type>[optional scope][!]: <description>"
	echo "   Example: feat(api): add authentication endpoint"
	echo "   Example: fix!: drop the legacy schema"
	if [ -n "$CUSTOM_REGEX" ]; then
		printf '   Pattern: %s\n' "$CUSTOM_REGEX"
	else
		printf '   Allowed types: %s\n' "$(join_by ', ' "${TYPES[@]}")"
		if [ ${#SCOPE_LIST[@]} -gt 0 ]; then
			printf '   Allowed scopes: %s\n' "$(join_by ', ' "${SCOPE_LIST[@]}")"
		fi
	fi
	emit_outputs true false
	emit_summary
	exit 1
fi

echo
if [ "$VALID" -gt 0 ] || [ "$SKIPPED" -gt 0 ]; then
	notice "Validation passed: ✅ $VALID valid · ⏭️ $SKIPPED skipped"
else
	notice "Validation passed"
fi
emit_outputs false false
emit_summary
exit 0
