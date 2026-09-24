#!/usr/bin/env bash
# Validate the inputs and split them into outputs, so the token minted next is
# scoped to one repository and to what the kind needs.
#
# Required environment: REPO, CI_RERUN, and GITHUB_OUTPUT from the Actions
# runtime.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

# create-github-app-token takes the owner and the name separately, so anything
# other than owner/name would scope the token somewhere unintended.
case "$REPO" in
  */*/*|/*|*/) fail "repo must be owner/name, got '${REPO}'" ;;
  */*) ;;
  *) fail "repo must be owner/name, got '${REPO}'" ;;
esac
OWNER=${REPO%%/*}
NAME=${REPO#*/}
[ -n "$OWNER" ] && [ -n "$NAME" ] || fail "repo must be owner/name, got '${REPO}'"

echo "$CI_RERUN" | jq -e 'type == "object"' > /dev/null 2>&1 \
  || fail "ci_rerun must be a JSON object, got '${CI_RERUN}'"

KIND=$(echo "$CI_RERUN" | jq -r '.kind // empty')
PR=$(echo "$CI_RERUN" | jq -r '.pr // empty')
REF=$(echo "$CI_RERUN" | jq -r '.ref // empty')

case "$KIND" in
  evergreen|pr)
    # A kind missing the field it acts on is a typo. Fail rather than no-op,
    # or the downstream repository is never re-triggered and nobody knows.
    [ -n "$PR" ] || fail "ci_rerun kind '${KIND}' requires a 'pr' number"
    case "$PR" in
      ''|*[!0-9]*) fail "ci_rerun 'pr' must be a number, got '${PR}'" ;;
    esac
    ;;
  ref)
    [ -n "$REF" ] || fail "ci_rerun kind 'ref' requires a 'ref'"
    # workflow_dispatch takes a branch or tag. GitHub rejects a SHA with an
    # opaque "No ref found", so catch that here.
    if printf '%s' "$REF" | grep -Eq '^[0-9a-f]{7,40}$'; then
      fail "ci_rerun 'ref' must be a branch or tag, not a commit SHA, got '${REF}'"
    fi
    ;;
  '')
    fail "ci_rerun must set 'kind', got '${CI_RERUN}'"
    ;;
  *)
    fail "unknown ci_rerun kind '${KIND}'; expected evergreen, pr, or ref"
    ;;
esac

{
  echo "owner=${OWNER}"
  echo "name=${NAME}"
  echo "kind=${KIND}"
  echo "pr=${PR}"
  echo "ref=${REF}"
} >> "$GITHUB_OUTPUT"
