#!/usr/bin/env python3
"""Rewrite Verilog so strict synthesis front-ends (Genus) accept it:

  1. split every net declaration-assignment
         wire [7:0] x = a & b;      ->   wire [7:0] x;
                                         assign x = a & b;
     (multi-declarator statements are split per declarator; the expression
     text is moved verbatim, continuation lines re-indented);
  2. hoist declarations that are used before they are declared: a fresh
     `<type> [range] name [dims];` is inserted before the module-level item
     that holds the first use, and every original declaration of that name
     is removed (branches of `ifdef/`else that both declared it collapse to
     the one unconditional declaration).  Iterated to a fixed point, since a
     hoisted range may itself refer to a later localparam.

`reg`/`integer` initialisers are NOT rewritten (they are power-up state; the
ASIC manifest already has none outside sim-only regions) -- they are reported.
Uses flow/asic/lint_decl.py for parsing; edits are applied to the original
text by character offset, so comments and formatting elsewhere are untouched.

    flow/asic/fix_decl.py [--dry-run] [files...]     # default: ASIC manifest
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lint_decl as L   # noqa: E402

ROOT = L.ROOT


def line_start(raw, pos):
    return raw.rfind('\n', 0, pos) + 1


def line_end(raw, pos):
    e = raw.find('\n', pos)
    return len(raw) if e < 0 else e


def indent_of(raw, pos):
    ls = line_start(raw, pos)
    k = ls
    while k < len(raw) and raw[k] in ' \t':
        k += 1
    return raw[ls:k]


def col_of(raw, pos):
    return pos - line_start(raw, pos)


def reindent(expr, old_col, new_col):
    """Shift continuation lines of a moved expression by new_col - old_col."""
    lines = expr.split('\n')
    if len(lines) == 1:
        return expr
    delta = new_col - old_col
    out = [lines[0]]
    for ln in lines[1:]:
        if ln.lstrip().startswith('`'):
            out.append(ln)                      # preprocessor line: keep as is
        elif delta >= 0:
            out.append((' ' * delta) + ln if ln.strip() else ln)
        else:
            k = 0
            while k < -delta and k < len(ln) and ln[k] == ' ':
                k += 1
            out.append(ln[k:])
    return '\n'.join(out)


# ---------------------------------------------------------------- phase 1 ---
def split_decl_inits(raw, path, report):
    findings, toks, modules, _ = L.lint_file_text(raw, path)
    edits = []   # (pos_start, pos_end, replacement)
    inserts = {} # insertion pos -> [assign text, ...] in source order
    n_split = 0
    for m in modules:
        # group decl-inits by statement so multi-declarator statements are handled once
        by_stmt = {}
        for d in m.decl_inits:
            if d['kind'] not in L.NET_KW:
                report.append(f'{path}:{d["line"]}: {d["kind"]} {d["name"]} has an initialiser (left as is)')
                continue
            by_stmt.setdefault(d['stmt'], []).append(d)
        for (s, e), ds in sorted(by_stmt.items()):
            semi = toks[e]
            seg = raw[toks[s].pos:semi.end]
            tail = raw[semi.end:line_end(raw, semi.pos)]
            # A statement whose expression contains `ifdef lines splits fine (the
            # expression moves verbatim, directives and all). The one shape that
            # does not is a shared head with one body per branch:
            #     wire x =
            # `ifdef A
            #     expr_a;
            # `else
            #     expr_b;
            # `endif
            # i.e. the line after the closing ';' is `else/`elsif and the line
            # after that is an expression fragment, not a new statement.
            le = line_end(raw, semi.pos)
            nxt = raw[le + 1:le + 200].split('\n')
            if len(nxt) >= 2 and re.match(r'\s*`(else|elsif)', nxt[0]) and \
               not re.match(r'\s*(`|//|wire\b|reg\b|assign\b|localparam\b|parameter\b|integer\b|genvar\b|always\b|if\b|for\b|generate\b|initial\b|function\b|task\b|end\b|$)', nxt[1]):
                report.append(f'{path}:{toks[s].line}: {ds[0]["name"]}: shared declaration head with one '
                              f'body per `ifdef branch -- split by hand')
                continue
            indent = indent_of(raw, toks[s].pos)
            assigns = []
            for d in sorted(ds, key=lambda d: d['declr']['name_idx']):
                dec = d['declr']
                i0, i1 = dec['init']
                eq_idx = i0 - 1                       # the '=' token
                # expression text starts right after '=' (only same-line blanks
                # skipped) so `ifdef lines between '=' and the first token move
                # with it instead of being dropped
                expr_start = toks[eq_idx].end
                while expr_start < len(raw) and raw[expr_start] in ' \t':
                    expr_start += 1
                # the last declarator's expression runs up to the ';' itself so a
                # trailing `endif line (guarded tail of the expression) moves too
                expr_end = semi.pos if dec['end'] == e else toks[i1 - 1].end
                expr = raw[expr_start:expr_end].rstrip(' \t')
                if expr.endswith('\n'):
                    expr = expr.rstrip('\n')
                # cut from the whitespace before '=' up to the end of the expression
                cut_start = toks[eq_idx].pos
                while cut_start > 0 and raw[cut_start - 1] in ' \t':
                    cut_start -= 1
                edits.append((cut_start, expr_end, ''))
                head = f'{indent}assign {dec["name"]} = '
                if expr.startswith('\n'):
                    # expression begins on the next line: keep its original layout
                    body = head.rstrip(' ') + expr
                else:
                    body = head + reindent(expr, col_of(raw, expr_start), len(head))
                # a ';' may not share a line with a preprocessor directive
                if body.split('\n')[-1].lstrip().startswith('`'):
                    body += '\n' + indent + '    '
                assigns.append(body + ';')
                n_split += 1
            # insert the assigns after the end of the line holding the ';' -- unless
            # more code follows on that line (e.g. `... end`), then right after ';'
            rest = tail.strip()
            if rest and not rest.startswith('//'):
                ins = semi.end
                inserts.setdefault(ins, []).extend(' ' + a.strip() for a in assigns)
            else:
                ins = line_end(raw, semi.pos)
                inserts.setdefault(ins, []).extend('\n' + a for a in assigns)
    for ins, texts in inserts.items():
        edits.append((ins, ins, ''.join(texts)))
    return apply_edits(raw, edits), n_split


def apply_edits(raw, edits):
    # apply from the end so earlier offsets stay valid; insertions at the same
    # position keep their listed order
    out = raw
    for (a, b, rep) in sorted(edits, key=lambda x: (x[0], x[1]), reverse=True):
        out = out[:a] + rep + out[b:]
    return out


def ifdef_constructs(raw):
    """[(start_pos, end_pos)] of every `ifdef/`ifndef ... `endif construct
    (start = beginning of the `ifdef line, end = end of the `endif line)."""
    out, stack = [], []
    for m in re.finditer(r'^[ \t]*`(ifdef|ifndef|endif)\b[^\n]*', raw, re.M):
        if m.group(1) in ('ifdef', 'ifndef'):
            stack.append(m.start())
        elif stack:
            out.append((stack.pop(), m.end()))
    return out


