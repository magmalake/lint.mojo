"""`mojolint [--lsp] [-I DIR]... PATH...` — print `path:line:col: L00N message`
per finding, exit 1 if there were any, 2 on a usage or read error.

A `PATH` that is a directory is walked for `.mojo` and `.🔥` files, skipping
`.pixi`, `.git`, `build` and `shelf`. `--lsp` runs `mojo-lsp-server` (from
`PATH`) once per file and lets the rules use resolved types and name-resolved
uses; `-I DIR` is passed through so imports resolve. Parse errors in the file
are reported as a `note:` line and the rules fall back to text where a fact
is missing.
"""

from std.pathlib import Path
from std.sys import argv, exit

from mojolint import Facts, collect_facts, lint_with_facts, rules
from mojolint.structure import parse_module
from mojolint.tokenize import logical_lines


def usage():
    print("usage: mojolint [--lsp] [-I DIR]... PATH ...")
    print("  PATH is a .mojo file or a directory to walk for them")
    print("rules:")
    for r in rules():
        print("  ", r.id, r.name, "—", r.summary)


def _is_mojo_source(name: String) -> Bool:
    return name.endswith(".mojo") or name.endswith(".🔥")


def collect_files(path: String, mut out: List[String]) raises:
    """`path` itself if it is a file, else every Mojo source under it, in
    sorted order, skipping the directories nothing should lint."""
    var p = Path(path)
    if not p.is_dir():
        out.append(path)
        return
    var names = List[String]()
    for entry in p.listdir():
        names.append(String(entry))
    sort(names)
    for name in names:
        if (
            name == ".pixi"
            or name == ".git"
            or name == "build"
            or name == "shelf"
        ):
            continue
        var child = String(p / name)
        if Path(child).is_dir():
            collect_files(child, out)
        elif _is_mojo_source(name):
            out.append(child)


def main() raises:
    var args = argv()
    var use_lsp = False
    var include = List[String]()
    var files = List[String]()
    var k = 1
    while k < len(args):
        var a = String(args[k])
        if a == "--lsp":
            use_lsp = True
        elif a == "-I" and k + 1 < len(args):
            k += 1
            include.append(String(args[k]))
        elif a.startswith("-I"):
            include.append(String(a[byte=2:]))
        elif a.startswith("-"):
            usage()
            exit(2)
        else:
            try:
                collect_files(a, files)
            except e:
                print(a, ": cannot read: ", e)
                exit(2)
        k += 1
    if len(files) == 0:
        usage()
        exit(2)
    var total = 0
    for path in files:
        var source = String()
        try:
            source = Path(path).read_text()
        except e:
            print(path, ": cannot read: ", e)
            exit(2)
        var facts = Facts()
        if use_lsp:
            var lines = logical_lines(source)
            var mod = parse_module(lines)
            try:
                facts = collect_facts(path, source, lines, mod, include)
            except e:
                print(
                    "note: ",
                    path,
                    ": mojo-lsp-server failed (",
                    e,
                    "); text-only",
                )
            if facts.errors > 0:
                print(
                    "note: ",
                    path,
                    ": mojo-lsp-server reported ",
                    facts.errors,
                    " parse errors; some types may be unresolved",
                )
        for f in lint_with_facts(path, source, facts):
            print(f)
            total += 1
    if total > 0:
        exit(1)
