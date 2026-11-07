#!/usr/bin/env python3
"""Generate app/CassotisPOC.xcodeproj. Fixed ids keep the file stable across runs.

Three targets: the host app, the plain UIKit keyboard (which also carries the
dictionary), and the keyboard with the fcitx5-ios SwiftUI panel (sources imported
into build/fcitxui by scripts/import_fcitx_ui.sh)."""
import glob, hashlib, os, pathlib

root = pathlib.Path(__file__).resolve().parent.parent / "app"
os.chdir(root)


def uid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


bridge = ["Keyboard/EngineBridge.mm", "../client/EngineClient.cpp", "../bench/replay.cpp"]
fcitx_ui = sorted(os.path.relpath(p) for p in glob.glob("../build/fcitxui/*.swift"))
targets = {
    "host": dict(
        name="CassotisPOC", ext="app", ptype="com.apple.product-type.application",
        sources=["Host/AppDelegate.swift"] + bridge, resources=[],
        bundle="com.hustmobile.cassotis.poc", plist="Host/Info.plist",
        header="Host/Host-Bridging-Header.h"),
    "kb": dict(
        name="CassotisKeyboard", ext="appex", ptype="com.apple.product-type.app-extension",
        sources=["Keyboard/KeyboardViewController.swift", "Keyboard/CommandKeyboardController.swift"] + bridge,
        resources=["../build/res/dict_sc.db", "../build/res/schema.sql", "../bench/corpus.tsv",
                   "../build/res/char_lm"],
        bundle="com.hustmobile.cassotis.poc.keyboard", plist="Keyboard/Info.plist",
        header="Keyboard/Keyboard-Bridging-Header.h"),
    "sui": dict(
        name="CassotisKeyboardSwiftUI", ext="appex", ptype="com.apple.product-type.app-extension",
        sources=["KeyboardSwiftUI/KeyboardViewController.swift", "KeyboardSwiftUI/FcitxBackend.swift",
                 "Keyboard/CommandKeyboardController.swift"] + bridge + fcitx_ui,
        resources=["../build/fcitxui-res/share"],
        bundle="com.hustmobile.cassotis.poc.swiftui", plist="KeyboardSwiftUI/Info.plist",
        header="KeyboardSwiftUI/Keyboard-Bridging-Header.h"),
}
TYPES = {"swift": "sourcecode.swift", "mm": "sourcecode.cpp.objcpp", "cpp": "sourcecode.cpp.cpp",
         "db": "file", "sql": "text", "tsv": "text", "share": "folder"}

files = []
for t in targets.values():
    for f in t["sources"] + t["resources"]:
        if f not in files:
            files.append(f)
refs = "".join(
    f'\t\t{uid("ref" + f)} = {{isa = PBXFileReference; lastKnownFileType = {TYPES[f.rsplit(".", 1)[-1] if "." in f.rsplit("/", 1)[-1] else "share"]}; '
    f'name = "{os.path.basename(f)}"; path = "{f}"; sourceTree = SOURCE_ROOT; }};\n' for f in files)
build_files, group, product_refs = "", "", ""
for f in files:
    group += f"\t\t\t\t{uid('ref' + f)},\n"
phases, native, lists, configs = "", "", "", ""
common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_CXX_LANGUAGE_STANDARD = "c++17";
				CLANG_ENABLE_OBJC_ARC = YES;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Manual;
				DEVELOPMENT_TEAM = TR78TGFZDE;
				ENABLE_BITCODE = NO;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				"CASSOTIS_ENGINE[sdk=iphoneos*]" = ios;
				"CASSOTIS_ENGINE[sdk=iphonesimulator*]" = "ios-sim";
				IPHONEOS_DEPLOYMENT_TARGET = 16.3;
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
				VALIDATE_PRODUCT = NO;
"""
release = '				COPY_PHASE_STRIP = NO;\n				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";\n				GCC_OPTIMIZATION_LEVEL = s;\n				SWIFT_COMPILATION_MODE = wholemodule;\n				SWIFT_OPTIMIZATION_LEVEL = "-O";\n'
debug = '				DEBUG_INFORMATION_FORMAT = dwarf;\n				GCC_OPTIMIZATION_LEVEL = 0;\n				ONLY_ACTIVE_ARCH = YES;\n				SWIFT_OPTIMIZATION_LEVEL = "-Onone";\n'


def config(owner, name, body):
    return f"""		{uid("cfg" + owner + name)} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{body}			}};
			name = {name};
		}};
