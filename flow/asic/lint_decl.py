#!/usr/bin/env python3
"""Verilog-2001 declaration-order lint for strict synthesis front-ends (Genus).

Reports, per module:
  * decl-init : a net/variable declared and assigned on the same statement
                (`wire x = expr;`, `reg x = 1'b0;`, `integer i = 0;`)
  * use-before-declare : an identifier used at module scope (or inside an
                always/assign/instance/generate item) before the statement
                that declares it
  * undeclared : an identifier never declared in the module and not a
                function/task/macro/system name -- usually a lint blind spot,
                so the list should stay empty

Preprocessor conditionals are treated as all-branches-present; macros are
opaque tokens (every karu64 macro expands to a constant or an expression of
constants). Declarations inside functions/tasks are scoped to that body;
everything else (generate blocks, named blocks) is folded into module scope
at its earliest declaration line, which is the conservative choice for a
"declare before use" rule.

    flow/asic/lint_decl.py [files...]        # default: the ASIC manifest
    flow/asic/lint_decl.py --json out.json   # machine-readable, used by fix_decl.py
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

KEYWORDS = set('''
always and assign automatic begin buf bufif0 bufif1 case casex casez cell cmos
config deassign default defparam design disable edge else end endcase endconfig
endfunction endgenerate endmodule endprimitive endspecify endtable endtask event
for force forever fork function generate genvar highz0 highz1 if ifnone incdir
include initial inout input instance integer join large liblist library localparam
macromodule medium module nand negedge nmos nor noshowcancelled not notif0 notif1
or output parameter pmos posedge primitive pull0 pull1 pulldown pullup
pulsestyle_onevent pulsestyle_ondetect rcmos real realtime reg release repeat
rnmos rpmos rtran rtranif0 rtranif1 scalared showcancelled signed small specify
specparam strong0 strong1 supply0 supply1 table task time tran tranif0 tranif1
tri tri0 tri1 triand trior trireg unsigned use uwire vectored wait wand weak0
weak1 while wire wor xnor xor
logic bit int longint shortint byte always_ff always_comb always_latch unique priority
'''.split())

DECL_KW = {'wire', 'reg', 'integer', 'real', 'genvar', 'localparam', 'parameter',
           'input', 'output', 'inout', 'tri', 'tri0', 'tri1', 'wand', 'wor',
           'supply0', 'supply1', 'time', 'realtime', 'logic', 'event', 'trireg'}
NET_KW = {'wire', 'tri', 'tri0', 'tri1', 'wand', 'wor', 'supply0', 'supply1', 'trireg'}
VAR_KW = {'reg', 'integer', 'real', 'time', 'realtime', 'logic'}
TYPE_MODIFIERS = {'signed', 'unsigned', 'scalared', 'vectored', 'wire', 'reg', 'logic',
                  'automatic', 'integer', 'real', 'time'}

TOK_RE = re.compile(r'''
    (?P<ws>\s+)
  | (?P<num>\d[\d_]*\s*'\s*[sS]?[bBoOdDhH]\s*[0-9a-fA-F_xXzZ?]+ | '\s*[sS]?[bBoOdDhH]\s*[0-9a-fA-F_xXzZ?]+ | \d[\d_]*\s*'\s*[sS]?[bBoOdDhH](?=\s*`) | '\s*[sS]?[bBoOdDhH](?=\s*`) | \d[\d_]*\.\d[\d_]*([eE][-+]?\d+)? | \d[\d_]*)
  | (?P<mac>`[A-Za-z_]\w*)
  | (?P<sys>\$[A-Za-z_]\w*)
  | (?P<esc>\\\S+)
  | (?P<id>[A-Za-z_][\w$]*)
  | (?P<op>\(\*|\*\)|[-+*/%&|^~!<>=?:;,.#@(){}\[\]]|\S)
''', re.X)


class Tok:
    __slots__ = ('kind', 'text', 'line', 'pos', 'end')

    def __init__(self, kind, text, line, pos, end):
        self.kind, self.text, self.line, self.pos, self.end = kind, text, line, pos, end

    def __repr__(self):
        return f'{self.kind}:{self.text}@{self.line}'


def strip_comments(src):
    """Blank comments/strings in place (keep newlines so offsets and lines hold)."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            seg = src[i:j]
            out.append(re.sub(r'[^\n]', ' ', seg)); i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            j = min(j + 1, n)
            out.append('""' + ' ' * (j - i - 2)); i = j
        else:
            out.append(c); i += 1
    return ''.join(out)


