#!/usr/bin/python3

"""An lldb module that registers a stop hook to set swift settings."""

import lldb
import re

# Order matters, it needs to be from the most nested to the least
_BUNDLE_EXTENSIONS = [
    ".framework",
    ".xctest",
    ".appex",
    ".bundle",
    ".app",
]

_TRIPLE_MATCH = re.compile(r"([^-]+-[^-]+)(-\D+)[^-]*(-.*)?")

_SETTINGS = {
    "arm64-apple-macosx MudClient": {
        "c": "-I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics/Sources/_AtomicsShims/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics/Sources/_AtomicsShims/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOAtomics.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOAtomics/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOAtomics/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOOpenBSD.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOOpenBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOOpenBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOFreeBSD.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOFreeBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOFreeBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIODarwin.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIODarwin/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIODarwin/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOLinux.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOLinux/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOLinux/include -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWindows/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWindows/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOWASI.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWASI/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWASI/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOPosix.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOPosix/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOPosix/include -iquote$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics -iquote$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics -iquote$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio -iquote$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio -iquote$(PROJECT_DIR) -iquote$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin -fmodule-map-file=$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics/Sources/_AtomicsShims/include/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOAtomics.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOOpenBSD.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOFreeBSD.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIODarwin.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOLinux.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWindows/include/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOWASI.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOPosix.rspm_modulemap_modulemap/_/module.modulemap -O0 -DDEBUG=1 -fstack-protector -fstack-protector-all",
        "s": [
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/+new_local_repository+swift_parsing",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_afluent",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_service_context",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_dependencyinjection",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/Sources/ScriptDescription",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_shellout",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_argument_parser",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_collections",
        ],
    },
    "arm64-apple-macosx MudClientTests.xctest/Contents/MacOS/MudClientTests": {
        "c": "-I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics/Sources/_AtomicsShims/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics/Sources/_AtomicsShims/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOAtomics.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOAtomics/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOAtomics/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOOpenBSD.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOOpenBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOOpenBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOFreeBSD.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOFreeBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOFreeBSD/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIODarwin.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIODarwin/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIODarwin/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOLinux.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOLinux/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOLinux/include -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWindows/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWindows/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOWASI.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWASI/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWASI/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOPosix.rspm_modulemap_modulemap/_ -I$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOPosix/include -I$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOPosix/include -iquote$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics -iquote$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics -iquote$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio -iquote$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio -iquote$(PROJECT_DIR) -iquote$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin -fmodule-map-file=$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics/Sources/_AtomicsShims/include/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOAtomics.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOOpenBSD.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOFreeBSD.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIODarwin.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOLinux.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_EXTERNAL)/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/Sources/CNIOWindows/include/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOWASI.rspm_modulemap_modulemap/_/module.modulemap -fmodule-map-file=$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio/CNIOPosix.rspm_modulemap_modulemap/_/module.modulemap -O0 -DDEBUG=1 -fstack-protector -fstack-protector-all",
        "f": [
            "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks",
        ],
        "s": [
            "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/+new_local_repository+swift_parsing",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_atomics",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_afluent",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_service_context",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_dependencyinjection",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/Sources/ScriptDescription",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_shellout",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_argument_parser",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_nio",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/external/rules_swift_package_manager++swift_deps+swiftpkg_swift_collections",
            "$(BAZEL_OUT)/darwin_arm64-dbg-ST-69e65c902ded/bin/Sources/MudClient",
        ],
    },
}

def __lldb_init_module(debugger, _internal_dict):
    # Register the stop hook when this module is loaded in lldb
    ci = debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()
    ci.HandleCommand(
        "target stop-hook add -P swift_debug_settings.StopHook",
        res,
    )
    if not res.Succeeded():
        print(f"""\
Failed to register Swift debug options stop hook:

{res.GetError()}
Please file a bug report here: \
https://github.com/MobileNativeFoundation/rules_xcodeproj/issues/new?template=bug.md
""")
        return

def _get_relative_executable_path(module):
    for extension in _BUNDLE_EXTENSIONS:
        prefix, _, suffix = module.rpartition(extension)
        if prefix:
            return prefix.split("/")[-1] + extension + suffix
    return module.split("/")[-1]

class StopHook:
    "An lldb stop hook class, that sets swift settings for the current module."

    def __init__(self, _target, _extra_args, _internal_dict):
        pass

    def handle_stop(self, exe_ctx, _stream):
        "Method that is called when the user stops in lldb."
        module = exe_ctx.frame.module
        if not module:
            return

        module_name = module.file.GetDirectory() + "/" + module.file.GetFilename()
        versionless_triple = _TRIPLE_MATCH.sub(r"\1\2\3", module.GetTriple())
        executable_path = _get_relative_executable_path(module_name)
        key = f"{versionless_triple} {executable_path}"

        settings = _SETTINGS.get(key)

        if settings:
            frameworks = " ".join([
                f'"{path}"'
                for path in settings.get("f", [])
            ])
            if frameworks:
                lldb.debugger.HandleCommand(
                    f"settings set -- target.swift-framework-search-paths {frameworks}",
                )
            else:
                lldb.debugger.HandleCommand(
                    "settings clear target.swift-framework-search-paths",
                )

            includes = " ".join([
                f'"{path}"'
                for path in settings.get("s", [])
            ])
            if includes:
                lldb.debugger.HandleCommand(
                    f"settings set -- target.swift-module-search-paths {includes}",
                )
            else:
                lldb.debugger.HandleCommand(
                    "settings clear target.swift-module-search-paths",
                )

            clang = settings.get("c")
            if clang:
                lldb.debugger.HandleCommand(
                    f"settings set -- target.swift-extra-clang-flags '{clang}'",
                )
            else:
                lldb.debugger.HandleCommand(
                    "settings clear target.swift-extra-clang-flags",
                )

        return True
