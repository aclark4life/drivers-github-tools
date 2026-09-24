#!/usr/bin/env bash
# Re-trigger the downstream repository's CI, one of three ways. parse_inputs.sh
# validated the inputs, so each kind can assume its fields are well formed.
#
# Required environment: GH_TOKEN, GH_REPO, KIND, PR, REF, WORKFLOW_PATTERN,
# EVERGREEN_COMMENT, DRY_RUN.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

# Every mutating command goes through this, so a dry run cannot re-trigger
# anything even if a new kind is added later.
run_gh() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "Would run: gh $*"
  else
    gh "$@"
  fi
}

# WORKFLOW_PATTERN is a glob, but jq matches regexes. Escape what has meaning
# in a regex, then let '*' through as '.*'.
pattern_to_regex() {
  local escaped
  escaped=$(printf '%s' "$1" | sed -e 's/[.[\]$()|+?{}^\\]/\\&/g' -e 's/\*/.*/g')
  printf '^%s$' "$escaped"
}

case "$KIND" in
  evergreen)
    # Evergreen only retries an open pull request. Elsewhere the comment posts
    # and nothing happens, which looks like success, so refuse instead.
    STATE=$(gh pr view "$PR" --json state --jq .state)
    if [ "$STATE" != "OPEN" ]; then
      fail "${GH_REPO}#${PR} is ${STATE}, not open; Evergreen will not re-run its patch. Point ci_rerun at an open pull request, or switch it to another kind."
    fi
    run_gh pr comment "$PR" --body "$EVERGREEN_COMMENT"
    echo "Asked Evergreen to retry ${GH_REPO}#${PR}."
    ;;

  pr)
    HEAD_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
    REGEX=$(pattern_to_regex "$WORKFLOW_PATTERN")
    # Match the file name, not the display name, which can be anything.
    #
    # Completed runs only: gh refuses to re-run one still going, and a run in
    # flight needs no help. A re-run redoes its checkouts, so it picks up the
    # new upstream commits.
    RUN_IDS=$(gh run list --commit "$HEAD_SHA" --status completed --limit 100 \
      --json databaseId,path \
      --jq "map(select((.path | split(\"/\") | last) | test(\"${REGEX}\"))) | .[].databaseId")
    if [ -z "$RUN_IDS" ]; then
      # The runs aged out of retention, or the pattern matches nothing. Either
      # way the downstream repository is untested against the new commits,
      # which is what this action prevents, so fail rather than exit clean.
      fail "No completed runs matching '${WORKFLOW_PATTERN}' found on ${GH_REPO}@${HEAD_SHA}. Nothing was re-triggered. Re-run them by hand, or use the 'ref' kind to dispatch the workflows instead."
    fi
    while read -r RUN_ID; do
      [ -n "$RUN_ID" ] || continue
      run_gh run rerun "$RUN_ID"
      echo "Re-queued run ${RUN_ID} on ${GH_REPO}@${HEAD_SHA}."
    done <<< "$RUN_IDS"
    ;;

  ref)
    REGEX=$(pattern_to_regex "$WORKFLOW_PATTERN")
    # Dispatch by file name, which is stable. Skip disabled workflows: gh
    # errors on them, and one disabled on purpose should stay off.
    WORKFLOWS=$(gh workflow list --all --limit 100 --json path,state \
      --jq "map(select(.state == \"active\")) | map(select((.path | split(\"/\") | last) | test(\"${REGEX}\"))) | .[].path")
    if [ -z "$WORKFLOWS" ]; then
      fail "No active workflows matching '${WORKFLOW_PATTERN}' found in ${GH_REPO}. Nothing was re-triggered."
    fi
    while read -r WORKFLOW; do
      [ -n "$WORKFLOW" ] || continue
      # Needs workflow_dispatch on the workflow and the ref to exist.
      run_gh workflow run "$(basename "$WORKFLOW")" --ref "$REF"
      echo "Dispatched $(basename "$WORKFLOW") on ${GH_REPO}@${REF}."
    done <<< "$WORKFLOWS"
    ;;

  *)
    # parse_inputs.sh rejects anything else, so the two got out of step.
    fail "unhandled ci_rerun kind '${KIND}'"
    ;;
esac