def strip_preproc(src):
    """Blank `define/`include/`timescale/`default_nettype lines (incl. continuations)
    and the conditional directives themselves; the code in every branch stays."""
    lines = src.split('\n')
    out = []
    cont = False
    for ln in lines:
        s = ln.lstrip()
        if cont:
            out.append(' ' * len(ln)); cont = ln.rstrip().endswith('\\'); continue
        if s.startswith('`') and re.match(r'`(define|undef|include|timescale|default_nettype|resetall|ifdef|ifndef|elsif|else|endif|line)\b', s):
            out.append(' ' * len(ln))
            cont = s.startswith('`define') and ln.rstrip().endswith('\\')
        else:
            out.append(ln)
    return '\n'.join(out)


def tokenize(src):
    toks = []
    line = 1
    in_attr = False
    for m in TOK_RE.finditer(src):
        kind = m.lastgroup
        text = m.group()
        if kind == 'ws':
            line += text.count('\n'); continue
        if kind == 'op' and text == '(*':
            if src[m.end():m.end() + 1] == ')':          # always @(*) -- not an attribute
                toks.append(Tok('op', '(', line, m.start(), m.start() + 1))
                toks.append(Tok('op', '*', line, m.start() + 1, m.end()))
                continue
            in_attr = True
        if not in_attr:
            toks.append(Tok(kind, text, line, m.start(), m.end()))
        if kind == 'op' and text == '*)':
            in_attr = False
        line += text.count('\n')
    return toks


def match_close(toks, i, open_t, close_t):
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind == 'op':
            if t.text == open_t: depth += 1
            elif t.text == close_t:
                depth -= 1
                if depth == 0: return j
    return len(toks) - 1