"""


def cfg_list(owner):
    return f"""		{uid("list" + owner)} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{uid("cfg" + owner + "Debug")},
				{uid("cfg" + owner + "Release")},
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
"""


configs += config("proj", "Debug", common + debug) + config("proj", "Release", common + release)
lists += cfg_list("proj")
for key, t in targets.items():
    product = f"{t['name']}.{t['ext']}"
    kind = "wrapper.application" if t["ext"] == "app" else '"wrapper.app-extension"'
    product_refs += f'\t\t{uid("product" + key)} = {{isa = PBXFileReference; explicitFileType = {kind}; includeInIndex = 0; path = {product}; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
    src, res = "", ""
    for f in t["sources"]:
        build_files += f'\t\t{uid("bf" + key + f)} = {{isa = PBXBuildFile; fileRef = {uid("ref" + f)}; }};\n'
        src += f"				{uid('bf' + key + f)},\n"
    for f in t["resources"]:
        build_files += f'\t\t{uid("bf" + key + f)} = {{isa = PBXBuildFile; fileRef = {uid("ref" + f)}; }};\n'
        res += f"				{uid('bf' + key + f)},\n"
    phases += f"""		{uid("src" + key)} = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{src}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{uid("res" + key)} = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{res}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""
    extra_phase, deps = "", ""
    if key == "host":
        extra_phase = f"\t\t\t\t{uid('embed')},\n"
        deps = f"\t\t\t\t{uid('depkb')},\n\t\t\t\t{uid('depsui')},\n"
    native += f"""		{uid("target" + key)} = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {uid("list" + key)};
			buildPhases = (
				{uid("src" + key)},
				{uid("res" + key)},
{extra_phase}			);
			buildRules = (
			);
			dependencies = (
{deps}			);
			name = {t["name"]};
			productName = {t["name"]};
			productReference = {uid("product" + key)};
			productType = "{t["ptype"]}";
		}};
"""
    settings = f"""				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/../../macos/src/embed",
					"$(SRCROOT)/../client",
					"$(SRCROOT)/../bench",
					"$(SRCROOT)/Keyboard",
				);
				INFOPLIST_FILE = {t["plist"]};
				OTHER_LDFLAGS = (
					"-force_load",
					"$(SRCROOT)/../build/$(CASSOTIS_ENGINE)/libcassotis_core.a",
					"-lsqlite3",
					"-liconv",
					"-lc++",
					"-Wl,-no_fixup_chains",
				);
				PRODUCT_BUNDLE_IDENTIFIER = {t["bundle"]};
				PRODUCT_NAME = {t["name"]};
				SWIFT_OBJC_BRIDGING_HEADER = "{t["header"]}";
"""
    if t["ext"] == "appex":
        settings += '				APPLICATION_EXTENSION_API_ONLY = YES;\n				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks";\n				SKIP_INSTALL = YES;\n'
    else:
        settings += '				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";\n'
    configs += config(key, "Debug", settings) + config(key, "Release", settings)
    lists += cfg_list(key)

build_files += f'\t\t{uid("embedkb")} = {{isa = PBXBuildFile; fileRef = {uid("productkb")}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n'
build_files += f'\t\t{uid("embedsui")} = {{isa = PBXBuildFile; fileRef = {uid("productsui")}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n'
proxies, deps = "", ""
for key in ("kb", "sui"):
    proxies += f"""		{uid("proxy" + key)} = {{
			isa = PBXContainerItemProxy;
			containerPortal = {uid("project")};
			proxyType = 1;
			remoteGlobalIDString = {uid("target" + key)};
			remoteInfo = {targets[key]["name"]};
		}};
"""
    deps += f"""		{uid("dep" + key)} = {{
			isa = PBXTargetDependency;
			target = {uid("target" + key)};
			targetProxy = {uid("proxy" + key)};
		}};
"""
pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

{build_files}
{proxies}
		{uid("embed")} = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				{uid("embedkb")},
				{uid("embedsui")},
			);
			name = "Embed App Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};

{refs}{product_refs}
		{uid("group")} = {{
			isa = PBXGroup;
			children = (
{group}				{uid("products")},
			);
			sourceTree = "<group>";
		}};
		{uid("products")} = {{
			isa = PBXGroup;
			children = (
				{uid("producthost")},
				{uid("productkb")},
				{uid("productsui")},
			);
			name = Products;
			sourceTree = "<group>";
		}};

{native}
		{uid("project")} = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = YES;
				LastUpgradeCheck = 2700;
			}};
			buildConfigurationList = {uid("listproj")};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = "zh-Hans";
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				"zh-Hans",
			);
			mainGroup = {uid("group")};
			productRefGroup = {uid("products")};
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{uid("targethost")},
				{uid("targetkb")},
				{uid("targetsui")},
			);
		}};

{phases}
{deps}
{configs}
{lists}	}};
	rootObject = {uid("project")};
}}
"""
(root / "CassotisPOC.xcodeproj/project.pbxproj").write_text(pbx)