def hoist_target(raw, tgt_pos, decl_pos):
    """Where to put a hoisted declaration so that it is visible wherever the
    original was: before the target item, moved out in front of every
    `ifdef construct that contains the target but not the original."""
    pos = tgt_pos
    for (a, b) in sorted(ifdef_constructs(raw)):        # outermost first
        if a <= tgt_pos < b and not (a <= decl_pos < b):
            return a
    return pos


# ---------------------------------------------------------------- phase 2 ---
def hoist_ubd(raw, path, report):
    """One hoisting pass; returns (new_text, number_hoisted, blocked_list)."""
    findings, toks, modules, _ = L.lint_file_text(raw, path)
    edits = []
    n_hoist = 0
    blocked = []
    for f, m in zip(findings, modules):
        if not f['use_before_declare']:
            continue
        # map use -> enclosing top-level item start index
        item_of_use = {}
        for (name, line, idx, item, depth, scope) in m.uses:
            if scope is not None and name in scope:
                continue
            item_of_use.setdefault(name, []).append((line, item, idx))
        for x in f['use_before_declare']:
            name = x['name']
            decls = m.decls.get(name)
            if not decls:
                continue
            uses = sorted(item_of_use.get(name, []))
            first_line, item, uidx = uses[0]
            if item is None:
                item = uidx
            tgt_tok = toks[item]
            # never split an if/else pair
            if (item > 0 and toks[item - 1].kind == 'id' and toks[item - 1].text == 'else') \
               or tgt_tok.text == 'else':
                blocked.append(f'{path}:{first_line}: {name}: first use sits in an else branch; hoist by hand')
                continue
            # all declarations of the name must agree on type/range
            protos = []
            for (dline, kind, s, e, dec) in decls:
                if dec is None:
                    protos = None; break
                grp = L.split_top_commas(toks, s + 1, e)
                first_s = grp[0][0]
                # prefix = tokens from after the keyword up to the first declarator name
                first_dec = L.parse_declarators(toks, s + 1, e)[0]
                prefix = raw[toks[s].pos:toks[first_dec['name_idx']].pos]
                dims = raw[toks[dec['dims'][0]].pos:toks[dec['dims'][1] - 1].end] if dec['dims'] else ''
                protos.append((' '.join(prefix.split()), dims, kind, s, e, dec))
            if protos is None:
                blocked.append(f'{path}:{first_line}: {name}: declared as a port/parameter; cannot hoist')
                continue
            if len({(p[0], p[1]) for p in protos}) != 1:
                blocked.append(f'{path}:{first_line}: {name}: declarations differ between branches; hoist by hand')
                continue
            prefix, dims = protos[0][0], protos[0][1]
            if protos[0][2] in ('localparam', 'parameter'):
                blocked.append(f'{path}:{first_line}: {name}: {protos[0][2]} used before declaration; move by hand')
                continue
            # insertion: before the line of the target item, but outside any
            # `ifdef construct the original declaration was not inside of
            decl_pos = toks[protos[0][3]].pos
            ins = line_start(raw, hoist_target(raw, tgt_tok.pos, decl_pos))
            indent = indent_of(raw, tgt_tok.pos)
            edits.append((ins, ins, f'{indent}{prefix} {name}{dims};   //  declared here: read below before its driver\n'))
            # remove every declarator of this name
            for (_, _, kind, s, e, dec) in protos:
                grp = L.parse_declarators(toks, s + 1, e)
                if len(grp) == 1:
                    # whole statement: remove from line start (if only whitespace precedes)
                    a = toks[s].pos; b = toks[e].end
                    ls = line_start(raw, a)
                    if raw[ls:a].strip() == '':
                        a = ls
                    # eat the newline if the rest of the line is empty
                    le = line_end(raw, b)
                    if raw[b:le].strip() == '':
                        b = min(le + 1, len(raw))
                    edits.append((a, b, ''))
                else:
                    # remove ", name[dims]" or "name[dims], "
                    k = [g for g in grp if g['name'] == name][0]
                    a = toks[k['start']].pos; b = toks[k['end'] - 1].end
                    if k is grp[0]:
                        # first declarator: keep the prefix (type/range), drop name and following comma
                        a = toks[k['name_idx']].pos
                        nxt = toks[k['end']]         # the ',' after it
                        b = toks[k['end'] + 1].pos   # start of the next declarator
                    else:
                        # drop the preceding comma and whitespace
                        a = toks[k['start'] - 1].pos
                        while a > 0 and raw[a - 1] in ' \t':
                            a -= 1
                    edits.append((a, b, ''))
            n_hoist += 1
    return apply_edits(raw, edits), n_hoist, blocked


