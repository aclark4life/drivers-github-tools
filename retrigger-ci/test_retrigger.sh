#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/retrigger.sh"
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=1
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected to find: $needle"
    echo "  in: $haystack"
    FAIL=1
  fi
}

# A fake gh that answers the three read queries from canned files and logs every
# call. The read queries apply the caller's own --jq to the canned JSON, so the
# real filters are exercised rather than a copy of them that could drift.
FAKE_GH="$TMPDIR/gh"
cat > "$FAKE_GH" <<FAKE_GH_EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMPDIR/gh_calls.log"
jq_of() {
  local expr=""
  while [ \$# -gt 0 ]; do
    if [ "\$1" = "--jq" ]; then expr="\$2"; fi
    shift
  done
  printf '%s' "\$expr"
}
case "\$1 \$2" in
  "pr view")  jq -r "\$(jq_of "\$@")" "$TMPDIR/pr_view.json" ;;
  "run list") jq -r "\$(jq_of "\$@")" "$TMPDIR/run_list.json" ;;
  "workflow list") jq -r "\$(jq_of "\$@")" "$TMPDIR/workflow_list.json" ;;
esac
FAKE_GH_EOF
chmod +x "$FAKE_GH"
export PATH="$TMPDIR:$PATH"

STATUS=0
run_script() {
  : > "$TMPDIR/gh_calls.log"
  STATUS=0
  KIND="${KIND:-}" PR="${PR:-}" REF="${REF:-}" \
  GH_TOKEN="fake-token" GH_REPO="mongodb/django-mongodb-backend" \
  WORKFLOW_PATTERN="${WORKFLOW_PATTERN:-test-python*}" \
  EVERGREEN_COMMENT="${EVERGREEN_COMMENT:-evergreen retry}" \
  DRY_RUN="${DRY_RUN:-false}" \
    bash "$SCRIPT" > "$TMPDIR/output.log" 2>&1 || STATUS=$?
}

log() { cat "$TMPDIR/output.log"; }
gh_call() { grep "^$1" "$TMPDIR/gh_calls.log" || true; }
# Every state-changing gh command. A dry run must produce none of them.
mutating_calls() { grep -E '^(pr comment|run rerun|workflow run)' "$TMPDIR/gh_calls.log" || true; }

# Canned responses, overridden per case.
echo '{"state":"OPEN","headRefOid":"a4787d0"}' > "$TMPDIR/pr_view.json"
echo '[]' > "$TMPDIR/run_list.json"
echo '[]' > "$TMPDIR/workflow_list.json"

echo "--- kind: evergreen"

KIND=evergreen PR=422 REF= run_script
check "evergreen: succeeds on an open PR" "0" "$STATUS"
check "evergreen: posts the retry comment" \
  "pr comment 422 --body evergreen retry" "$(gh_call 'pr comment')"

KIND=evergreen PR=422 REF= EVERGREEN_COMMENT="evergreen retry --ui" run_script
check "evergreen: the comment body is configurable" \
  "pr comment 422 --body evergreen retry --ui" "$(gh_call 'pr comment')"

# Evergreen ignores a retry comment on a closed or merged PR, so the comment
# would post and nothing would happen. That silent success is the whole failure
# mode this ticket exists to avoid.
echo '{"state":"CLOSED","headRefOid":"a4787d0"}' > "$TMPDIR/pr_view.json"
KIND=evergreen PR=422 REF= EVERGREEN_COMMENT= run_script
check "evergreen: a closed PR fails" "1" "$STATUS"
check "evergreen: a closed PR gets no comment" "" "$(mutating_calls)"
check_contains "evergreen: a closed PR explains why" \
  "not open; Evergreen will not re-run" "$(log)"

echo '{"state":"MERGED","headRefOid":"a4787d0"}' > "$TMPDIR/pr_view.json"
KIND=evergreen PR=422 REF= run_script
check "evergreen: a merged PR fails" "1" "$STATUS"
check "evergreen: a merged PR gets no comment" "" "$(mutating_calls)"

echo '{"state":"OPEN","headRefOid":"a4787d0"}' > "$TMPDIR/pr_view.json"
DRY_RUN=true KIND=evergreen PR=422 REF= run_script
check "evergreen + dry run: no mutating gh call" "" "$(mutating_calls)"
check_contains "evergreen + dry run: the intended call is logged" \
  "Would run: gh pr comment 422" "$(log)"

echo "--- kind: pr"

cat > "$TMPDIR/run_list.json" <<'JSON'
[
  {"databaseId": 1, "path": ".github/workflows/test-python.yml"},
  {"databaseId": 2, "path": ".github/workflows/test-python-atlas.yml"},
  {"databaseId": 3, "path": ".github/workflows/release-python.yml"},
  {"databaseId": 4, "path": ".github/workflows/codeql.yml"}
]
JSON
unset DRY_RUN EVERGREEN_COMMENT
KIND=pr PR=422 REF= run_script
check "pr: succeeds" "0" "$STATUS"
check "pr: runs are looked up on the PR head commit" \
  "1" "$(gh_call 'run list' | grep -c -- '--commit a4787d0')"
