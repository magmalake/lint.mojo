"""`mojolint FILE...` — print `path:line:col: L00N message` per finding, exit
1 if there were any, 2 on a usage or read error."""

from std.pathlib import Path
from std.sys import argv, exit

from mojolint import lint_source, rules


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: mojolint FILE.mojo ...")
        print("rules:")
        for r in rules():
            print("  ", r.id, r.name, "—", r.summary)
        exit(2)
    var total = 0
    for k in range(1, len(args)):
        var path = String(args[k])
        var source = String()
        try:
            source = Path(path).read_text()
        except e:
            print(path, ": cannot read: ", e)
            exit(2)
        for f in lint_source(path, source):
            print(f)
            total += 1
    if total > 0:
        exit(1)
