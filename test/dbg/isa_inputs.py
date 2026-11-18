"""Declared HTIF sources, conservative include closure and frontend coverage."""
# SPDX-License-Identifier: BSD-2-Clause
from functools import lru_cache
from pathlib import Path
import re
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def key(path):
    path = Path(path).resolve()
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


@lru_cache(maxsize=1)
def runtime_paths():
    command = ["make", "-s", "--no-print-directory", "--eval=karudbg-print-isa-sources:;@printf '%s\\n' $(HTIF_SRC) $(ZVK_RTL)",
               "karudbg-print-isa-sources"]
    declared = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, check=True, timeout=30).stdout.splitlines()
    pending = [(ROOT / name).resolve() for name in declared if name.strip()]
    # Keep every optional HTIF observer in the before-build snapshot, even
    # when a particular preprocessor configuration does not select it.
    pending += list((ROOT / "test").glob("*.vh"))
    files = set()
    while pending:
        path = pending.pop().resolve()
        if path in files:
            continue
        if not path.is_file():
            raise ValueError("declared HTIF source/include missing: " + str(path))
        files.add(path)
        if path.suffix not in {".v", ".sv", ".vh", ".svh"}:
            continue
        text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
        for match in re.finditer(r'^\s*`include\s+"([^"\n]+)"', text, re.M):
            name = match[1]
            candidates = (path.parent / name, ROOT / "rtl" / name, ROOT / "dbg" / name, ROOT / name)
            found = next((p for p in candidates if p.is_file()), None)
            if found is None:
                raise ValueError("HTIF include closure missing: " + name)
            pending.append(found)
    files.update(ROOT / name for name in ("Makefile", "dbg/isa.mk", "flow/sim_tb.cpp", "test/dbg/isa_inputs.py",
                                          "test/dbg/build_isa.py", "test/dbg/replay_isa.py"))
    # These are also S-inputs in Verilator's frontend manifest. Cover them
    # before compilation so the after-build coverage check has no exception.
    verilator = shutil.which("verilator")
    if not verilator:
        raise ValueError("verilator not found")
    tool_root = Path(subprocess.run([verilator, "--getenv", "VERILATOR_ROOT"], check=True,
                                    stdout=subprocess.PIPE, text=True, timeout=10).stdout.strip())
    files.add(Path(verilator).resolve())
    binary = shutil.which("verilator_bin") or str(Path(verilator).resolve().with_name("verilator_bin"))
    files.add(Path(binary).resolve())
    files.update(path.resolve() for pattern in ("*.sv", "*.vlt") for path in (tool_root / "include").glob(pattern))
    return frozenset(key(path) for path in files)


def frontend_sources(path):
    files = set()
    for line in Path(path).read_text().splitlines():
        if line.startswith("S "):
            files.add(key(Path(shlex.split(line)[-1])))
    return files
