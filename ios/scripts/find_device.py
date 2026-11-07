#!/usr/bin/env python3
"""Print the CoreDevice identifier of the first paired, connected iPhone.

The device scripts use it when CASSOTIS_DEVICE is not set, so no device identifier
has to live in the repository."""
import json, subprocess, sys, tempfile, os

with tempfile.TemporaryDirectory() as folder:
    path = os.path.join(folder, "devices.json")
    subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    devices = json.load(open(path))["result"]["devices"]
# The tunnel reads "disconnected" while idle and comes up on demand, so judge by the
# transport: a cable first, then the local network.
for transport in ("wired", "localNetwork"):
    for device in devices:
        hardware = device.get("hardwareProperties", {})
        connection = device.get("connectionProperties", {})
        if (hardware.get("deviceType") == "iPhone" and hardware.get("reality") == "physical"
                and connection.get("pairingState") == "paired"
                and connection.get("transportType") == transport):
            print(hardware.get("udid") or device["identifier"])
            sys.exit(0)
sys.exit("no paired, connected iPhone; set CASSOTIS_DEVICE")
