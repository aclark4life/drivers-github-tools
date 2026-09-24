#!/usr/bin/env bash
# Validate the action's inputs and split them into individual outputs, so the
# token minted next is scoped to exactly one repository and the permissions the
# chosen kind needs.
#
# Required environment: REPO, CI_RERUN, and GITHUB_OUTPUT from the Actions
# runtime.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

# create-github-app-token takes the owner and the bare repository name
# separately, so a value that is not exactly owner/name would silently scope the
# token somewhere unintended.
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
    # An unknown kind, or a kind missing the field it acts on, is a typo in the
    # caller's configuration. Fail rather than no-op, or the mistake is silent
    # and the downstream repository is never re-triggered.
    [ -n "$PR" ] || fail "ci_rerun kind '${KIND}' requires a 'pr' number"
    case "$PR" in
      ''|*[!0-9]*) fail "ci_rerun 'pr' must be a number, got '${PR}'" ;;
    esac
    ;;
  ref)
    [ -n "$REF" ] || fail "ci_rerun kind 'ref' requires a 'ref'"
    # workflow_dispatch only accepts a branch or a tag. GitHub rejects a SHA
    # with an opaque "No ref found" error, so catch the likely mistake here.
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
