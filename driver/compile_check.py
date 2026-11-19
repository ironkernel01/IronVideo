#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compile the canonical IronVideo object against an existing MicroBlaze build."""

import argparse
import hashlib
import json
import re
import shlex
import struct
import subprocess
import sys
from pathlib import Path
from tempfile import mkdtemp

DRIVER = Path(__file__).resolve().parent
CORE_ROOT = DRIVER.parent


def embedded_workspace():
    # Keep the invocation path for an IronForge junction. Source provenance
    # and Kbuild still use the one physical checkout via DRIVER and CORE_ROOT.
    invoked = Path(__file__).absolute().parent.parent
    for candidate in (invoked.parent.parent, invoked.parent.parent.parent.parent):
        if ((candidate / "IRONFORGE.md").is_file() and invoked in
                (candidate / "rtl/ironvideo", candidate / "rtl/ironvideo/sources/IronVideo")):
            return candidate.resolve()
    return None


def hashes(paths):
    results = {}
    for path in paths:
        with path.open("rb") as stream:
            results[str(path)] = hashlib.file_digest(stream, "sha256").hexdigest()
    return results


def check_register_map():
    header = (DRIVER / "ironvideo_regs.h").read_text()
    rtl = (CORE_ROOT / "hdl/ironvideo_scanout.sv").read_text()
    c_map = dict(re.findall(r"^#define IV_REG_(\w+)\s+0x([a-f\d]+)", header, re.M))
    rtl_map = dict(re.findall(r"\bREG_(\w+) = 'h([a-f\d]+)", rtl))
    if not c_map or c_map != rtl_map:
        raise ValueError("IronVideo C/RTL register mismatch")
    def constant(name):
        return re.search(rf"^#define IV_{name}\s+0x([\da-f]+)", header, re.M)[1]

    if f"register_value[REG_ID / 4] = 32'h{constant('ID')};" not in rtl:
        raise ValueError("IronVideo C/RTL ID mismatch")
    versions = f"32'h{constant('VERSION_FORMATS')} : 32'h{constant('VERSION_LEGACY')}"
    if f"register_value[REG_VERSION / 4] = EXTENDED_ABI ? {versions};" not in rtl:
        raise ValueError("IronVideo C/RTL version profile mismatch")
    for name in ("ROW_WORST", "ROW_BEST", "PEAK_RATE_CYCLES"):
        if not re.search(rf"accept_read.*s_axi_araddr == REG_{name}", rtl):
            raise ValueError(f"IronVideo RTL no longer clears {name} on a read")
    return len(c_map)


def check_microblaze_object(path):
    if path.read_bytes()[:20] != struct.pack(
        "<16sHH", b"\x7fELF\x01\x01\x01", 1, 189
    ):
        raise ValueError(f"Output is not a little-endian MicroBlaze ELF object: {path}")


