#!/usr/bin/env python3
"""Bind existing feature-off mappings to exact preprocessed source equality.

Preprocessor-guarded changes require lexical identity, including comments and
synthesis directives. Only whitespace and `line bookkeeping are ignored.
The ordered source manifest also detects macro leakage into later files.
One separately checked exception supports the DM's AUTOEXEC=0 constant guard:
its module body may be replaced only after Yosys sequential equivalence proves
all outputs/state, with unchanged compiler-directive/pragma environment.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
CAPTURED = ("rtl/karu64.v", "rtl/karu_vlsu.v", "dbg/karudbg.v")
FEATURES = {"base": set(), "autoexec": {"KARU_DBG_AUTOEXEC"}, "sba": {"KARU_DBG_SBA"},
            "triggers": {"KARU_DBG_TRIGGERS"}}
FEATURE_NAMES = {"KARU_DBG_AUTOEXEC", "KARU_DBG_TRIGGERS", "KARU_DBG_SBA", "KARU_DBG_FULL", "KARU_DBG_TRIGGER_COUNT"}
PRELUDE = "`undef __ICARUS__\n"
HASH = re.compile(r"^([0-9a-f]{64})\s+\*?(.+)$")
LINE = re.compile(r'`line[ \t]+[0-9]+[ \t]+"(?:[^"\\\n]|\\.)*"[ \t]+[012][ \t]*(?:\n|$)')
NUMBER = re.compile(r"(?:[0-9][0-9_]*[ \t]*)?'[sS]?[bBoOdDhH][ \t]*[0-9a-fA-F_xXzZ?]+|"
                    r"'[01xXzZ]|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?")
IDENT = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
OPERATORS = sorted(("<<<", ">>>", "===", "!==", "&&&", "==?", "!=?", "**", "<<", ">>",
                    "<=", ">=", "==", "!=", "&&", "||", "~^", "^~", "~&", "~|", "+:", "-:",
                    "->", "=>", "*>", "(*", "*)"), key=len, reverse=True)
SINGLE = set(";:,.(){}[]+-*/%&|^~!=<>?#@'`")


def sha(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def record(path):
    path = Path(path).resolve()
    return {"path": str(path), "sha256": sha(path)}


def read_hashes(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        match = HASH.fullmatch(line)
        if not match:
            raise ValueError("malformed fingerprint: " + str(path))
        value, name = match.groups()
        if name in result:
            raise ValueError("duplicate fingerprint path: " + name)
        result[name] = value
    if not result:
        raise ValueError("empty fingerprint: " + str(path))
    return result


def tokenize(text):
    tokens, index = [], 0
    while index < len(text):
        ch = text[index]
        if ch in " \t\r\n\f\v":
            index += 1
            continue
        if ch == "`" and (index == 0 or text[text.rfind("\n", 0, index) + 1:index].strip() == ""):
            match = LINE.match(text, index)
            if match:
                index = match.end()
                continue
        if text.startswith("//", index):
            end = text.find("\n", index)
            if end < 0:
                end = len(text)
            tokens.append(("comment", text[index:end]))
            index = end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                raise ValueError("unterminated Verilog comment")
            tokens.append(("comment", text[index:end + 2]))
            index = end + 2
            continue
        if ch == '"':
            end = index + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                elif text[end] == '"':
                    end += 1
                    break
                elif text[end] == "\n":
                    raise ValueError("newline in Verilog string")
                else:
                    end += 1
            else:
                raise ValueError("unterminated Verilog string")
            tokens.append(("string", text[index:end]))
            index = end
            continue
        if ch == "\\":
            end = index + 1
            while end < len(text) and text[end] not in " \t\r\n\f\v":
                end += 1
            if end == index + 1:
                raise ValueError("empty escaped identifier")
            tokens.append(("escaped_identifier", text[index:end]))
            index = end
            continue
        match = NUMBER.match(text, index) if ch.isdigit() or ch == "'" else None
        if match:
            tokens.append(("number", re.sub(r"[ \t]", "", match.group())))
            index = match.end()
            continue
        match = IDENT.match(text, index)
        if match:
            tokens.append(("identifier", match.group()))
            index = match.end()
            continue
        op = next((op for op in OPERATORS if text.startswith(op, index)), None)
        if op:
            tokens.append(("operator", op))
            index += len(op)
        elif ch in SINGLE:
            tokens.append(("punctuation", ch))
            index += 1
        else:
            raise ValueError(f"unrecognized Verilog character {ch!r} at {index}")
    return tokens


def token_identity(text, proved_dm=False):
    tokens = tokenize(text)
    if proved_dm:
        # Only this module is replaced by a separate, checked sequential
        # equivalence theorem. All following modules remain in the token
        # comparison, so preprocessor effects cannot leak past this scope.
        filtered, index, matches = [], 0, 0
        while index < len(tokens):
            if tokens[index:index + 2] == [("identifier", "module"), ("identifier", "karudbg")]:
                matches += 1
                index += 2
                while index < len(tokens) and tokens[index] != ("identifier", "endmodule"):
                    index += 1
                if index == len(tokens):
                    raise ValueError("unterminated proved DM module")
                filtered.append(("proved_module", "karudbg AUTOEXEC=0"))
                index += 1
            else:
                filtered.append(tokens[index])
                index += 1
        if matches != 1:
            raise ValueError("semantic waiver requires exactly one karudbg module")
        tokens = filtered
    serialized = json.dumps(tokens, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(serialized).hexdigest(), len(tokens)


def dm_verifier():
    path = REPO / "dbg/dm_equivalence.py"
    spec = importlib.util.spec_from_file_location("karudbg_dm_equivalence", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def metadata(directory):
    text = (directory / "log/manifest.txt").read_text()
    config = dict(re.findall(r"^(KARU_\w+)=([^\n]*)$", text, re.MULTILINE))
    if config.get("KARU_TOP") != "karudbg_top":
        raise ValueError("source proof requires karudbg_top")
    name = directory.name.split("_", 1)[-1]
    defines = shlex.split(config.get("KARU_DEFINES", ""))
    if any(not word.split("=", 1)[0].startswith("KARU_") for word in defines):
        raise ValueError("proof scope requires KARU defines and the unmodified Yosys implicit macros")
    features = {word for word in defines if word.split("=", 1)[0] in FEATURE_NAMES}
    if name not in FEATURES or features != FEATURES[name] or "KARU_DBG" not in defines:
        raise ValueError("source proof is only valid for independently selected extension rows")
    path = Path(config["KARU_RTL_MANIFEST"]).resolve()
    sources = []
    for line in path.read_text().splitlines():
        name = line.split("//", 1)[0].split("#", 1)[0].strip()
        if name:
            source = Path(name)
            sources.append(source.resolve() if source.is_absolute() else (REPO / source).resolve())
    return defines, path, sources


def preprocess(tool, defines, prelude, sources):
    command = [str(tool), "-g2001", "-E", "-o", "-", "-I" + str(REPO / "rtl"),
               "-I" + str(REPO / "dbg"), "-DYOSYS", "-DSYNTHESIS"]
    command += ["-D" + word for word in defines]
    command += [str(prelude), *map(str, sources)]
    result = subprocess.run(command, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=60)
    if result.returncode:
        raise ValueError("preprocessing failed: " + result.stderr)
    return command, result.stdout


def artifact_paths(directory):
    paths = [directory / "generated/karudbg_top_netlist.v",
             directory / "generated/karudbg_top_netlist.sta.v", directory / "reports/area.rpt",
             directory / "log/syn.log"]
    if directory.name.startswith("timing_"):
        paths += [directory / "reports/timing/summary.rpt", directory / "log/sta.log"]
        paths += [directory / f"reports/timing/{name}.csv.rpt"
                  for name in ("reg2reg", "in2reg", "reg2out", "in2out")]
    return paths


def complete(directory):
    before = directory / "log/inputs.before.sha256"
    after = directory / "log/inputs.after.sha256"
    artifacts = [directory / "log/manifest.txt", *artifact_paths(directory)]
    return (before.is_file() and after.is_file() and all(path.is_file() for path in artifacts) and
            before.stat().st_mtime_ns <= after.stat().st_mtime_ns and
            all(before.stat().st_mtime_ns <= path.stat().st_mtime_ns <= after.stat().st_mtime_ns
                for path in artifacts))


def generate(directory, before_dir):
    directory, before_dir = directory.resolve(), before_dir.resolve()
    defines, manifest, sources = metadata(directory)
    before_path, after_path = (directory / "log" / name for name in ("inputs.before.sha256", "inputs.after.sha256"))
    if not complete(directory):
        raise ValueError("mapping/STA artifacts are not complete yet")
    inputs = read_hashes(before_path)
    changes = {}
    allowed = {str((REPO / name).resolve()) for name in CAPTURED}
    after = read_hashes(after_path)
    if inputs.keys() != after.keys():
        raise ValueError("mapping input set changed")
    actual_changed = {path for path, value in inputs.items()
                      if not Path(path).is_file() or sha(Path(path)) != value or after[path] != value}
    if not actual_changed.issubset(allowed):
        raise ValueError("non-source mapping inputs changed")
    if directory.name.endswith("_triggers") and actual_changed != {str((REPO / "dbg/karudbg.v").resolve())}:
        raise ValueError("trigger-row reuse requires unchanged core/VLSU and only an AUTOEXEC=0 DM change")
    for name in CAPTURED:
        current, old = (REPO / name).resolve(), before_dir / Path(name).name
        if str(current) not in actual_changed:
            continue
        if str(current) not in inputs or not old.is_file() or sha(old) != inputs[str(current)]:
            raise ValueError("captured source does not match mapping fingerprint: " + name)
        changes[str(current)] = {"old": record(old), "current_sha256": sha(current)}
    out = directory / "log/source-equivalence"
    out.mkdir(exist_ok=True)
    prelude = out / "prelude.vh"
    prelude.write_text(PRELUDE)
    tool_path = shutil.which("iverilog")
    if not tool_path:
        raise ValueError("iverilog is required for the source identity proof")
    tool = Path(tool_path).resolve()
    substitutions = {Path(path): Path(item["old"]["path"]) for path, item in changes.items()}
    dm = (REPO / "dbg/karudbg.v").resolve()
    semantic = None
    if dm in substitutions:
        verifier = dm_verifier()
        semantic = verifier.execute(REPO, defines, [substitutions.get(path, path) for path in sources], sources,
                                    substitutions[dm], dm, out / "dm", record)
        semantic["generator"] = record(Path(verifier.__file__))
    scopes = []
    for name, selected in [("manifest", sources), *[(Path(path).stem, [Path(path)]) for path in changes if Path(path) != dm]]:
        old_sources = [substitutions.get(path, path) for path in selected]
        old_command, old_text = preprocess(tool, defines, prelude, old_sources)
        new_command, new_text = preprocess(tool, defines, prelude, selected)
        mask_dm = semantic is not None and name == "manifest"
        old_tokens, count = token_identity(old_text, mask_dm)
        new_tokens, new_count = token_identity(new_text, mask_dm)
        if old_tokens != new_tokens or count != new_count:
            raise ValueError("preprocessed token mismatch: " + name)
        old_output, new_output = out / (name + "-old.pp.v"), out / (name + "-current.pp.v")
        old_output.write_text(old_text)
        new_output.write_text(new_text)
        scopes.append({"name": name, "old_command": old_command, "current_command": new_command,
                       "old_output": record(old_output), "current_output": record(new_output),
                       "token_sha256": old_tokens, "token_count": count, "proved_dm": mask_dm})
    proof = {"schema": 1, "utc": datetime.now(timezone.utc).isoformat(), "top": "karudbg_top",
             "row_directory": str(directory), "row_manifest": record(directory / "log/manifest.txt"),
             "before_fingerprint": record(before_path), "after_fingerprint": record(after_path),
             "rtl_manifest": record(manifest), "defines": defines, "implicit_defines": ["YOSYS", "SYNTHESIS"],
             "prelude": record(prelude), "preprocessor": record(tool), "generator": record(Path(__file__)),
             "files": changes, "scopes": scopes, "dm_equivalence": semantic,
             "artifacts": [record(path) for path in artifact_paths(directory)]}
    path = directory / "log/source-equivalence.json"
    path.write_text(json.dumps(proof, indent=2) + "\n")
    verify_row_proof(directory, actual_changed)
    return path


def verify_row_proof(directory, changed_paths):
    directory = Path(directory).resolve()
    proof = json.loads((directory / "log/source-equivalence.json").read_text())
    defines, manifest, sources = metadata(directory)
    if proof.get("schema") != 1 or proof.get("top") != "karudbg_top" or proof.get("row_directory") != str(directory):
        raise ValueError("wrong proof schema/top/row")
    if proof["generator"] != record(Path(__file__)) or proof["defines"] != defines or proof["implicit_defines"] != ["YOSYS", "SYNTHESIS"]:
        raise ValueError("proof generator or preprocessing defines changed")
    tool_path = shutil.which("iverilog")
    if not tool_path or proof["preprocessor"] != record(Path(tool_path)):
        raise ValueError("proof preprocessor changed")
    expected_records = {"row_manifest": directory / "log/manifest.txt",
                        "before_fingerprint": directory / "log/inputs.before.sha256",
                        "after_fingerprint": directory / "log/inputs.after.sha256", "rtl_manifest": manifest}
    if any(proof[key] != record(path) for key, path in expected_records.items()):
        raise ValueError("row manifest/input fingerprint changed after proof")
    if proof["artifacts"] != [record(path) for path in artifact_paths(directory)]:
        raise ValueError("mapped netlist/report artifacts changed after proof")
    before, after = read_hashes(expected_records["before_fingerprint"]), read_hashes(expected_records["after_fingerprint"])
    if before.keys() != after.keys():
        raise ValueError("mapping input set changed")
    actual_changed = {path for path, value in before.items()
                      if not Path(path).is_file() or sha(Path(path)) != value or after[path] != value}
    if actual_changed != set(changed_paths):
        raise ValueError("proof change set is not the exact mapping/current difference")
    if directory.name.endswith("_triggers") and actual_changed != {str((REPO / "dbg/karudbg.v").resolve())}:
        raise ValueError("trigger-row reuse requires unchanged core/VLSU and only an AUTOEXEC=0 DM change")
    # Mapping tools are recorded in the manifest, separately from source and
    # Liberty fingerprints. They may never be waived by a source-token proof.
    text = expected_records["row_manifest"].read_text()
    recorded = {match[2]: match[1] for line in text.splitlines() if (match := HASH.fullmatch(line))}
    for name in ["YOSYS", "YOSYS_ABC"] + (["OPENSTA"] if directory.name.startswith("timing_") else []):
        match = re.search(r"^" + name + r"_EXECUTABLE=(.+)$", text, re.MULTILINE)
        if not match or recorded.get(match[1]) != sha(Path(match[1])):
            raise ValueError("mapping tool identity changed: " + name)
    allowed = {str((REPO / name).resolve()) for name in CAPTURED}
    if set(proof["files"]) != set(changed_paths) or not set(changed_paths).issubset(allowed):
        raise ValueError("proof requested for an uncaptured source")
    prelude = Path(proof["prelude"]["path"])
    if prelude != directory / "log/source-equivalence/prelude.vh" or prelude.read_text() != PRELUDE or proof["prelude"] != record(prelude):
        raise ValueError("preprocessor environment prelude changed")
    substitutions, approved = {}, {}
    for path, item in proof["files"].items():
        old = Path(item["old"]["path"])
        if not old.is_relative_to(REPO / "_build") or item["old"] != record(old) or item["old"]["sha256"] != before.get(path):
            raise ValueError("old source is not bound to the mapping input: " + path)
        current_hash = sha(Path(path))
        if current_hash != item["current_sha256"] or after[path] not in {before[path], current_hash}:
            raise ValueError("current/intermediate source hash is not covered: " + path)
        substitutions[Path(path)] = old
        if path in changed_paths:
            approved[path] = current_hash
    dm = (REPO / "dbg/karudbg.v").resolve()
    semantic = proof.get("dm_equivalence")
    if (dm in substitutions) != (semantic is not None):
        raise ValueError("missing or unexpected DM semantic proof")
    if semantic:
        verifier = dm_verifier()
        if semantic["generator"] != record(Path(verifier.__file__)):
            raise ValueError("DM equivalence verifier changed")
        verifier.verify(semantic, REPO, defines, [substitutions.get(path, path) for path in sources], sources,
                        substitutions[dm], dm, directory / "log/source-equivalence/dm", record)
    expected_scopes = [("manifest", sources), *[(Path(path).stem, [Path(path)]) for path in proof["files"] if Path(path) != dm]]
    if [name for name, _ in expected_scopes] != [item["name"] for item in proof["scopes"]]:
        raise ValueError("incomplete source/macro-leakage scope")
    for (name, selected), item in zip(expected_scopes, proof["scopes"]):
        old_command, old_text = preprocess(Path(tool_path).resolve(), defines, prelude,
                                           [substitutions.get(path, path) for path in selected])
        new_command, new_text = preprocess(Path(tool_path).resolve(), defines, prelude, selected)
        mask_dm = semantic is not None and name == "manifest"
        if item.get("proved_dm", False) != mask_dm:
            raise ValueError("wrong semantic DM exclusion scope")
        old_tokens, count = token_identity(old_text, mask_dm)
        new_tokens, new_count = token_identity(new_text, mask_dm)
        if item["old_command"] != old_command or item["current_command"] != new_command:
            raise ValueError("preprocessor command changed: " + name)
        for key, output in (("old_output", old_text), ("current_output", new_text)):
            suffix = "old" if key == "old_output" else "current"
            path = directory / "log/source-equivalence" / (name + "-" + suffix + ".pp.v")
            if item[key] != record(path) or path.read_text() != output:
                raise ValueError("preprocessed audit artifact changed: " + name)
        if old_tokens != new_tokens or count != new_count or old_tokens != item["token_sha256"] or count != item["token_count"]:
            raise ValueError("preprocessed token identity failed: " + name)
    return approved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO / "_build/syn_out/karudbg")
    parser.add_argument("--before", type=Path, default=REPO / "_build/syn_out/karudbg/reuse-proof/before")
    parser.add_argument("--rows", default="area_base,area_autoexec,area_sba,timing_base,timing_autoexec,timing_sba")
    args = parser.parse_args()
    failed = False
    for row in args.rows.split(","):
        directory = args.root / row
        if not complete(directory):
            print("PENDING", row + ": mapping/STA artifacts are not complete yet", flush=True)
            continue
        try:
            path = generate(directory, args.before)
            print("PASS exact preprocessed-source reuse:", path, flush=True)
        except (OSError, ValueError) as error:
            failed = True
            print("REJECTED", row + ":", error, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
