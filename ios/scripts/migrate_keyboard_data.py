"""Back up this device's old keyboards before installation. Publish verified snapshots
for the new keyboards to import on their next engine open, including existing installs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PAIRS = [("poc.swiftui", "keyboard"), ("poc.keyboard", "testkeyboard")]
PREFIX = "com.hustmobile.cassotis"
DATA = "Library/Application Support/Cassotis"


def device_command(device, *args, result=False):
    cmd = ["xcrun", "devicectl", "device", *args[:2], "--device", device, "--timeout", "120", *map(str, args[2:])]
    if result:
        raw = subprocess.check_output(cmd + ["--quiet", "--json-output", "-"])
        return json.loads(raw)["result"]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def domain(bundle):
    return ["--domain-type", "appDataContainer", "--domain-identifier", bundle]


def file_names(device, bundle, folder):
    listing = device_command(device, "info", "files", *domain(bundle), "--subdirectory",
                             folder, "--no-recurse", result=True)
    return {f["name"] for f in listing["files"]}


def copy(device, direction, bundle, source, destination):
    device_command(device, "copy", direction, *domain(bundle),
                   "--source", source, "--destination", destination)


def stop_keyboards(device):
    processes = device_command(device, "info", "processes", result=True)["runningProcesses"]
    for proc in processes:
        path = proc.get("executable", "")
        if any(f"/{name}.appex/" in path for name in ("CassotisKeyboard", "CassotisKeyboardSwiftUI")):
            device_command(device, "process", "terminate", "--pid", proc["processIdentifier"])


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_dictionary(device, bundle, out):
    # The keyboard can be relaunched by iOS. Only seal a set of database and
    # journal files which stayed identical across two reads from the device.
    database = "user_dict.db"
    for _ in range(3):
        names = file_names(device, bundle, DATA)
        files = [name for name in (database, database + "-wal", database + "-journal") if name in names]
        if database not in files:
            return False
        with tempfile.TemporaryDirectory(dir=out) as scratch:
            working = Path(scratch)
            try:
                for name in files:
                    copy(device, "from", bundle, f"{DATA}/{name}", working / name)
                for name in files:
                    check = working / "second-read"
                    copy(device, "from", bundle, f"{DATA}/{name}", check)
                    if digest(working / name) != digest(check):
                        break
                    check.unlink()
                else:
                    if names == file_names(device, bundle, DATA):
                        for name in files:
                            (working / name).replace(out / name)
                        return True
            except subprocess.CalledProcessError:
                if names == file_names(device, bundle, DATA):
                    raise
    raise RuntimeError(f"{bundle}: dictionary changed during backup, retry when the keyboard is idle")


def backup(device, old, out):
    # List from an existing parent: a locked device or failed listing must abort,
    # whereas a never-used keyboard truly has no dictionary.
    parent = "Library"
    for part in ["Application Support", "Cassotis"]:
        if part not in file_names(device, old, parent):
            return None
        parent += "/" + part
    out.mkdir(mode=0o700)
    if not copy_dictionary(device, old, out):
        return None

    sealed = out / "legacy.sqlite"
    with sqlite3.connect(out / "user_dict.db") as source, sqlite3.connect(sealed) as target:
        source.backup(target)
        if target.execute("pragma quick_check").fetchall() != [("ok",)]:
            raise RuntimeError(f"{old}: invalid SQLite backup")
        target.execute("SELECT 1 FROM dict_user LIMIT 1")
        target.execute("pragma journal_mode=delete")
    if "Preferences" in file_names(device, old, "Library") and old + ".plist" in file_names(device, old, "Library/Preferences"):
        copy(device, "from", old, f"Library/Preferences/{old}.plist", out / "prefs.plist")
        plistlib.loads((out / "prefs.plist").read_bytes())
    return sealed


def publish(device, bundle, sealed):
    checksum = digest(sealed)
    base = f"Library/CassotisLegacy-{checksum}"
    copy(device, "to", bundle, sealed, base + ".sqlite")
    readback = sealed.parent / "verified.sqlite"
    copy(device, "from", bundle, base + ".sqlite", readback)
    if digest(readback) != checksum:
        raise RuntimeError(f"{bundle}: transferred snapshot differs")
    readback.unlink()
    prefs = sealed.parent / "prefs.plist"
    if prefs.is_file():
        copy(device, "to", bundle, prefs, base + ".plist")
        copy(device, "from", bundle, base + ".plist", readback)
        if digest(readback) != digest(prefs):
            raise RuntimeError(f"{bundle}: transferred preferences differ")
        readback.unlink()
    marker = sealed.parent / "ready"
    marker.write_text(checksum)
    copy(device, "to", bundle, marker, "Library/CassotisLegacy.ready")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label", nargs="?", default="device")
    parser.add_argument("--install", type=Path, metavar="APP")
    args = parser.parse_args()
    device = os.environ.get("CASSOTIS_DEVICE")
    if not device or not re.fullmatch(r"[A-Za-z0-9_-]+", args.label):
        parser.error("set CASSOTIS_DEVICE and use an alphanumeric backup label")
    if args.install and plistlib.loads((args.install / "Info.plist").read_bytes()).get("CFBundleIdentifier") != PREFIX:
        parser.error("--install requires the new Cassotis app")
    app_list = device_command(device, "info", "apps", "--include-default-apps",
                              "--filter", f"bundleIdentifier BEGINSWITH '{PREFIX}'", result=True)
    apps = {app["bundleIdentifier"] for app in app_list["apps"]}
    has_old = PREFIX + ".poc" in apps
    snapshots = {}
    if has_old:
        stop_keyboards(device)
        parent = ROOT / "build/migration" / args.label
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        folder = Path(tempfile.mkdtemp(prefix="install-", dir=parent))
        for old, new in PAIRS:
            snapshots[new] = backup(device, f"{PREFIX}.{old}", folder / new)
            if PREFIX in apps:
                backup(device, f"{PREFIX}.{new}", folder / ("before-" + new))
        print(f"Local device backup: {folder}", flush=True)
    if args.install:
        device_command(device, "install", "app", args.install.resolve())
    for new, sealed in snapshots.items():
        if sealed:
            publish(device, f"{PREFIX}.{new}", sealed)
            print(f"{new}: verified snapshot staged", flush=True)
            field = "swiftui" if new == "keyboard" else "uikit"
            try:
                device_command(device, "process", "launch", "--terminate-existing", PREFIX,
                               "--field", field, "--keyboard", f"{PREFIX}.{new}",
                               "--command", "label=migration mode=migrate")
            except subprocess.CalledProcessError:
                # A locked phone can refuse the host launch after a successful install.
                print(f"{new}: host launch was not confirmed; checking the staged import")
            for _ in range(12):
                if "CassotisLegacy.ready" not in file_names(device, f"{PREFIX}.{new}", "Library"):
                    print(f"{new}: imported on device")
                    break
                time.sleep(1)
            else:
                print(f"{new}: import pending; open this keyboard once on the unlocked device")
        else:
            print(f"{new}: old keyboard has no dictionary")
    if not has_old:
        print("No old Cassotis app installed on this device.")


if __name__ == "__main__":
    main()