def compile_uboot(configured, output, source, bash, env, msys, posix):
    """Reuse the configured board's actual Kbuild flags with scratch outputs."""
    cmd_file = configured / "board/xilinx/microblaze-generic/.ironvideo_core.o.cmd"
    target = "board/xilinx/microblaze-generic/ironvideo_core.o"
    prefix = f"cmd_{target} := "
    commands = [line.removeprefix(prefix) for line in cmd_file.read_text().splitlines()
                if line.startswith(prefix)]
    if len(commands) != 1 or "-D__UBOOT__" not in commands[0]:
        raise ValueError("Configured Nexys U-Boot build lacks its IronVideo compiler command")
    command = commands[0]
    object_path = output / "ironvideo_uboot.o"
    dependency_path = output / "ironvideo_uboot.d"
    replacements = (
        (r"(?<=-Wp,-MMD,)\S+", posix(dependency_path)),
        (r"(?<= -o )\S+", posix(object_path)),
        (r"\S+/driver/ironvideo\.c(?=\s*$)", posix(source)),
    )
    for pattern, destination in replacements:
        command, count = re.subn(pattern, shlex.quote(destination), command)
        if count != 1:
            raise ValueError("Unrecognized configured U-Boot object command")
    shell = [str(bash), "-c", msys.SHELL_PREFIX + command]
    log = output / "uboot-compile.log"
    with log.open("wb") as stream:
        subprocess.run(shell, cwd=configured, env=env, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)
    check_microblaze_object(object_path)
    return {
        "command": shell,
        "inputs": hashes([cmd_file, configured / ".config",
                          configured / "include/generated/autoconf.h"]),
        "outputs": hashes([object_path, dependency_path, log]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_output", type=Path)
    parser.add_argument("--ironforge-root", type=Path,
                        help="IronForge workspace providing the pinned Linux and native build tools")
    parser.add_argument("--amd-root", type=Path)
    parser.add_argument("--msys-root", type=Path)
    parser.add_argument("--uboot-output", type=Path,
                        help="optionally compile the firmware adapter using configured Nexys U-Boot flags")
    args = parser.parse_args()

    embedded = embedded_workspace()
    root = args.ironforge_root.resolve() if args.ironforge_root else embedded
    if root is None or not (root / "src/ironforge/msys.py").is_file() or not (root / "IRONFORGE.md").is_file():
        parser.error("provide a valid IronForge workspace with --ironforge-root")
    sys.path.insert(0, str(root / "src"))
    from ironforge import msys
    from ironforge.sources import shared_source_lock
    from ironforge.tools import discover_amd, discover_msys, posix

    kernel = root / "linux-7.3.4"
    configured = args.kernel_output.resolve(strict=True)
    config_paths = [configured / name for name in (".config", "include/config/auto.conf")]
    amd = discover_amd(args.amd_root)
    tools = discover_msys(args.msys_root) / "usr/bin"
    gcc = amd["gcc"]
    output_root = embedded / "build/ironvideo/driver" if embedded else CORE_ROOT / "build/driver"
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(mkdtemp(prefix="compile-", dir=output_root))

    command = [
        "/usr/bin/make", "-C", posix(kernel), "O=" + posix(configured),
        "M=" + posix(DRIVER), "MO=" + posix(output), "ARCH=microblaze",
        "CROSS_COMPILE=" + posix(gcc).removesuffix("gcc.exe"),
        *msys.HOST_MAKE_ARGS, r"stringify=$(squote)\$(quote)$1\$(quote)$(squote)",
        "CONFIG_DRM_IRONVIDEO=y", "V=1", "W=1", "ironvideo_drm.o",
    ]
    log = output / "compile.log"
    obj = output / "ironvideo_drm.o"
    cmd_log = output / ".ironvideo_drm.o.cmd"
    env = msys.environment()
    env.update(TZ="UTC", KBUILD_BUILD_USER="ironforge", KBUILD_BUILD_HOST="windows")
    shell = [str(tools / "bash.exe"), "-c", msys.SHELL_PREFIX + shlex.join(command)]

    print(f"Compile output {output}", flush=True)
    with shared_source_lock(root):
        registers = check_register_map()
        old_config = hashes(config_paths)
        with log.open("wb") as stream:
            subprocess.run(shell, cwd=root, env=env, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
        if hashes(config_paths) != old_config:
            raise ValueError("Kbuild changed the configured kernel inputs")
        check_microblaze_object(obj)
        # Kbuild records actual translation-unit dependencies using POSIX paths
        # relative to MO or absolute paths. Hash those files directly.
        deps = set()
        for token in re.findall(r"^  ([^\s$]+) \\", cmd_log.read_text(), re.M):
            if re.match(r"/[a-z]/", token):
                token = token[1] + ":" + token[2:]
            path = (output / token).resolve()
            if path.is_file():
                deps.add(path)
        source = DRIVER / "ironvideo.c"
        header = DRIVER / "ironvideo_regs.h"
        source_entry = f"source_ironvideo_drm.o := {posix(source)}"
        if (source_entry not in cmd_log.read_text().splitlines() or header not in deps
                or DRIVER / "ironvideo_core.h" not in deps):
            raise ValueError("Kbuild did not record the canonical driver source and headers")
        receipt = {
            "command": shell,
            "canonical_linux": str(kernel),
            "configured_kernel": str(configured),
            "canonical_driver": str(source),
            "config_inputs": old_config,
            "registers_verified": registers,
            "inputs": hashes(sorted(deps | {
                source, header, DRIVER / "Kconfig", DRIVER / "Kbuild", DRIVER / "builtin.mk",
                Path(__file__).resolve(),
                CORE_ROOT / "hdl/ironvideo_scanout.sv", kernel / "Makefile",
                kernel / ".ironforge-source.json", kernel / ".ironforge-patches.json",
            })),
            "tools": hashes([gcc, Path(sys.executable)] + [
                tools / name for name in ("bash.exe", "make.exe", "msys-2.0.dll")
            ]),
            "gcc_version": subprocess.check_output([gcc, "--version"], text=True).splitlines()[0],
            "outputs": hashes([obj, cmd_log, log]),
            "scope": "MicroBlaze object only",
        }
        if args.uboot_output:
            receipt["uboot"] = compile_uboot(args.uboot_output.resolve(strict=True),
                                             output, source, tools / "bash.exe", env, msys, posix)
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n",
                                             encoding="utf-8")
    print(f"PASS ({registers} registers and {'Linux/U-Boot' if args.uboot_output else 'Linux'} MicroBlaze ELF objects)")


if __name__ == "__main__":
    main()
