#!/bin/bash
# scripts/release.sh: the MusicCraftCore release sequence, up to the release commit. It STOPS
# before the tag. Tagging and pushing are Chris's word, always (CLAUDE.md red list: "Package.swift
# version or tag operations"; explicit approval before tagging and pushing).
#
# Usage:
#   scripts/release.sh <version> [--dry-run] [--title "<release title>"]
#   scripts/release.sh --help
#
# Runs from any directory (it cds to the repo root). What it does, in order:
#   1. <version> is 3-part SemVer, greater than Version.swift, not already a tag; branch is main.
#   2. git status is clean.
#   3. CHANGELOG.md has a "## [<version>]" heading (already committed, since the tree is clean).
#   4. swift test; the failure set must be a subset of .git-hooks/known-failing-tests.txt.
#   5. Bump Version.swift and the testVersionIsSet assertion in MusicCraftCoreTests.swift.
#   6. Commit: subject "release: <version> — <title>", body with the test result, then the
#      trailer lines from the RELEASE_TRAILERS env var (multi-line, optional).
#   7. Print, and never run, the next commands: tag, push, then the Sanctuary consume steps.
#
# --dry-run does 1 to 4 and prints what 5 to 7 would do. A dirty tree in dry-run mode is reported
# and swift test is skipped (the script never builds or edits a tree that is mid-change).
#
# The title comes from CHANGELOG.md: the text after the em dash on the "## [<version>]" line if it
# carries one, else on the first "### ..." heading under it (the house shape is
# "### Fixed — <what changed>"). --title overrides.
#
# Exit codes: 0 done (or dry run with every gate passing), 1 a gate refused, 2 usage.
#
# Per-app values live in the block just below. Everything else is generic.

set -uo pipefail

# ---- Per-app values (MusicCraftCore, consumed by Songwriter's Sanctuary) ----------------------
VERSION_FILE="Sources/MusicCraftCore/Version.swift"
TEST_FILE="Tests/MusicCraftCoreTests/MusicCraftCoreTests.swift"
CHANGELOG="CHANGELOG.md"
ALLOWLIST=".git-hooks/known-failing-tests.txt"
RELEASE_BRANCH="main"
REMOTE="origin"
# The consumer. Overridable: SANCTUARY_DIR=/path scripts/release.sh ...
SANCTUARY_DIR="${SANCTUARY_DIR:-/Users/chris/Documents/Code/mossgroves-songwriter-sanctuary/songwriter-sanctuary}"
SANCTUARY_PROJECT="Sanctuary.xcodeproj"
SANCTUARY_SCHEME="Sanctuary"
# -----------------------------------------------------------------------------------------------

usage() {
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

VERSION=""
DRY_RUN=0
TITLE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        --title) shift; TITLE_OVERRIDE="${1:-}" ;;
        --title=*) TITLE_OVERRIDE="${1#--title=}" ;;
        -*) echo "release.sh: unknown flag $1" >&2; usage >&2; exit 2 ;;
        *) if [[ -z "$VERSION" ]]; then VERSION="$1"; else echo "release.sh: one version only" >&2; exit 2; fi ;;
    esac
    shift
done
if [[ -z "$VERSION" ]]; then
    echo "release.sh: a version is required, e.g. scripts/release.sh 0.1.17 --dry-run" >&2
    exit 2
fi

cd "$(dirname "$0")/.." || exit 2
REPO_ROOT="$(pwd -P)"