def stmt_end(toks, i):
    """Index of the ';' ending the statement starting at i (skips ( ) and [ ])."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind != 'op': continue
        if t.text in '([{': depth += 1
        elif t.text in ')]}': depth -= 1
        elif t.text == ';' and depth == 0: return j
    return len(toks) - 1


def split_top_commas(toks, i, j):
    """Split toks[i:j] on top-level commas -> list of (start, end) index ranges."""
    parts, depth, s = [], 0, i
    for k in range(i, j):
        t = toks[k]
        if t.kind == 'op':
            if t.text in '([{': depth += 1
            elif t.text in ')]}': depth -= 1
            elif t.text == ',' and depth == 0:
                parts.append((s, k)); s = k + 1
    parts.append((s, j))
    return parts


def parse_declarators(toks, i, j, first=True):
    """toks[i:j] is one declarator group; returns list of dicts
    {name, name_idx, init:(start,end)|None, dims:(start,end)|None} in order."""
    out = []
    for (s, e) in split_top_commas(toks, i, j):
        k = s
        # skip type modifiers and ranges at the start of the first declarator
        while k < e and ((toks[k].kind == 'id' and toks[k].text in TYPE_MODIFIERS) or
                         (toks[k].kind == 'op' and toks[k].text == '[')):
            if toks[k].kind == 'op':
                k = match_close(toks, k, '[', ']') + 1
            else:
                k += 1
        if k >= e or toks[k].kind not in ('id', 'esc'):
            continue
        name_idx = k
        k += 1
        dims = None
        while k < e and toks[k].kind == 'op' and toks[k].text == '[':
            d0 = k; k = match_close(toks, k, '[', ']') + 1
            dims = (d0, k)
        init = None
        if k < e and toks[k].kind == 'op' and toks[k].text == '=':
            init = (k + 1, e)
        out.append({'name': toks[name_idx].text, 'name_idx': name_idx, 'init': init,
                    'dims': dims, 'start': s, 'end': e})
    return out


class Module:
    def __init__(self, name, line):
        self.name = name
        self.line = line
        self.decls = {}        # name -> [(line, kind, stmt_start_idx, stmt_end_idx, declarator)]
        self.funcs = {}        # name -> line
        self.instances = set()
        self.labels = set()
        self.uses = []         # (name, line, tok_idx, item_start_idx, depth, scope)
        self.decl_inits = []   # dicts
        self.items = []        # (start_idx, end_idx, depth) module-level items


HEADER_FUNCS = None


def header_funcs():
    global HEADER_FUNCS
    if HEADER_FUNCS is None:
        HEADER_FUNCS = set()
        for h in (ROOT / 'rtl').glob('*.vh'):
            for m in re.finditer(r'^\s*(?:function|task)\b[^;(]*?([A-Za-z_]\w*)\s*[;(]',
                                 h.read_text(errors='replace'), re.M):
                HEADER_FUNCS.add(m.group(1))
    return HEADER_FUNCS


def lint_file(path, want_positions=False):
    raw = Path(path).read_text(errors='replace')
    return lint_file_text(raw, path, want_positions)


def lint_file_text(raw, path, want_positions=True):
    src = strip_preproc(strip_comments(raw))
    toks = tokenize(src)
    modules = []
    mod = None
    i = 0
    n = len(toks)
    scope_stack = []       # function/task local scopes: dict name->line
    fn_stack = []          # names of functions being parsed
    depth = 0              # generate/named-block nesting (module body = 0)
    item_stack = []        # start idx of enclosing items per depth
    cur_item = None        # current module-level item start idx

    def declare(name, line, kind, s, e, declr=None, local=False):
        if local and scope_stack:
            scope_stack[-1].setdefault(name, line)
            return
        mod.decls.setdefault(name, []).append((line, kind, s, e, declr))

    def use(name, line, idx):
        mod.uses.append((name, line, idx, cur_item, depth, scope_stack[-1] if scope_stack else None))

    def handle_decl_stmt(s, e, kind, header=False):
        """Declaration statement toks[s:e] (e = ';' index). Registers names,
        records uses inside ranges/initialisers, collects decl-inits."""
        # parameter list inside #( ... ) handled by caller via header=True
        groups = parse_declarators(toks, s + 1, e)
        # 'output reg' / 'input wire' etc: parse_declarators skips modifiers
        for d in groups:
            declare(d['name'], toks[d['name_idx']].line, kind, s, e, d,
                    local=bool(fn_stack))
            if d['init'] is not None and kind not in ('localparam', 'parameter'):
                mod.decl_inits.append({'name': d['name'], 'kind': kind,
                                       'line': toks[d['name_idx']].line,
                                       'stmt': (s, e), 'declr': d,
                                       'in_function': bool(fn_stack)})
        # uses inside the statement: everything except declarator names
        names_idx = {d['name_idx'] for d in groups}
        for k in range(s + 1, e):
            t = toks[k]
            if t.kind == 'id' and k not in names_idx and t.text not in KEYWORDS \
               and not (toks[k - 1].kind == 'op' and toks[k - 1].text == '.'):
                use(t.text, t.line, k)

    while i < n:
        t = toks[i]
        if t.kind == 'id' and t.text in ('module', 'macromodule'):
            mod = Module(toks[i + 1].text, toks[i + 1].line)
            modules.append(mod)
            scope_stack, fn_stack, depth, item_stack, cur_item = [], [], 0, [], None
            j = i + 2
            # parameter port list
            if toks[j].kind == 'op' and toks[j].text == '#':
                pe = match_close(toks, j + 1, '(', ')')
                for (s, e) in split_top_commas(toks, j + 2, pe):
                    # parameter [type] NAME = expr
                    k = s
                    if toks[k].kind == 'id' and toks[k].text in ('parameter', 'localparam'):
                        k += 1
                    for d in parse_declarators(toks, k, e):
                        declare(d['name'], toks[d['name_idx']].line, 'parameter', s, e, d)
                j = pe + 1
            if toks[j].kind == 'op' and toks[j].text == '(':
                pe = match_close(toks, j, '(', ')')
                for (s, e) in split_top_commas(toks, j + 1, pe):
                    if s >= e: continue
                    if toks[s].kind == 'id' and toks[s].text in ('input', 'output', 'inout'):
                        handle_decl_stmt(s, e, toks[s].text, header=True)
                    elif toks[s].kind == 'id':
                        declare(toks[s].text, toks[s].line, 'port', s, e)   # non-ANSI list
                j = pe + 1
            i = stmt_end(toks, j) + 1
            continue
        if mod is None:
            i += 1; continue
        if t.kind == 'id' and t.text == 'endmodule':
            mod = None; i += 1; continue

        # ---- function / task -------------------------------------------
        if t.kind == 'id' and t.text in ('function', 'task'):
            k = i + 1
            if toks[k].kind == 'id' and toks[k].text == 'automatic': k += 1
            while toks[k].kind == 'op' and toks[k].text == '[':
                k = match_close(toks, k, '[', ']') + 1
            if toks[k].kind == 'id' and toks[k].text in ('integer', 'real', 'signed', 'time', 'reg'):
                k += 1
                while toks[k].kind == 'op' and toks[k].text == '[':
                    k = match_close(toks, k, '[', ']') + 1
            fname = toks[k].text
            mod.funcs[fname] = toks[k].line
            fn_stack.append(fname); scope_stack.append({fname: toks[k].line})
            if cur_item is None: cur_item = i
            if toks[k + 1].kind == 'op' and toks[k + 1].text == '(':
                pe = match_close(toks, k + 1, '(', ')')
                for (s, e) in split_top_commas(toks, k + 2, pe):
                    if s < e and toks[s].kind == 'id' and toks[s].text in ('input', 'output', 'inout'):
                        for d in parse_declarators(toks, s + 1, e):
                            scope_stack[-1].setdefault(d['name'], toks[d['name_idx']].line)
            i = stmt_end(toks, k) + 1
            continue
        if t.kind == 'id' and t.text in ('endfunction', 'endtask'):
            fn_stack.pop(); scope_stack.pop(); cur_item = None
            i += 1; continue

        # ---- declarations --------------------------------------------------
        if t.kind == 'id' and t.text in DECL_KW and not (
                t.text in ('input', 'output', 'inout') and False):
            e = stmt_end(toks, i)
            if cur_item is None: cur_item = i
            handle_decl_stmt(i, e, t.text)
            mod.items.append((i, e, depth))
            if depth == 0 and not fn_stack: cur_item = None
            i = e + 1
            continue

        # ---- generate / begin-end nesting -----------------------------------
        if t.kind == 'id' and t.text in ('generate', 'endgenerate'):
            i += 1; continue
        if t.kind == 'id' and t.text == 'begin':
            if cur_item is None: cur_item = i
            depth += 1
            if toks[i + 1].kind == 'op' and toks[i + 1].text == ':':
                mod.labels.add(toks[i + 2].text); i += 3
            else:
                i += 1
            continue
        if t.kind == 'id' and t.text == 'end':
            depth -= 1
            i += 1
            if toks[i].kind == 'op' and toks[i].text == ':' and toks[i + 1].kind == 'id':
                i += 2
            if depth == 0 and not fn_stack:
                cur_item = None
            continue

        # ---- module instantiation: IDENT [#(...)] IDENT ( ... ) ; -------------
        prev_t = toks[i - 1] if i > 0 else None
        at_stmt_start = (cur_item is None and depth == 0) or (prev_t is not None and (
            (prev_t.kind == 'op' and prev_t.text == ';') or
            (prev_t.kind == 'id' and prev_t.text in ('begin', 'end', 'generate', 'endgenerate', 'else')) or
            (prev_t.kind == 'id' and i >= 3 and toks[i - 2].kind == 'op' and toks[i - 2].text == ':'
             and toks[i - 3].kind == 'id' and toks[i - 3].text == 'begin') or
            (prev_t.kind == 'op' and prev_t.text == ')' and depth >= 0 and
             toks[[q for q in range(i - 1, -1, -1) if toks[q].kind == 'op' and toks[q].text == '('
                   and match_close(toks, q, '(', ')') == i - 1][0] - 1].text == 'if'
             if any(toks[q].kind == 'op' and toks[q].text == '(' and match_close(toks, q, '(', ')') == i - 1
                    for q in range(i - 1, max(-1, i - 400), -1)) else False)))
        if t.kind == 'id' and t.text not in KEYWORDS and not fn_stack and at_stmt_start:
            k = i + 1
            if toks[k].kind == 'op' and toks[k].text == '#':
                k = match_close(toks, k + 1, '(', ')') + 1
            if toks[k].kind == 'id' and toks[k + 1].kind == 'op' and toks[k + 1].text in ('(', '['):
                # instance
                mod.instances.add(toks[k].text)
                mod.instances.add(t.text)       # module name (may be an elab-error idiom)
                e = stmt_end(toks, i)
                saved_item = cur_item
                if cur_item is None: cur_item = i
                for q in range(i + 1, e):
                    tq = toks[q]
                    if tq.kind == 'id' and tq.text not in KEYWORDS and q != k \
                       and not (toks[q - 1].kind == 'op' and toks[q - 1].text == '.'):
                        use(tq.text, tq.line, q)
                mod.items.append((i, e, depth))
                cur_item = saved_item if depth > 0 else None
                i = e + 1
                continue

        # ---- everything else: statements with uses --------------------------
        if cur_item is None and depth == 0 and not fn_stack and t.kind == 'id' \
           and t.text in ('assign', 'always', 'initial', 'if', 'for', 'case', 'defparam'):
            cur_item = i
        if t.kind == 'id' and t.text not in KEYWORDS:
            prev = toks[i - 1] if i > 0 else None
            nxt = toks[i + 1] if i + 1 < n else None
            if prev is not None and prev.kind == 'op' and prev.text == '.':
                pass                                    # named port / hierarchical member
            elif nxt is not None and nxt.kind == 'op' and nxt.text == ':' and prev is not None \
                    and prev.kind == 'id' and prev.text in ('begin', 'end', 'fork', 'join'):
                pass                                    # block label
            elif prev is not None and prev.kind == 'id' and prev.text == 'disable':
                pass
            else:
                use(t.text, t.line, i)
        if t.kind == 'op' and t.text == ';' and depth == 0 and not fn_stack:
            if cur_item is not None:
                mod.items.append((cur_item, i, depth))
            cur_item = None
        i += 1

    # ---- resolve ----------------------------------------------------------
    findings = []
    for m in modules:
        first_decl = {nm: min(d[0] for d in ds) for nm, ds in m.decls.items()}
        ubd = {}
        undeclared = {}
        for (name, line, idx, item, dp, scope) in m.uses:
            if scope is not None and name in scope:
                if scope[name] > line:
                    ubd.setdefault(name, []).append(line)
                continue
            if name in first_decl:
                if first_decl[name] > line:
                    ubd.setdefault(name, []).append(line)
                continue
            if name in m.funcs or name in m.instances or name in m.labels or name in header_funcs():
                continue
            undeclared.setdefault(name, []).append(line)
        findings.append({
            'file': str(path), 'module': m.name,
            'decl_init': [{'name': d['name'], 'kind': d['kind'], 'line': d['line'],
                           'in_function': d['in_function']} for d in m.decl_inits],
            'use_before_declare': [{'name': nm, 'first_use': min(ls), 'uses': sorted(set(ls)),
                                    'decl_line': first_decl[nm] if nm in first_decl else None}
                                   for nm, ls in sorted(ubd.items(), key=lambda kv: min(kv[1]))],
            'undeclared': {nm: sorted(set(ls))[:5] for nm, ls in sorted(undeclared.items())},
        })
    if want_positions:
        return findings, toks, modules, raw
    return findings


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='*')
    ap.add_argument('--json')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()
    files = a.files or [str(ROOT / p) for p in
                        (ROOT / 'flow/asic/karu64.f').read_text().split()]
    allf = []
    tot = {'decl_init': 0, 'ubd': 0, 'undeclared': 0}
    for f in files:
        for r in lint_file(f):
            allf.append(r)
            di, ub, un = len(r['decl_init']), len(r['use_before_declare']), len(r['undeclared'])
            tot['decl_init'] += di; tot['ubd'] += ub; tot['undeclared'] += un
            if a.quiet or (di == 0 and ub == 0 and un == 0):
                continue
            rel = str(Path(f).resolve().relative_to(ROOT)) if str(f).startswith(str(ROOT)) else f
            print(f'== {rel} : module {r["module"]}  decl-init={di}  use-before-declare={ub}  undeclared={un}')
            for x in r['use_before_declare']:
                print(f'   UBD  {x["name"]:<28} first use L{x["first_use"]:<5} declared L{x["decl_line"]}')
            for nm, ls in r['undeclared'].items():
                print(f'   UNDECL {nm:<26} lines {ls}')
    print(f'TOTAL decl-init={tot["decl_init"]}  use-before-declare={tot["ubd"]}  undeclared={tot["undeclared"]}')
    if a.json:
        Path(a.json).write_text(json.dumps(allf, indent=1))
    return 1 if (tot['decl_init'] or tot['ubd']) else 0


if __name__ == '__main__':
    sys.exit(main())
