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
    for name in ("ID", "VERSION"):
        value = re.search(rf"^#define IV_{name}\s+0x([\da-f]+)", header, re.M)
        if not value or f"register_value[REG_{name} / 4] = 32'h{value[1]};" not in rtl:
            raise ValueError(f"IronVideo C/RTL {name} mismatch")
    for name in ("ROW_WORST", "ROW_BEST"):
        if not re.search(rf"accept_read.*s_axi_araddr == REG_{name}", rtl):
            raise ValueError(f"IronVideo RTL no longer clears {name} on a read")
    return len(c_map)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_output", type=Path)
    parser.add_argument("--ironforge-root", type=Path,
                        help="IronForge workspace providing the pinned Linux and native build tools")
    parser.add_argument("--amd-root", type=Path)
    parser.add_argument("--msys-root", type=Path)
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
        if obj.read_bytes()[:20] != struct.pack(
            "<16sHH", b"\x7fELF\x01\x01\x01", 1, 189
        ):
            raise ValueError("Driver output is not a little-endian MicroBlaze ELF object")
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
        if source_entry not in cmd_log.read_text().splitlines() or header not in deps:
            raise ValueError("Kbuild did not record the canonical driver source and header")
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
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n",
                                             encoding="utf-8")
    print(f"PASS ({registers} registers and MicroBlaze ELF object)")


if __name__ == "__main__":
    main()
