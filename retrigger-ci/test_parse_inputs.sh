#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/parse_inputs.sh"
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

# A rejection prints its message only on the fail path, and an output appears
# only on the success path, so each assertion below implies the exit code.
run_script() {
  : > "$TMPDIR/output"
  : > "$TMPDIR/log"
  REPO="$1" CI_RERUN="$2" GITHUB_OUTPUT="$TMPDIR/output" \
    bash "$SCRIPT" > "$TMPDIR/log" 2>&1 || true
}

outputs() { cat "$TMPDIR/output"; }
log() { cat "$TMPDIR/log"; }

# The owner/name split is what scopes the token, and each kind leaves the other
# kinds' fields empty.
run_script "mongodb/django-mongodb-backend" '{"kind":"evergreen","pr":422}'
check "evergreen: outputs" \
  "owner=mongodb
name=django-mongodb-backend
kind=evergreen
pr=422
ref=" \
  "$(outputs)"

run_script "mongodb/django-mongodb-backend" '{"kind":"ref","ref":"main"}'
check_contains "ref: the ref is passed through" "ref=main" "$(outputs)"

# Anything other than owner/name would scope the minted token somewhere
# unintended.
for BAD_REPO in "django-mongodb-backend" "mongodb/labs/backend" "mongodb/"; do
  run_script "$BAD_REPO" '{"kind":"ref","ref":"main"}'
  check_contains "repo '${BAD_REPO}' is rejected" "repo must be owner/name" "$(log)"
done

# A typo in the matrix must fail, not silently skip the re-trigger.
run_script "mongodb/backend" '{"kind":"evergreeen","pr":1}'
check_contains "unknown kind is rejected, naming the valid kinds" \
  "expected evergreen, pr, or ref" "$(log)"

run_script "mongodb/backend" '{"pr":1}'
check_contains "missing kind is rejected" "must set 'kind'" "$(log)"

run_script "mongodb/backend" 'not json'
check_contains "non-JSON ci_rerun is rejected" "must be a JSON object" "$(log)"

# A kind missing the field it acts on cannot do anything useful.
run_script "mongodb/backend" '{"kind":"evergreen"}'
check_contains "evergreen without pr is rejected" "requires a 'pr' number" "$(log)"

run_script "mongodb/backend" '{"kind":"ref"}'
check_contains "ref without ref is rejected" "requires a 'ref'" "$(log)"

run_script "mongodb/backend" '{"kind":"pr","pr":"main"}'
check_contains "non-numeric pr is rejected" "'pr' must be a number" "$(log)"

# workflow_dispatch takes a branch or tag. A SHA fails downstream with an
# opaque error, so catch it here.
run_script "mongodb/backend" '{"kind":"ref","ref":"a4787d0a0bdcdff18333a0204135fa2a6283a19d"}'
check_contains "a SHA ref is rejected" "not a commit SHA" "$(log)"

# A branch that only looks SHA-like must still be allowed.
run_script "mongodb/backend" '{"kind":"ref","ref":"6.0.x"}'
check_contains "a dotted branch name is passed through" "ref=6.0.x" "$(outputs)"

exit $FAIL
