"""Re-run a downstream repository's CI after a fork branch was force-pushed.

The downstream CI checks out the fork branch at a pinned ``ref:``, so a rebased
branch does not re-trigger it. This reads a ``ci_rerun`` mapping naming, per
fork branch, the downstream repositories and how to re-run each one.

Ported from ``dbx sync --all-branches``, and deliberately accepts that command's
config shape unchanged so a mapping can be copied across verbatim:

    {"mongodb/django-mongodb-backend": "main"}                      # a git ref
    {"mongodb/django-mongodb-backend": 607}                         # a PR number
    {"mongodb/django-mongodb-backend": {"pr": 607, "evergreen": true}}
    {"mongodb/django-mongodb-backend": ["main", 607]}               # a mix

The value's *type* selects the behaviour: a string dispatches the downstream
``test-python*`` workflows on that ref, an integer re-runs the workflow runs on
that PR's head commit, and the object form does the PR re-run *and* comments
``evergreen retry`` to re-trigger the PR's Evergreen patch.

Best-effort, like dbx: a stale PR number or an API error is reported and
skipped rather than failing the run, so one bad mapping entry cannot mask the
branches that synced correctly.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys

# GitHub refuses to re-run a workflow run older than this, so a PR whose runs
# have aged out needs a fresh push instead. Worth naming in the output: the
# refusal is otherwise indistinguishable from a permissions problem.
RETRY_WINDOW_HINT = "over a month ago"


class Skip(Exception):
    """A target could not be re-triggered. Reported, then execution continues."""


def warn(message: str) -> None:
    print(f"::warning::{message}")


def run_gh(args: list[str], dry_run: bool = False) -> str:
    """Run gh and return stdout. A dry run logs the call and returns nothing."""
    if dry_run:
        print(f"Would run: gh {' '.join(args)}")
        return ""
    result = subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


def gh_json(args: list[str]):
    """Run a read-only gh query and parse its JSON. Never subject to dry run."""
    out = run_gh(args)
    return json.loads(out) if out else []


def gh_error(exc: subprocess.CalledProcessError) -> str:
    """Pull the human-readable part out of gh's stderr.

    gh reports API failures as ``gh: <message> (HTTP <code>)``, sometimes after
    the raw JSON body, so callers can report why GitHub refused.
    """
    for line in reversed((exc.stderr or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("gh: "):
            return line[4:].strip()
    return (exc.stderr or "").strip().splitlines()[-1].strip() if exc.stderr else ""


def parse_ci_rerun(raw: str) -> dict[str, dict]:
    """Split the mapping into per-target lists of refs, PRs, and Evergreen PRs.

    Mirrors dbx's ``get_ci_rerun_targets``. Returns ``owner/name`` ->
    ``{"refs": [...], "prs": [...], "evergreen_prs": [...]}``, where
    ``evergreen_prs`` is the subset of ``prs`` that also want a retry comment.
    """
    try:
        mapping = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"::error::ci_rerun is not valid JSON: {exc}")
    if not isinstance(mapping, dict):
        raise SystemExit(f"::error::ci_rerun must be a JSON object, got {raw!r}")

    result: dict[str, dict] = {}
    for target, value in mapping.items():
        if "/" not in target or target.count("/") != 1 or not all(target.split("/")):
            raise SystemExit(
                f"::error::ci_rerun keys must be owner/name, got '{target}'"
            )
        refs: list[str] = []
        prs: list[int] = []
        evergreen_prs: list[int] = []
        for item in value if isinstance(value, list) else [value]:
            # bool is an int subclass, so exclude it before the int check or
            # `true` would parse as PR #1.
            if isinstance(item, bool):
                continue
            if isinstance(item, int):
                prs.append(item)
            elif isinstance(item, str):
                # Unlike dbx's TOML, a matrix value reaches us through YAML, so
                # a PR number may arrive quoted. Treat a digit-only string as a
                # PR rather than a ref, which no branch name would look like.
                (prs if item.isdigit() else refs).append(
                    int(item) if item.isdigit() else item
                )
            elif isinstance(item, dict):
                pr = item.get("pr")
                if isinstance(pr, str) and pr.isdigit():
                    pr = int(pr)
                if isinstance(pr, bool) or not isinstance(pr, int):
                    continue
                # The object form still re-runs the PR's Actions runs, exactly
                # as a bare integer does. The flag only adds Evergreen on top.
                prs.append(pr)
                if item.get("evergreen"):
                    evergreen_prs.append(pr)
        result[target] = {"refs": refs, "prs": prs, "evergreen_prs": evergreen_prs}
    return result


def pr_state(target: str, number: int) -> str | None:
    """Return OPEN/CLOSED/MERGED, or None if the lookup failed.

    A failed lookup returns None so the caller proceeds rather than skipping
    real work over a transient API error.
    """
    try:
        pr = gh_json(["pr", "view", str(number), "--repo", target, "--json", "state"])
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None
    return pr.get("state") if isinstance(pr, dict) else None


def rerun_pr(target: str, number: int, dry_run: bool) -> None:
    """Re-queue every workflow run on an open PR's head commit.

    Every run, not just the test workflows: on a PR the lint and Evergreen
    checks gate the merge too, so all of them need re-validating against the
    rebased fork branch.
    """
    print(f"Re-running CI on {target}#{number}")
    try:
        pr = gh_json(
            ["pr", "view", str(number), "--repo", target, "--json", "headRefOid,state"]
        )
        state = pr.get("state") if isinstance(pr, dict) else None
        if state and state != "OPEN":
            raise Skip(
                f"{target}#{number} is {state.lower()}; update the ci_rerun mapping"
            )
        head_sha = pr.get("headRefOid") if isinstance(pr, dict) else None
        if not head_sha:
            raise Skip(f"{target}#{number} returned no head commit")
        runs = gh_json(
            [
                "api",
                f"repos/{target}/actions/runs?head_sha={head_sha}&per_page=100",
                "--jq",
                "[.workflow_runs[].id]",
            ]
        )
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise Skip(f"could not resolve runs for {target}#{number}: {exc}")

    if not runs:
        raise Skip(f"{target}#{number} has no workflow runs on {head_sha}")

    requeued = 0
    reasons: list[str] = []
    for run_id in runs:
        try:
            run_gh(
                ["api", "-X", "POST", f"repos/{target}/actions/runs/{run_id}/rerun"],
                dry_run,
            )
            requeued += 1
        except subprocess.CalledProcessError as exc:
            reason = gh_error(exc)
            if reason and reason not in reasons:
                reasons.append(reason)

    if requeued or dry_run:
        print(f"  queued {requeued} workflow run(s)")
        return
    detail = f": {reasons[0]}" if reasons else ""
    if any(RETRY_WINDOW_HINT in r for r in reasons):
        detail += (
            f". These runs are past GitHub's retry window; push to the PR branch "
            f"to get fresh runs on #{number}"
        )
    raise Skip(f"no runs re-queued on {target}#{number}{detail}")


def retry_evergreen(target: str, number: int, dry_run: bool) -> None:
    """Comment ``evergreen retry`` so Evergreen starts a fresh patch.

    Evergreen pins the fork ref just as Actions does, so a rebase does not
    re-run it. A closed or merged PR is skipped: Evergreen runs no patch for
    one, so the comment would be noise.
    """
    print(f"Retrying Evergreen on {target}#{number}")
    state = pr_state(target, number)
    if state and state != "OPEN":
        raise Skip(f"{target}#{number} is {state.lower()}; update the ci_rerun mapping")
    try:
        run_gh(
            ["pr", "comment", str(number), "--repo", target, "--body", "evergreen retry"],
            dry_run,
        )
    except subprocess.CalledProcessError as exc:
        raise Skip(f"could not comment on {target}#{number}: {gh_error(exc)}")
    print("  commented 'evergreen retry'")


def dispatch_workflows(target: str, ref: str, pattern: str, dry_run: bool) -> None:
    """Dispatch the downstream test workflows on a branch or tag.

    No PR is needed: workflow_dispatch runs each workflow's definition as it
    exists on ``ref``, which pins the fork branch that definition checks out.
    """
    print(f"Dispatching CI on {target}@{ref}")
    try:
        workflows = gh_json(
            [
                "api",
                f"repos/{target}/actions/workflows",
                "--jq",
                f'[.workflows[] | select(.path | test("workflows/{pattern}")) | .path]',
            ]
        )
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise Skip(f"could not list workflows in {target}: {exc}")

    if not workflows:
        raise Skip(f"no {pattern}* workflows found in {target}")

    # Only a workflow declaring workflow_dispatch can run on a ref; the rest
    # would 422. Inspect each definition at `ref` rather than guessing.
    dispatchable = []
    for path in sorted(workflows):
        name = path.split("/")[-1]
        try:
            content = run_gh(["api", f"repos/{target}/contents/{path}?ref={ref}", "--jq", ".content"])
            body = base64.b64decode(content).decode("utf-8", "replace")
            # Avoid a YAML dependency: the trigger has to appear in the file.
            if "workflow_dispatch" in body:
                dispatchable.append(path)
            else:
                print(f"  {name}: skipped, no workflow_dispatch trigger")
        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr or ""
            # A 404 means the Actions registry still lists a workflow that no
            # longer exists at this ref. Dispatching it would 422.
            if "404" in stderr or "Not Found" in stderr:
                print(f"  {name}: skipped, not present on {ref}")
                continue
            # Any other error is transient, so attempt the dispatch anyway
            # rather than skipping work over a failed inspection.
            dispatchable.append(path)

    if not dispatchable:
        raise Skip(f"no dispatchable {pattern}* workflows in {target} at {ref}")

    for path in dispatchable:
        name = path.split("/")[-1]
        try:
            run_gh(["workflow", "run", name, "--repo", target, "--ref", ref], dry_run)
            print(f"  dispatched {name}")
        except subprocess.CalledProcessError as exc:
            warn(f"could not dispatch {name} on {target}@{ref}: {gh_error(exc)}")


def main() -> int:
    raw = os.environ["CI_RERUN"].strip()
    pattern = os.environ.get("WORKFLOW_PATTERN") or "test-python"
    dry_run = os.environ.get("DRY_RUN") == "true"

    if not raw:
        print("ci_rerun is empty, nothing to re-trigger.")
        return 0

    targets = parse_ci_rerun(raw)

    # De-duplicate so a mapping that names the same PR or ref twice acts once.
    actions: list[tuple] = []
    for target, spec in targets.items():
        for ref in spec["refs"]:
            actions.append((dispatch_workflows, target, ref, pattern))
        for number in spec["prs"]:
            actions.append((rerun_pr, target, number))
        for number in spec["evergreen_prs"]:
            actions.append((retry_evergreen, target, number))

    if not actions:
        print("ci_rerun named no targets, nothing to re-trigger.")
        return 0

    # Best-effort, like dbx: one stale mapping entry must not stop the rest.
    # Failures are warnings so the run stays green but says what was skipped.
    for func, *args in actions:
        try:
            func(*args, dry_run)
        except Skip as exc:
            warn(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
