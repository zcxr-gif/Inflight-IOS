#!/usr/bin/env python3
"""Check the provisioning profiles on this machine against what the targets ask for.

Signing this project needs two App IDs, not one: the app and the widget
extension. Every failure mode around that is quiet in the wrong place —
`fetch-signing-files` matching only the app's identifier still exits 0, and
`use-profiles` still exits 0 because it did apply a profile to a target. The
first thing that notices is `xcodebuild archive`, several minutes later, with:

    "InflightWidgets" requires a provisioning profile with the App Groups
    feature. Select a provisioning profile in the Signing & Capabilities editor.

which says nothing about which of the several possible causes it hit. This
turns that into an up-front failure that names the missing piece and what to
click to get it.

Usage:

    check-provisioning.py --require BUNDLE_ID:ENTITLEMENT[=VALUE] ...

A requirement with no VALUE asserts the entitlement is present at all. With a
VALUE it must equal it, or contain it when the entitlement is an array (which
is how app groups are stored).
"""

from __future__ import annotations

import argparse
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_PROFILES_DIR = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"

# What to tell a human when a profile is missing or under-powered. Keyed by the
# entitlement, because the fix is a different checkbox in the portal for each.
CAPABILITY_HINTS = {
    "com.apple.security.application-groups": (
        "App Groups. Enable it on the identifier, then edit it and tick the "
        "group itself — an identifier can have the capability enabled and no "
        "group attached, which still signs nothing. The App Store Connect API "
        "cannot attach the group, so this part is portal-only."
    ),
    "aps-environment": (
        "Push Notifications. Enable it on the identifier."
    ),
    "com.apple.developer.applesignin": (
        "Sign in with Apple. Enable it on the identifier — and note that this "
        "one is invisible until it is missing: the app builds, installs and "
        "runs, and the button then fails with error 1000 and nothing else to "
        "go on. Profiles issued before the capability was added still install "
        "and still sign, so the profile has to be regenerated afterwards and "
        "re-uploaded to Codemagic as inflight_distribution."
    ),
}


def decode_profile(path: Path) -> dict:
    """Read the plist out of a .mobileprovision.

    The file is CMS-wrapped, so `security cms -D` is the right tool where it
    exists. It only exists on macOS, and this script is worth being able to run
    against a downloaded profile anywhere, so fall back to lifting the embedded
    XML out of the container by hand.
    """
    try:
        decoded = subprocess.run(
            ["security", "cms", "-D", "-i", str(path)],
            capture_output=True,
            check=True,
        ).stdout
        return plistlib.loads(decoded)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        raw = path.read_bytes()
        start = raw.find(b"<?xml")
        end = raw.find(b"</plist>")
        if start == -1 or end == -1:
            raise ValueError(f"{path.name} does not contain a readable plist")
        return plistlib.loads(raw[start : end + len(b"</plist>")])


def bundle_id_of(profile: dict) -> str | None:
    """The bundle id a profile signs, with the team prefix stripped.

    A wildcard profile's application-identifier ends in `.*`; it is returned as
    the prefix so the caller can match against it.
    """
    entitlements = profile.get("Entitlements", {})
    app_id = entitlements.get("application-identifier") or entitlements.get(
        "com.apple.application-identifier"
    )
    if not app_id:
        return None
    # TEAMID.com.example.app -> com.example.app
    _, _, identifier = app_id.partition(".")
    return identifier or None


def matches(profile_bundle_id: str, wanted: str) -> bool:
    if profile_bundle_id == wanted:
        return True
    if profile_bundle_id.endswith(".*"):
        return wanted.startswith(profile_bundle_id[:-1])
    return False


def issued_label(profile: dict) -> str:
    created = profile.get("CreationDate")
    if not isinstance(created, datetime):
        return "date unknown"
    return created.strftime("%Y-%m-%d")


def is_expired(profile: dict) -> bool:
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime):
        return False
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    return expires <= datetime.now(timezone.utc)


def satisfies(entitlements: dict, key: str, value: str | None) -> bool:
    if key not in entitlements:
        return False
    if value is None:
        return True
    held = entitlements[key]
    if isinstance(held, (list, tuple)):
        return value in held
    return held == value


