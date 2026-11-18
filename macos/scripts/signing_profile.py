#!/usr/bin/env python3
"""Find the development profile that lets a bundle use the iCloud container.

    signing_profile.py mac|mac-release|ios BUNDLE_ID

Prints "<profile path>\t<team id>" for the newest unexpired profile made for exactly
BUNDLE_ID (not a wildcard) that grants iCloud.com.hustmobile.cassotis and, for
macOS, lists this Mac. Exits 1 when there is none: scripts/provision_icloud.py
fetches development profiles from the developer account. mac-release selects a Developer
ID profile for Production, optionally from CASSOTIS_DISTRIBUTION_PROFILE.
"""
import datetime, os, pathlib, plistlib, subprocess, sys

CONTAINER = "iCloud.com.hustmobile.cassotis"
FOLDERS = [pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
           pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"]


def this_mac():
    out = subprocess.run(["system_profiler", "SPHardwareDataType"], capture_output=True,
                         text=True).stdout
    for line in out.splitlines():
        if "Provisioning UDID" in line:
            return line.split(":", 1)[1].strip()
    return None


def main(platform, bundle):
    now = datetime.datetime.now(datetime.timezone.utc)
    mac = this_mac() if platform == "mac" else None
    best = None
    supplied = os.environ.get("CASSOTIS_DISTRIBUTION_PROFILE") if platform == "mac-release" else None
    candidates = [pathlib.Path(supplied)] if supplied else (
        path for folder in FOLDERS if folder.is_dir() for path in folder.iterdir())
    for path in candidates:
        if path.suffix not in (".mobileprovision", ".provisionprofile"):
            continue
        raw = subprocess.run(["security", "cms", "-D", "-i", str(path)],
                             capture_output=True).stdout
        try:
            profile = plistlib.loads(raw)
        except Exception:
            continue
        platforms = profile.get("Platform", [])
        if (platform != "ios") != ("OSX" in platforms):
            continue
        entitlements = profile.get("Entitlements", {})
        team = (profile.get("TeamIdentifier") or [""])[0]
        app_id = entitlements.get("com.apple.application-identifier"
                                  if platform != "ios" else "application-identifier")
        if app_id != f"{team}.{bundle}":
            continue
        if CONTAINER not in entitlements.get(
                "com.apple.developer.icloud-container-identifiers", []):
            continue
        services = entitlements.get("com.apple.developer.icloud-services", [])
        if "CloudKit" not in services and "*" not in services:
            continue
        if platform == "mac-release":
            environments = entitlements.get("com.apple.developer.icloud-container-environment", [])
            if not profile.get("ProvisionsAllDevices") or "Production" not in environments:
                continue
        expires = profile.get("ExpirationDate")
        if expires is None or expires.replace(tzinfo=datetime.timezone.utc) <= now:
            continue
        if platform == "mac" and (mac is None or mac not in profile.get("ProvisionedDevices", [])):
            continue
        created = profile.get("CreationDate")
        if best is None or created > best[0]:
            best = (created, path, team)
    if best is None:
        return 1
    print(f"{best[1]}\t{best[2]}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("mac", "mac-release", "ios"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
