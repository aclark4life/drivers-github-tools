"""Hold back hook updates whose release is younger than the cooldown.

``pre-commit autoupdate`` always moves each hook to the newest tag, with no way
to skip one that just landed. A bad release is most dangerous in its first days,
before anyone has yanked it, so this reverts any rev moved to a tag published
inside the cooldown window.

Nothing is held permanently: once the tag ages past the cutoff, the next run
picks it up. A repo whose newest tag is too young stays where it is rather than
moving to an older intermediate tag, which the next run would supersede.

Usage: apply_cooldown.py <old-config> <new-config> <cooldown-days>

The new config is rewritten in place. Held back updates are printed to stdout as
markdown bullets for the pull request body, and as workflow notices on stderr.
"""

import subprocess
import sys
import tempfile
import time

import pre_commit_config as config

# A hanging hook repo must not hang the weekly job. The fetch asks for one tag
# at depth 1, so this is far longer than a healthy one needs.
GIT_TIMEOUT_SECONDS = 120


def git(*args: str, timeout: int = GIT_TIMEOUT_SECONDS) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def tag_timestamp(url: str, rev: str) -> int | None:
    """Return the Unix timestamp ``rev`` was tagged at, or None if unknown.

    Fetching one tag into a throwaway bare repo is a single shallow round trip
    and works against any git host, so it needs no credentials.

    An annotated tag carries the date it was created, which is when the release
    was cut. A lightweight tag has none, so its commit date stands in. That can
    read older and let a young release through, but hook repos overwhelmingly
    publish annotated tags and the alternative is never updating.
    """
    with tempfile.TemporaryDirectory() as tmp:
        if git("init", "--quiet", "--bare", tmp).returncode != 0:
            return None
        if git("-C", tmp, "remote", "add", "origin", url).returncode != 0:
            return None
        fetched = git(
            "-C", tmp, "fetch", "--quiet", "--depth", "1",
            "origin", f"refs/tags/{rev}:refs/tags/{rev}",
        )
        if fetched.returncode != 0:
            return None
        shown = git(
            "-C", tmp, "for-each-ref",
            "--format=%(taggerdate:unix)|%(committerdate:unix)",
            f"refs/tags/{rev}",
        )
        if shown.returncode != 0:
            return None
        tagger, _, committer = shown.stdout.strip().partition("|")
        stamp = tagger or committer
        return int(stamp) if stamp.isdigit() else None


def main() -> None:
    if len(sys.argv) != 4:
        print(
            "Usage: apply_cooldown.py <old-config> <new-config> <cooldown-days>",
            file=sys.stderr,
        )
        sys.exit(2)
    old_path, new_path, cooldown_days_arg = sys.argv[1:]

    try:
        cooldown_days = float(cooldown_days_arg)
    except ValueError:
        print(f"::error::cooldown_days must be a number, got '{cooldown_days_arg}'", file=sys.stderr)
        sys.exit(2)
    if cooldown_days < 0:
        print(f"::error::cooldown_days must not be negative, got '{cooldown_days_arg}'", file=sys.stderr)
        sys.exit(2)
    if cooldown_days == 0:
        return

    old_lines = config.read(old_path)
    new_lines = config.read(new_path)
    pairs = config.changed(config.parse(old_lines), config.parse(new_lines))
    if not pairs:
        return

    cutoff = time.time() - cooldown_days * 86400
    held = []
    for previous, current in pairs:
        name = config.short_name(current.repo)
        stamp = tag_timestamp(current.repo, current.rev)
        if stamp is None:
            # Unknown age cannot be shown to clear the cooldown, so hold. The
            # warning keeps an undatable repo from silently freezing forever.
            print(
                f"::warning::Could not determine the release date of {name} {current.rev};"
                " holding it back. Check that the rev is a tag reachable in the repo.",
                file=sys.stderr,
            )
            held.append(f"- {name}: held `{current.rev}`, release date unknown")
        elif stamp > cutoff:
            age_days = max(0, int((time.time() - stamp) // 86400))
            print(
                f"::notice::Holding {name} {current.rev}: released {age_days}d ago,"
                f" inside the {cooldown_days:g}d cooldown.",
                file=sys.stderr,
            )
            held.append(
                f"- {name}: held `{current.rev}`, released {age_days}d ago"
                f" (cooldown {cooldown_days:g}d)"
            )
        else:
            continue
        config.set_rev(new_lines, current, previous.rev)

    if held:
        config.write(new_path, new_lines)
        for line in held:
            print(line)


if __name__ == "__main__":
    main()