def parse_requirement(spec: str) -> tuple[str, str, str | None]:
    bundle_id, sep, rest = spec.partition(":")
    if not sep or not rest:
        raise argparse.ArgumentTypeError(
            f"expected BUNDLE_ID:ENTITLEMENT[=VALUE], got {spec!r}"
        )
    entitlement, _, value = rest.partition("=")
    return bundle_id, entitlement, value or None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--require",
        dest="requirements",
        action="append",
        type=parse_requirement,
        metavar="BUNDLE_ID:ENTITLEMENT[=VALUE]",
        required=True,
    )
    parser.add_argument(
        "--profiles-dir",
        type=Path,
        default=DEFAULT_PROFILES_DIR,
        help="where the fetched profiles landed (default: %(default)s)",
    )
    args = parser.parse_args()

    profiles = []
    for path in sorted(args.profiles_dir.glob("*.mobileprovision")):
        try:
            profile = decode_profile(path)
        except (ValueError, OSError) as error:
            print(f"  ! skipping {path.name}: {error}")
            continue
        bundle_id = bundle_id_of(profile)
        if bundle_id is None:
            continue
        profiles.append((path, bundle_id, profile))

    print(f"==> {len(profiles)} provisioning profile(s) in {args.profiles_dir}")
    for path, bundle_id, profile in profiles:
        name = profile.get("Name", path.name)
        note = " (EXPIRED)" if is_expired(profile) else ""
        # When it was issued, because the usual reason a run looks identical to
        # the last one is that a regenerate in the portal did not take. A date
        # from weeks ago against an App ID somebody has just edited says so
        # immediately; the name alone is reused and says nothing.
        print(f"      {bundle_id} -> {name}{note}   issued {issued_label(profile)}")

    # Two live profiles for one bundle id is not an error — either may sign
    # perfectly well — but it is a coin toss the moment one of them goes stale,
    # and the loser is a build that fails for no reason anybody changed. Worth
    # saying out loud while somebody is already looking at the portal.
    seen: dict[str, list[str]] = {}
    for path, bundle_id, profile in profiles:
        if is_expired(profile):
            continue
        seen.setdefault(bundle_id, []).append(str(profile.get("Name", path.name)))

    for bundle_id, names in seen.items():
        if len(names) > 1:
            print(
                f"  ! {bundle_id} has {len(names)} live profiles: {', '.join(names)}.\n"
                f"    Whichever is chosen is arbitrary. Delete all but one."
            )

    # Group the requirements so one missing profile reports once rather than
    # once per entitlement it was supposed to carry.
    wanted: dict[str, list[tuple[str, str | None]]] = {}
    for bundle_id, entitlement, value in args.requirements:
        wanted.setdefault(bundle_id, []).append((entitlement, value))

    failures: list[str] = []
    for bundle_id, needs in wanted.items():
        candidates = [
            (path, profile)
            for path, profile_bundle_id, profile in profiles
            if matches(profile_bundle_id, bundle_id) and not is_expired(profile)
        ]
        if not candidates:
            failures.append(
                f"No unexpired provisioning profile signs {bundle_id}.\n"
                f"    Register the App ID in Certificates, Identifiers & Profiles, "
                f"enable the capabilities below on it, and let the next build "
                f"fetch a profile for it."
            )
            for entitlement, _ in needs:
                hint = CAPABILITY_HINTS.get(entitlement, entitlement)
                failures.append(f"      - {hint}")
            continue

        # Prefer whichever candidate covers the most of what we asked for, so a
        # stale wildcard profile does not mask a correct explicit one.
        path, profile = max(
            candidates,
            key=lambda item: sum(
                satisfies(item[1].get("Entitlements", {}), key, value)
                for key, value in needs
            ),
        )
        entitlements = profile.get("Entitlements", {})
        for entitlement, value in needs:
            if satisfies(entitlements, entitlement, value):
                continue
            shown = f"{entitlement}={value}" if value else entitlement
            hint = CAPABILITY_HINTS.get(entitlement, entitlement)
            failures.append(
                f"Profile {profile.get('Name', path.name)!r} signs {bundle_id} "
                f"but is missing {shown}.\n"
                f"    The App ID needs {hint}\n"
                f"    Then delete the stale profile so a fresh one is issued."
            )

    if failures:
        print("\nFATAL: this build cannot be signed.\n")
        for failure in failures:
            print(f"  {failure}")
        print(
            "\n  Portal checklists: ios-native/NOTIFICATIONS.md for push, app "
            "groups and the widget extension; ios-native/PRO.md for Sign in "
            "with Apple and the App Store products. None of it can be set "
            "from the repository."
        )
        return 1

    print("==> Every target has a profile with the entitlements it asks for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