check "pr: only the matching runs are re-queued" \
  "run rerun 1
run rerun 2" "$(gh_call 'run rerun')"
# release-python.yml starts with "release", not "test-python", and re-running it
# would publish. codeql.yml matches nothing. Both must be left alone.
check "pr: the release workflow is not re-queued" "" "$(gh_call 'run rerun 3')"
check "pr: an unrelated workflow is not re-queued" "" "$(gh_call 'run rerun 4')"

# The pattern is a glob over file names, not a substring match, so a workflow
# whose name merely contains the pattern must not match.
cat > "$TMPDIR/run_list.json" <<'JSON'
[
  {"databaseId": 5, "path": ".github/workflows/nightly-test-python.yml"},
  {"databaseId": 6, "path": ".github/workflows/test-python.yml"}
]
JSON
KIND=pr PR=422 REF= run_script
check "pr: the pattern anchors at the start of the file name" \
  "run rerun 6" "$(gh_call 'run rerun')"

# A '.' in the pattern is a literal, not a regex wildcard.
cat > "$TMPDIR/run_list.json" <<'JSON'
[
  {"databaseId": 7, "path": ".github/workflows/test-python.yml"},
  {"databaseId": 8, "path": ".github/workflows/testxpython.yml"}
]
JSON
WORKFLOW_PATTERN="test-python.yml" KIND=pr PR=422 REF= run_script
check "pr: a dot in the pattern is literal" \
  "run rerun 7" "$(gh_call 'run rerun')"

# No matching run means the downstream repository is not being tested against
# the new commits, which is exactly the situation this action prevents.
echo '[]' > "$TMPDIR/run_list.json"
unset WORKFLOW_PATTERN
KIND=pr PR=422 REF= run_script
check "pr: no matching run fails" "1" "$STATUS"
check "pr: no matching run re-queues nothing" "" "$(mutating_calls)"
check_contains "pr: no matching run suggests a way forward" \
  "use the 'ref' kind" "$(log)"

cat > "$TMPDIR/run_list.json" <<'JSON'
[{"databaseId": 1, "path": ".github/workflows/test-python.yml"}]
JSON
DRY_RUN=true KIND=pr PR=422 REF= run_script
check "pr + dry run: no mutating gh call" "" "$(mutating_calls)"
check_contains "pr + dry run: the intended call is logged" \
  "Would run: gh run rerun 1" "$(log)"

echo "--- kind: ref"

cat > "$TMPDIR/workflow_list.json" <<'JSON'
[
  {"path": ".github/workflows/test-python.yml", "state": "active"},
  {"path": ".github/workflows/test-python-atlas.yml", "state": "active"},
  {"path": ".github/workflows/test-python-geo.yml", "state": "disabled_manually"},
  {"path": ".github/workflows/release-python.yml", "state": "active"}
]
JSON
unset DRY_RUN
KIND=ref PR= REF=main run_script
check "ref: succeeds" "0" "$STATUS"
check "ref: the matching active workflows are dispatched on the ref" \
  "workflow run test-python.yml --ref main
workflow run test-python-atlas.yml --ref main" "$(gh_call 'workflow run')"
# gh errors on a disabled workflow, and one disabled on purpose should stay off.
check "ref: a disabled workflow is skipped" "" "$(gh_call 'workflow run test-python-geo')"
check "ref: the release workflow is not dispatched" "" "$(gh_call 'workflow run release')"

KIND=ref PR= REF=6.0.x run_script
check "ref: a branch with dots is dispatched as given" \
  "workflow run test-python.yml --ref 6.0.x
workflow run test-python-atlas.yml --ref 6.0.x" "$(gh_call 'workflow run')"

echo '[]' > "$TMPDIR/workflow_list.json"
KIND=ref PR= REF=main run_script
check "ref: no matching workflow fails" "1" "$STATUS"
check "ref: no matching workflow dispatches nothing" "" "$(mutating_calls)"

cat > "$TMPDIR/workflow_list.json" <<'JSON'
[{"path": ".github/workflows/test-python.yml", "state": "active"}]
JSON
DRY_RUN=true KIND=ref PR= REF=main run_script
check "ref + dry run: no mutating gh call" "" "$(mutating_calls)"
check_contains "ref + dry run: the intended call is logged" \
  "Would run: gh workflow run test-python.yml --ref main" "$(log)"

echo "--- unhandled kind"

# parse_inputs.sh rejects this first, so reaching it means the two got out of
# step. It must not exit clean and report a re-trigger that never happened.
unset DRY_RUN
KIND=bogus PR= REF= run_script
check "an unhandled kind fails" "1" "$STATUS"
check "an unhandled kind does nothing" "" "$(mutating_calls)"

exit $FAIL
