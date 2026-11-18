#!/usr/bin/env python3
"""Ask the developer account for the development profiles that carry iCloud.

The input method (macOS) and the keyboard people use (iOS) sync through the CloudKit
container below, an entitlement only a provisioning profile can grant. Regular builds
never talk to the account: they sign with whatever profile this left in
~/Library/Developer/Xcode/UserData/Provisioning Profiles. Run this once, and again
when a profile is about to expire (development profiles last a year).

It builds a stub project with Xcode's automatic signing and -allowProvisioningUpdates,
which registers the App IDs with iCloud (CloudKit) and the container, registers this
Mac as a development device (macOS only), and downloads the profiles. The stub's
products are thrown away.

    provision_icloud.py [mac] [ios] [ioshost]      (default: all)
"""
import hashlib, pathlib, shutil, subprocess, sys

TEAM = "TR78TGFZDE"
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")
CONTAINER = "iCloud.com.hustmobile.cassotis"
TARGETS = {
    "mac": dict(name="ProvisionMac", bundle="com.hustmobile.inputmethod.Cassotis",
                sdk="macosx", destination="platform=macOS,arch=arm64",
                settings="MACOSX_DEPLOYMENT_TARGET = 14.0;"),
    "ios": dict(name="ProvisionKeyboard", bundle="com.hustmobile.cassotis.keyboard",
                sdk="iphoneos", destination="generic/platform=iOS",
                settings="IPHONEOS_DEPLOYMENT_TARGET = 18.0; TARGETED_DEVICE_FAMILY = 1;"),
    # The host app: shows the sync state, and probes the container from the Mac.
    "ioshost": dict(name="ProvisionHost", bundle="com.hustmobile.cassotis",
                    sdk="iphoneos", destination="generic/platform=iOS",
                    settings="IPHONEOS_DEPLOYMENT_TARGET = 18.0; TARGETED_DEVICE_FAMILY = 1;"),
}
ENTITLEMENTS = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>{CONTAINER}</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
</dict></plist>
"""


def uid(name):
    return hashlib.md5(("provision" + name).encode()).hexdigest()[:24].upper()


def project(t):
    n = t["name"]
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 56;
	objects = {{
		{uid(n + "bf")} = {{isa = PBXBuildFile; fileRef = {uid(n + "src")}; }};
		{uid(n + "src")} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; }};
		{uid(n + "ent")} = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = stub.entitlements; sourceTree = "<group>"; }};
		{uid(n + "product")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {n}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{uid(n + "group")} = {{isa = PBXGroup; children = ({uid(n + "src")}, {uid(n + "ent")}, {uid(n + "products")}, ); sourceTree = "<group>"; }};
		{uid(n + "products")} = {{isa = PBXGroup; children = ({uid(n + "product")}, ); name = Products; sourceTree = "<group>"; }};
		{uid(n + "phase")} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uid(n + "bf")}, ); runOnlyForDeploymentPostprocessing = 0; }};
		{uid(n + "target")} = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {uid(n + "tlist")};
			buildPhases = ({uid(n + "phase")}, );
			buildRules = ();
			dependencies = ();
			name = {n};
			productName = {n};
			productReference = {uid(n + "product")};
			productType = "com.apple.product-type.application";
		}};
		{uid(n + "project")} = {{
			isa = PBXProject;
			attributes = {{LastUpgradeCheck = 2700; TargetAttributes = {{ {uid(n + "target")} = {{ DevelopmentTeam = {TEAM}; ProvisioningStyle = Automatic; }}; }}; }};
			buildConfigurationList = {uid(n + "plist")};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base, );
			mainGroup = {uid(n + "group")};
			productRefGroup = {uid(n + "products")};
			projectDirPath = "";
			projectRoot = "";
			targets = ({uid(n + "target")}, );
		}};
		{uid(n + "pcfg")} = {{isa = XCBuildConfiguration; buildSettings = {{ SDKROOT = {t["sdk"]}; }}; name = Debug; }};
		{uid(n + "plist")} = {{isa = XCConfigurationList; buildConfigurations = ({uid(n + "pcfg")}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
		{uid(n + "tcfg")} = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_ENTITLEMENTS = stub.entitlements;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = {TEAM};
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = {t["bundle"]};
				PRODUCT_NAME = {n};
				SDKROOT = {t["sdk"]};
				{t["settings"]}
			}};
			name = Debug;
		}};
		{uid(n + "tlist")} = {{isa = XCConfigurationList; buildConfigurations = ({uid(n + "tcfg")}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
	}};
	rootObject = {uid(n + "project")};
}}
"""


def scheme(t):
    n = t["name"]
    ref = f"""<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{uid(n + "target")}"
            BuildableName = "{n}.app" BlueprintName = "{n}" ReferencedContainer = "container:{n}.xcodeproj"></BuildableReference>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "NO" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" launchStyle = "0" useCustomWorkingDirectory = "NO">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""


def main(argv):
    wanted = argv or list(TARGETS)
    base = pathlib.Path(__file__).resolve().parent.parent / "build" / "provision"
    for key in wanted:
        t = TARGETS[key]
        work = base / key
        if work.exists():
            shutil.rmtree(work)
        schemes = work / f"{t['name']}.xcodeproj" / "xcshareddata" / "xcschemes"
        schemes.mkdir(parents=True)
        (schemes / f"{t['name']}.xcscheme").write_text(scheme(t))
        (work / f"{t['name']}.xcodeproj" / "project.pbxproj").write_text(project(t))
        (work / "main.c").write_text("int main(void) { return 0; }\n")
        entitlements = ENTITLEMENTS if key == "mac" else (
            pathlib.Path(__file__).resolve().parents[2] / "ios/app/Cloud.entitlements").read_text()
        (work / "stub.entitlements").write_text(entitlements)
        command = ["xcodebuild", "-project", str(work / f"{t['name']}.xcodeproj"),
                   "-scheme", t["name"], "-configuration", "Debug",
                   "-destination", t["destination"], "-derivedDataPath", str(work / "dd"),
                   "-allowProvisioningUpdates", "build"]
        if key == "mac":
            command.insert(-1, "-allowProvisioningDeviceRegistration")
        print("[provision]", key, t["bundle"], flush=True)
        log = work / "xcodebuild.log"
        with open(log, "w") as out:
            status = subprocess.call(command, stdout=out, stderr=subprocess.STDOUT)
        # The stub carries the input method's bundle id: Xcode registered it with
        # LaunchServices, which must know only the installed input method by that id.
        for app in (work / "dd").glob("Build/Products/*/*.app"):
            subprocess.call([LSREGISTER, "-u", str(app)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
        shutil.rmtree(work / "dd", ignore_errors=True)
        if status != 0:
            lines = [line for line in log.read_text(errors="replace").splitlines()
                     if "error" in line.lower() or "warning: " in line.lower()]
            print("\n".join(lines[-20:]) or log.read_text(errors="replace")[-3000:], file=sys.stderr)
            print(f"xcodebuild failed ({status}); log: {log}", file=sys.stderr)
            return 1
        print("[provision]", key, "ok", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