# ---- reporting ---------------------------------------------------------------------------------
GATE_FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
skip() { printf '  SKIP  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }
# fail <message> [detail]: print the message, then the detail lines indented (the file list, the
# failing tests, the error lines). In a real run, stop right there; in a dry run, record it and
# keep reporting.
fail() {
    printf '  FAIL  %s\n' "$1"
    if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/          /'; fi
    GATE_FAILED=1
    if [[ $DRY_RUN -eq 0 ]]; then
        echo
        echo "release.sh: refused at the gate above. Nothing was changed."
        exit 1
    fi
}
heading() { printf '\n%s\n' "$*"; }

if [[ $DRY_RUN -eq 1 ]]; then
    echo "release.sh $VERSION: DRY RUN in $REPO_ROOT (gates 1 to 4 checked, nothing changed, nothing committed)"
else
    echo "release.sh $VERSION: release run in $REPO_ROOT (stops before the tag)"
fi

# ---- gate 1: the version ---------------------------------------------------------------------
heading "1. The version"
semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ "$VERSION" =~ $semver_re ]]; then
    pass "$VERSION is 3-part SemVer"
else
    fail "$VERSION is not 3-part SemVer (MAJOR.MINOR.PATCH). A patch takes the next patch number, never a 4th part: SwiftPM ignores 4-part tags."
fi