def process(path, dry_run, report):
    raw = Path(path).read_text()
    text, n_split = split_decl_inits(raw, path, report)
    total_hoist = 0
    blocked = []
    for it in range(8):
        text, n, blocked = hoist_ubd(text, path, report)
        total_hoist += n
        if n == 0:
            break
    findings, *_ = L.lint_file_text(text, path)
    rem_ubd = sum(len(f['use_before_declare']) for f in findings)
    rem_init = sum(1 for f in findings for d in f['decl_init'] if d['kind'] in L.NET_KW)
    if not dry_run and text != raw:
        Path(path).write_text(text)
    return n_split, total_hoist, rem_ubd, rem_init, blocked


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='*')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()
    files = a.files or [str(ROOT / p) for p in (ROOT / 'flow/asic/karu64.f').read_text().split()]
    report = []
    tot = [0, 0, 0, 0]
    for f in files:
        n_split, n_hoist, rem_ubd, rem_init, blocked = process(f, a.dry_run, report)
        rel = Path(f).resolve()
        rel = rel.relative_to(ROOT) if str(rel).startswith(str(ROOT)) else rel
        flag = '' if (rem_ubd == 0 and rem_init == 0 and not blocked) else '  <-- CHECK'
        print(f'{str(rel):<36} split={n_split:<4} hoisted={n_hoist:<3} remaining ubd={rem_ubd} decl-init={rem_init}{flag}')
        for b in blocked:
            print('   BLOCKED', b)
        tot[0] += n_split; tot[1] += n_hoist; tot[2] += rem_ubd; tot[3] += rem_init
    print(f'TOTAL split={tot[0]} hoisted={tot[1]} remaining ubd={tot[2]} decl-init={tot[3]}')
    for r in report:
        print('   NOTE', r)
    return 0 if tot[2] == 0 and tot[3] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
