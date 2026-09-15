#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Materialize isolated supervisor, H and profile verification configurations."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil

import pyjson5
from ruamel.yaml import YAML


PROFILE_LINKER_SUFFIX = """
/* HTIF verification devices: symbols only, without changing image layout. */
karu_htif_meip = tohost + 0x18;
karu_htif_seip = tohost + 0x20;
ASSERT((tohost & 7) == 0, "HTIF device base must be naturally aligned")
ASSERT((tohost >> 12) == ((karu_htif_seip + 7) >> 12),
       "HTIF external-input registers must stay in the uncacheable HTIF page")
ASSERT(fromhost + 8 <= karu_htif_meip || fromhost >= karu_htif_seip + 8,
       "HTIF external-input registers overlap fromhost")
ASSERT(ADDR(.text.rvmodel) >= karu_htif_seip + 8,
       "HTIF external-input registers overlap platform code")
"""


def merge(target: dict, overlay: dict) -> None:
    for key, value in overlay.items():
        # Sail option values are tagged unions, not independent fields. A
        # Some -> None overlay must remove the old tag (and vice versa).
        if isinstance(value, dict) and len(value) == 1 and next(iter(value)) in ("Some", "None"):
            target[key] = value
        elif isinstance(value, dict) and isinstance(target.get(key), dict):
            merge(target[key], value)
        else:
            target[key] = value


def write_if_changed(path: Path, contents: str) -> None:
    if not path.exists() or path.read_text() != contents:
        path.write_text(contents)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    profiles = ("karu64-rva23s64", "karu64-rva23s64-smcntrpmf")
    parser.add_argument("--configuration", choices=("karu64-sv39", "karu64-h", *profiles),
                        default="karu64-sv39")
    parser.add_argument("--ref-model-exe", help="Reference executable name or absolute path")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    baseline = source / "karu64-rv64gc"
    common_dir = source / "karu64-sv39"
    overlay_dirs = [common_dir]
    has_profile = args.configuration in profiles
    has_h = args.configuration == "karu64-h" or has_profile
    if has_h:
        overlay_dirs.append(source / "karu64-h")
    if has_profile:
        overlay_dirs.append(source / "karu64-rva23s64")
    if args.configuration == "karu64-rva23s64-smcntrpmf":
        overlay_dirs.append(source / args.configuration)
    output = args.output_dir.resolve()
    if output == source or source in output.parents:
        parser.error("generated config must be outside the tracked configuration source tree")
    output.mkdir(parents=True, exist_ok=True)

    yaml = YAML(typ="safe", pure=True)
    yaml.default_flow_style = False
    inputs = [
        baseline / "test_config.yaml",
        baseline / "karu64-rv64gc.yaml",
        baseline / "sail.json",
        baseline / "rvmodel_macros.h",
        baseline / "link.ld",
        Path(__file__).resolve(),
        common_dir / "rvmodel_macros.h",
    ]
    udb = yaml.load(inputs[1].read_text())
    sail = pyjson5.loads(inputs[2].read_text())
    sail.pop("$schema", None)
    for overlay_dir in overlay_dirs:
        udb_path = overlay_dir / "udb-overlay.yaml"
        sail_path = overlay_dir / "sail-overlay.json"
        inputs.extend((udb_path, sail_path))
        udb_overlay = yaml.load(udb_path.read_text())
        versions = udb_overlay.pop("extension_versions")
        removed_params = udb_overlay.pop("remove_params", [])
        extensions = {ext["name"]: ext for ext in udb["implemented_extensions"]}
        for name, version in versions.items():
            extensions[name] = {"name": name, "version": version}
        udb["implemented_extensions"] = list(extensions.values())
        merge(udb, udb_overlay)
        for name in removed_params:
            udb["params"].pop(name, None)
        merge(sail, json.loads(sail_path.read_text()))
    if has_h:
        # Sail 0.14 gives LR/SC a separate per-region PMA field. Preserve the
        # inherited AccessFault PMA policy without duplicating the memory map.
        # The H overlay defers atomic alignment rejection until this physical
        # check, matching the RTL's translation-before-LSU exception priority.
        for region in sail["memory"]["regions"]:
            region["attributes"]["misaligned_exceptions"]["lrsc"] = "AccessFault"
    config = yaml.load(inputs[0].read_text())
    udb_name = f"{args.configuration}.yaml"
    config.update(name=args.configuration, udb_config=udb_name, include_priv_tests=True)
    if has_h:
        config["ref_model_version"] = "0.14"
    if args.ref_model_exe:
        config["ref_model_exe"] = args.ref_model_exe

    for name, data in ((udb_name, udb), ("test_config.yaml", config)):
        contents = io.StringIO()
        yaml.dump(data, contents)
        write_if_changed(output / name, "# Generated by test/act4-karu/generate_config.py\n" + contents.getvalue())
    write_if_changed(output / "sail.json", json.dumps(sail, indent=2) + "\n")
    macros = (common_dir / "rvmodel_macros.h").read_text()
    if has_profile:
        macros = "#define RVMODEL_HTIF_CLINT\n#define RVMODEL_HTIF_EXTIRQ\n" + macros
    write_if_changed(output / "rvmodel_macros.h", macros)
    write_if_changed(output / "rvmodel_common.h", (baseline / "rvmodel_macros.h").read_text())
    linker = (baseline / "link.ld").read_text()
    if has_profile:
        linker += PROFILE_LINKER_SUFFIX
    write_if_changed(output / "link.ld", linker)
    manifest = {
        "configuration": args.configuration,
        "purpose": "Privileged-1.13 development verification; not an RVA23S64 compliance claim",
        "reference_executable": config["ref_model_exe"],
        "reference_version": config.get("ref_model_version", "0.13.1"),
        "inputs_sha256": {
            str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs
        },
    }
    if has_profile:
        reference = shutil.which(config["ref_model_exe"])
        manifest["rtl_build_define"] = "KARU_RVA23S64"
        manifest["testbench_defines"] = ["HTIF_TB_CLINT", "HTIF_TB_EXTIRQ"]
        if args.configuration == "karu64-rva23s64-smcntrpmf":
            manifest["rtl_additional_defines"] = ["KARU_SMCNTRPMF"]
        manifest["reference_executable_sha256"] = (
            hashlib.sha256(Path(reference).read_bytes()).hexdigest() if reference else None
        )
        manifest["outputs_sha256"] = {
            name: hashlib.sha256((output / name).read_bytes()).hexdigest()
            for name in (udb_name, "test_config.yaml", "sail.json", "rvmodel_macros.h", "rvmodel_common.h", "link.ld")
        }
    write_if_changed(output / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    print(f"{args.configuration} verification config: {output / 'test_config.yaml'}")


if __name__ == "__main__":
    main()