CURRENT="$(sed -nE 's/^public let musicCraftCoreVersion = "([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$VERSION_FILE" 2>/dev/null | head -1)"
if [[ -z "$CURRENT" ]]; then
    fail "could not read the current version from $VERSION_FILE"
    CURRENT="0.0.0"
else
    note "$VERSION_FILE reads $CURRENT"
fi
TEST_CURRENT="$(sed -nE 's/^[[:space:]]*XCTAssertEqual\(musicCraftCoreVersion, "([0-9]+\.[0-9]+\.[0-9]+)"\)[[:space:]]*$/\1/p' "$TEST_FILE" 2>/dev/null | head -1)"
if [[ -z "$TEST_CURRENT" ]]; then
    fail "could not find the testVersionIsSet assertion in $TEST_FILE"
elif [[ "$TEST_CURRENT" != "$CURRENT" ]]; then
    fail "the test assertion reads $TEST_CURRENT but $VERSION_FILE reads $CURRENT; they must agree before a release moves both"
else
    note "$TEST_FILE asserts $TEST_CURRENT (agrees)"
fi

# semver_gt A B: true when A > B, compared part by part as numbers.
semver_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for i in 0 1 2; do
        if (( ${a[$i]:-0} > ${b[$i]:-0} )); then return 0; fi
        if (( ${a[$i]:-0} < ${b[$i]:-0} )); then return 1; fi
    done
    return 1
}
if [[ "$VERSION" =~ $semver_re ]]; then
    if semver_gt "$VERSION" "$CURRENT"; then
        pass "$VERSION is greater than $CURRENT"
    else
        fail "$VERSION is not greater than the current $CURRENT"
    fi
fi

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
    fail "tag $VERSION already exists (git tag -l $VERSION)"
else
    pass "no tag named $VERSION yet"
fi

BRANCH="$(git branch --show-current 2>/dev/null)"
if [[ "$BRANCH" == "$RELEASE_BRANCH" ]]; then
    pass "on branch $RELEASE_BRANCH"
else
    fail "on branch '${BRANCH:-detached}', not $RELEASE_BRANCH; the pre-push hook and the printed push commands assume $RELEASE_BRANCH"
fi

# ---- gate 2: a clean tree --------------------------------------------------------------------
heading "2. The working tree"
DIRTY="$(git status --porcelain 2>/dev/null)"
TREE_CLEAN=1
if [[ -z "$DIRTY" ]]; then
    pass "git status is clean"
else
    TREE_CLEAN=0
    fail "the working tree is dirty; commit or stash first (a release commit carries only the version bump):" "$DIRTY"
fi
AHEAD="$(git rev-list --count "$REMOTE/$RELEASE_BRANCH..HEAD" 2>/dev/null || echo "?")"
if [[ "$AHEAD" != "?" && "$AHEAD" != "0" ]]; then
    note "$AHEAD commit(s) on $RELEASE_BRANCH not yet on $REMOTE; they go up with the release push"
fi

# ---- gate 3: the CHANGELOG heading -----------------------------------------------------------
heading "3. The CHANGELOG entry"
# changelog_title: the text after the first em dash on the version heading, else on the first
# "### " heading under it. Literal substring matching, so multibyte is safe in any locale.
changelog_title() {
    local in=0 line
    while IFS= read -r line; do
        if [[ "$line" == "## ["* ]]; then
            (( in )) && break
            if [[ "$line" == "## [$VERSION]"* ]]; then
                in=1
                if [[ "$line" == *"— "* ]]; then printf '%s\n' "${line#*— }"; return 0; fi
            fi
            continue
        fi
        if (( in )) && [[ "$line" == "### "* ]] && [[ "$line" == *"— "* ]]; then
            printf '%s\n' "${line#*— }"; return 0
        fi
    done < "$CHANGELOG"
    return 1
}
HEADING_LINE="$(grep -n -F "## [$VERSION]" "$CHANGELOG" 2>/dev/null | head -1 | cut -d: -f1)"
TITLE=""
if [[ -n "$HEADING_LINE" ]]; then
    pass "$CHANGELOG has \"## [$VERSION]\" at line $HEADING_LINE"
    FIRST_HEADING="$(grep -n -E '^## \[' "$CHANGELOG" | head -1 | cut -d: -f1)"
    if [[ "$FIRST_HEADING" != "$HEADING_LINE" ]]; then
        warn "it is not the first version heading (line $FIRST_HEADING is); a release entry normally heads the file"
    fi
    if [[ -n "$TITLE_OVERRIDE" ]]; then
        TITLE="$TITLE_OVERRIDE"
        note "title (from --title): $TITLE"
    elif TITLE="$(changelog_title)"; then
        note "title (after the dash in the CHANGELOG heading): $TITLE"
    else
        fail "no title found: give the version line or its first \"### ...\" heading an em dash and a title (\"### Fixed — what changed\"), or pass --title"
    fi
else
    fail "$CHANGELOG has no \"## [$VERSION]\" heading; write the entry (Keep a Changelog shape, \"## [$VERSION] - $(date +%Y-%m-%d)\" then \"### Fixed — <title>\"), commit it, and re-run"
    if [[ -n "$TITLE_OVERRIDE" ]]; then TITLE="$TITLE_OVERRIDE"; note "title (from --title): $TITLE"; fi
fi

# ---- gate 4: swift test against the allowlist --------------------------------------------------
heading "4. swift test against $ALLOWLIST"
TEST_SUMMARY="(not run)"
FAIL_COUNT="?"
if [[ ! -f "$ALLOWLIST" ]]; then
    fail "$ALLOWLIST is missing"
fi
if [[ $TREE_CLEAN -eq 0 ]]; then
    skip "swift test not run: the tree is dirty, and this script never builds a tree that is mid-change."
    note "It would have: run 'swift test' in $REPO_ROOT (several minutes), parsed every"
    note "\"Test Case '-[Class method]' failed\" line into Class/method, and compared that set with"
    note "the allowlist. New failures refuse; allowlisted tests that now pass also refuse, because the"
    note "pre-push hook blocks that push until their allowlist entries are removed."
elif [[ -f "$ALLOWLIST" ]]; then
    LOG="$(mktemp -t "mcc-release-$VERSION")"
    echo "        running swift test (several minutes; full log: $LOG)"
    swift test > "$LOG" 2>&1
    TEST_EXIT=$?
    ACTUAL_FAILURES="$(grep "Test Case.*failed" "$LOG" | \
        sed -E "s/.*'-\[([A-Za-z0-9.]+) ([a-zA-Z0-9_]+)\]'.*/\1\/\2/" | LC_ALL=C sort -u | grep -v '^$' || true)"
    EXPECTED_FAILURES="$(grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u || true)"
    NEW_FAILURES="$(LC_ALL=C comm -23 <(printf '%s\n' "$ACTUAL_FAILURES") <(printf '%s\n' "$EXPECTED_FAILURES") | grep -v '^$' || true)"
    FIXED_TESTS="$(LC_ALL=C comm -13 <(printf '%s\n' "$ACTUAL_FAILURES") <(printf '%s\n' "$EXPECTED_FAILURES") | grep -v '^$' || true)"
    TEST_SUMMARY="$(grep -E 'Executed [0-9]+ tests' "$LOG" | tail -1 | sed -E 's/^.*(Executed [0-9]+ tests, with [0-9]+ failures?).*$/\1/')"
    SKIPPED="$(grep -c "' skipped" "$LOG" || true)"
    FAIL_COUNT="$(printf '%s\n' "$ACTUAL_FAILURES" | grep -c . || true)"
    [[ -n "$TEST_SUMMARY" ]] && note "$TEST_SUMMARY, $SKIPPED skipped, $FAIL_COUNT failing"
    # A build error must be judged before the allowlist (the hook's 2026-08-26 lesson): no parsed
    # failures plus a nonzero exit is not "every listed test passes", it is "nothing ran".
    if [[ $TEST_EXIT -ne 0 && -z "$ACTUAL_FAILURES" ]]; then
        fail "swift test exited $TEST_EXIT with no failures parsed: a build error, not a test result. First error lines:" \
            "$(grep -E "error:" "$LOG" | head -5)"
    else
        if [[ -n "$NEW_FAILURES" ]]; then
            fail "new failures not in the allowlist:" "$NEW_FAILURES"
        else
            pass "the failure set is a subset of the allowlist ($FAIL_COUNT allowlisted, 0 new)"
        fi
        if [[ -n "$FIXED_TESTS" ]]; then
            fail "allowlisted tests now pass; the pre-push hook will block the push until their entries are removed from $ALLOWLIST (in their own commit, then re-run):" "$FIXED_TESTS"
        fi
    fi
fi

# ---- steps 5 to 7 ---------------------------------------------------------------------------------
TITLE_SHOWN="${TITLE:-<title from the CHANGELOG heading>}"
SUBJECT="release: $VERSION — $TITLE_SHOWN"
TODAY="$(date +%Y-%m-%d)"

build_commit_message() {
    printf '%s\n\n' "$SUBJECT"
    printf 'Version.swift and the testVersionIsSet assertion move from %s to %s together (the 0.1.16\nlesson: seven releases shipped a stale version string because only one of the two moved).\n\n' "$CURRENT" "$VERSION"
    printf 'CHANGELOG: the [%s] entry at line %s. swift test: %s; %s allowlisted failure(s), no new ones.\n' "$VERSION" "${HEADING_LINE:-?}" "$TEST_SUMMARY" "$FAIL_COUNT"
    if [[ -n "${RELEASE_TRAILERS:-}" ]]; then
        printf '\n%s\n' "$RELEASE_TRAILERS"
    fi
}

if [[ $DRY_RUN -eq 1 ]]; then
    heading "5. Would bump (not done in a dry run)"
    note "$VERSION_FILE: \"$CURRENT\" to \"$VERSION\" on the musicCraftCoreVersion line"
    note "$TEST_FILE: \"$CURRENT\" to \"$VERSION\" in XCTAssertEqual(musicCraftCoreVersion, ...)"
    heading "6. Would commit (not done in a dry run)"
    note "git add $VERSION_FILE $TEST_FILE"
    note "git commit -F <message>, where the message would be:"
    build_commit_message | sed 's/^/          | /'
    if [[ -z "${RELEASE_TRAILERS:-}" ]]; then
        warn "RELEASE_TRAILERS is not set; the house rule wants the session trailer lines (Co-Authored-By, Claude-Session) on every commit body"
    fi
else
    heading "5. Bumping the version"
    CUR_ESC="${CURRENT//./\\.}"
    sed -i '' -E "s/^(public let musicCraftCoreVersion = \")$CUR_ESC(\")/\1$VERSION\2/" "$VERSION_FILE"
    sed -i '' -E "s/^([[:space:]]*XCTAssertEqual\(musicCraftCoreVersion, \")$CUR_ESC(\"\))/\1$VERSION\2/" "$TEST_FILE"
    if grep -q "musicCraftCoreVersion = \"$VERSION\"" "$VERSION_FILE" && grep -q "XCTAssertEqual(musicCraftCoreVersion, \"$VERSION\")" "$TEST_FILE"; then
        pass "$VERSION_FILE and $TEST_FILE now read $VERSION"
    else
        git checkout -- "$VERSION_FILE" "$TEST_FILE"
        fail "the bump did not take in both files; both restored, nothing committed"
    fi

    heading "6. The release commit"
    MSG_FILE="$(mktemp -t "mcc-release-msg-$VERSION")"
    build_commit_message > "$MSG_FILE"
    if [[ -z "${RELEASE_TRAILERS:-}" ]]; then
        warn "RELEASE_TRAILERS is not set; committing without the session trailer lines"
    fi
    git add "$VERSION_FILE" "$TEST_FILE"
    if git commit -q -F "$MSG_FILE"; then
        pass "committed $(git rev-parse --short HEAD): $SUBJECT"
    else
        git reset -q HEAD -- "$VERSION_FILE" "$TEST_FILE"
        git checkout -- "$VERSION_FILE" "$TEST_FILE"
        fail "git commit failed; the bump was restored"
    fi
fi

# ---- 7. what comes next, printed and never run --------------------------------------------------
heading "7. NEXT, on Chris's word only. This script never runs these."
SANCTUARY_PIN=""
if [[ -f "$SANCTUARY_DIR/project.yml" ]]; then
    SANCTUARY_PIN="$(grep -n -E '^[[:space:]]+from: "[0-9]+\.[0-9]+\.[0-9]+"' "$SANCTUARY_DIR/project.yml" | head -1)"
fi
cat <<NEXT

  # MusicCraftCore: tag and push (in $REPO_ROOT). Both are red until he says so.
  git tag -a $VERSION -m "$VERSION — $TITLE_SHOWN (Chris's release word, $TODAY)"
  git push $REMOTE $RELEASE_BRANCH
  git push $REMOTE $VERSION
    # Two pushes, not one "git push $REMOTE $RELEASE_BRANCH --tags": the pre-push hook exits early
    # on the first non-main ref it reads, so a combined push can skip the test gate entirely
    # (MCC TASKS.md item 0, seen on the 0.1.14 release). Push main first so the hook runs.

  # Songwriter's Sanctuary: consume (in $SANCTUARY_DIR)
  edit project.yml: the MusicCraftCore package pin from: "$CURRENT" to from: "$VERSION"
NEXT
if [[ -n "$SANCTUARY_PIN" ]]; then
    printf '    # currently line %s\n' "$SANCTUARY_PIN"
fi
cat <<NEXT
    # and add a dated line to the comment block above the pin saying what $VERSION carries
  xcodegen generate
  xcodebuild -resolvePackageDependencies -project $SANCTUARY_PROJECT -scheme $SANCTUARY_SCHEME
    # confirm: grep -A3 music-craft-core $SANCTUARY_PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved shows $VERSION
  then the verify-build skill (both simulators, count arithmetic reconciled, harness pinned)

  # Sanctuary doc-sync, same session (CLAUDE.md Doc-Sync Gate):
  TECHNICAL-ARCHITECTURE.md   the "Dependency shape" line (pinned from: "...") and the status block at the top
  CHANGELOG.md                an entry: MCC $VERSION consumed (project.yml from: "$VERSION", resolved at <MCC sha>), what it carries
  dashboard.html              data.deps "MusicCraftCore version" body (resolved version + the recent line), recentlyLanded, lastUpdated
NEXT

echo
if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $GATE_FAILED -eq 1 ]]; then
        echo "release.sh $VERSION: DRY RUN finished with at least one gate refusing (see FAIL lines). Nothing was changed."
        exit 1
    fi
    echo "release.sh $VERSION: DRY RUN finished, every gate passed. Nothing was changed. Re-run without --dry-run to bump and commit."
    exit 0
fi
echo "release.sh $VERSION: done through the release commit. The tag and the push wait for Chris."
exit 0
