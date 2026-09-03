"""The rules. Each is one function over a file's logical lines and its
recovered structure, returning `Finding`s. `RULES` is the table the CLI and
the corpus harness read; add an entry and a branch in `run_rule` for L004.
"""

from .structure import (
    Func,
    Module,
    has_local,
    locals_of,
    parse_module,
    used_after,
)
from .tokenize import Line, logical_lines, words_of


@fieldwise_init
struct Finding(Copyable, Movable, Writable):
    var path: String
    var line: Int
    var col: Int
    var rule: String
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            self.path,
            ":",
            self.line,
            ":",
            self.col,
            ": ",
            self.rule,
            " ",
            self.message,
        )


@fieldwise_init
struct Rule(Copyable, Movable):
    var id: String
    var name: String
    var summary: String


def rules() -> List[Rule]:
    """Every rule, in the order they run."""
    var out = List[Rule]()
    out.append(
        Rule(
            "L001",
            "untracked-pointer-from-dying-local",
            (
                "an address is erased to an untracked pointer and the"
                " referent's lifetime is not extended past it"
            ),
        )
    )
    out.append(
        Rule(
            "L002",
            "owning-untracked-field",
            (
                "a struct with a destructor keeps an untracked pointer field"
                " that is dereferenced from outside after a field copy"
            ),
        )
    )
    out.append(
        Rule(
            "L003",
            "plain-store-in-task",
            "a parallel task writes to shared state with a plain store",
        )
    )
    return out^


# ── helpers ──────────────────────────────────────────────────────────────────


def _ident_after(code: String, at: Int) -> String:
    """The identifier starting at byte `at`, or empty."""
    var ws = words_of(String(code[byte=at:]))
    if len(ws) == 0:
        return String()
    var w = ws[0]
    if not String(code[byte=at:]).startswith(w):
        return String()
    return w


def _pointer_to_targets(code: String) -> List[String]:
    """Every `NAME` in a `Pointer(to=NAME)` on the line, bare identifiers only.

    `Pointer(to=x.field)` and `Pointer(to=x[])` are skipped: the referent
    is not a whole binding, and the rules below reason about bindings.
    """
    var out = List[String]()
    var pos = 0
    while True:
        var at = code.find("Pointer(to=", pos)
        if at < 0:
            break
        var start = at + 11
        var name = _ident_after(code, start)
        pos = start
        if name.byte_length() == 0:
            continue
        var after = start + name.byte_length()
        if after < code.byte_length() and code[byte=after] == ")":
            out.append(name)
    return out^


def _erases_to_untracked(code: String) -> Bool:
    """Does the line build an untracked pointer or an opaque pointer?"""
    return (
        code.find("MutUntrackedOrigin") >= 0
        or code.find("OpaquePtr(") >= 0
        or code.find("opaque_ptr(") >= 0
    )


def _assignment_target(code: String) -> String:
    """The text left of a top-level `=` (or `+=` etc.); empty if the line is
    not an assignment. Declarations (`var x = …`) count as not assignments."""
    var b = code.as_bytes()
    var depth = 0
    for i in range(len(b)):
        var c = b[i]
        if c == 40 or c == 91 or c == 123:
            depth += 1
        elif c == 41 or c == 93 or c == 125:
            depth -= 1
        elif c == 61 and depth == 0:  # '='
            if i + 1 < len(b) and b[i + 1] == 61:
                return String()  # `==`
            var prev: UInt8 = 0
            if i > 0:
                prev = b[i - 1]
            if prev == 33 or prev == 60 or prev == 62:  # != <= >=
                return String()
            var end = i
            if (
                prev == 43
                or prev == 45
                or prev == 42
                or prev == 47
                or prev == 37
                or prev == 124
                or prev == 38
                or prev == 94
            ):
                end = i - 1  # augmented assignment
            var target = String(String(code[byte=0:end]).strip())
            var ws = words_of(target)
            if len(ws) > 0 and ws[0] == "var":
                return String()
            return target
    return String()


def _is_field_path(text: String) -> Bool:
    """`a`, `a.b`, `a.b.c` — identifiers and dots, nothing else."""
    if text.byte_length() == 0:
        return False
    for c in text.as_bytes():
        var ok = (
            (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or (c >= 48 and c <= 57)
            or c == 95
            or c == 46
        )
        if not ok:
            return False
    return True


def _col(line: Line, needle: String) -> Int:
    var at = line.code.find(needle)
    return line.indent + 1 + (at if at >= 0 else 0)


# ── L001 ─────────────────────────────────────────────────────────────────────


def check_l001(path: String, lines: List[Line], mod: Module) -> List[Finding]:
    """`Pointer(to=x)` erased to an untracked or opaque pointer, where either

    - the line is a `return`: the untracked pointer leaves the function while
      `x` (a parameter or local) does not; or
    - `x` is a `var` local of this function and is never mentioned again:
      Mojo destroys `x` at that last use, before anything reads the pointer.

    An erased pointer passed as an argument to a call, from a parameter, is
    fine — a parameter is alive for the whole call, joins included — which is
    how the library's own typed `parallel_for` looks, and why it is silent.
    """
    var out = List[Finding]()
    for f in mod.funcs:
        for j in range(f.body_start, f.body_end):
            ref line = lines[j]
            if line.allows("L001"):
                continue
            for name in _pointer_to_targets(line.code):
                var is_local = has_local(lines, f, name)
                var returns = len(line.words) > 0 and line.words[0] == "return"
                if (
                    returns
                    and _erases_to_untracked(line.code)
                    and (is_local or f.is_param(name))
                ):
                    out.append(
                        Finding(
                            path,
                            line.lineno,
                            _col(line, "Pointer(to="),
                            "L001",
                            "the address of `"
                            + name
                            + "` is returned as an untracked"
                            " pointer; nothing extends `"
                            + name
                            + "`'s lifetime to match",
                        )
                    )
                elif (
                    is_local
                    and (
                        _erases_to_untracked(line.code)
                        or line.code.find("Int(Pointer(to=" + name + ")") >= 0
                    )
                    and not used_after(lines, f, j, name)
                ):
                    out.append(
                        Finding(
                            path,
                            line.lineno,
                            _col(line, "Pointer(to="),
                            "L001",
                            "`"
                            + name
                            + "` is erased to an untracked pointer here and"
                            " never used again, so it is destroyed on this"
                            " line — before anything reads the pointer; pass"
                            " it by `ref` instead, or use it after",
                        )
                    )
    return out^


# ── L002 ─────────────────────────────────────────────────────────────────────


def check_l002(path: String, lines: List[Line], mod: Module) -> List[Finding]:
    """A struct with `__deinit__`/`__del__` and an untracked pointer field,
    dereferenced as `local.field[]` from outside its methods.

    `local.field[]` copies the pointer out and, if that is `local`'s last
    use, the destructor runs between the copy and the deref. A method borrows
    the whole struct for the call; so does `OwnedPointer.__getitem__`.
    """
    var out = List[Finding]()
    for s in mod.structs:
        if not s.has_deinit:
            continue
        for fld in s.fields:
            if not (
                fld.type.find("Pointer[") >= 0
                and fld.type.find("MutUntrackedOrigin") >= 0
            ):
                continue
            for f in mod.funcs:
                if f.owner == s.name:
                    continue
                var owners = List[String]()
                for j in range(f.body_start, f.body_end):
                    ref l = lines[j]
                    if (
                        len(l.words) >= 2
                        and l.words[0] == "var"
                        and l.code.find("= " + s.name + "(") >= 0
                    ):
                        owners.append(l.words[1])
                for j in range(f.body_start, f.body_end):
                    ref l = lines[j]
                    if l.allows("L002"):
                        continue
                    for owner in owners:
                        var needle = owner + "." + fld.name + "[]"
                        if l.code.find(needle) >= 0:
                            out.append(
                                Finding(
                                    path,
                                    l.lineno,
                                    _col(l, needle),
                                    "L002",
                                    "`"
                                    + needle
                                    + "` copies the untracked pointer out of `"
                                    + s.name
                                    + "` and dereferences it after `"
                                    + owner
                                    + "`'s last use; read it through a method,"
                                    " or hold it in an `OwnedPointer`",
                                )
                            )
    return out^


# ── L003 ─────────────────────────────────────────────────────────────────────


def _task_shape(f: Func) -> String:
    """`typed` for `(i: Int, mut t: T)`, `opaque` for `(i: Int, p: OpaquePtr)`,
    empty otherwise."""
    if len(f.params) != 2 or f.params[0].type != "Int":
        return String()
    if f.params[1].conv == "mut":
        return String("typed")
    if f.params[1].type == "OpaquePtr":
        return String("opaque")
    return String()


def check_l003(path: String, lines: List[Line], mod: Module) -> List[Finding]:
    """A plain store to shared state inside a task-shaped function.

    Fires on `t.field = …` (typed shape) and `p[].field = …` (any shape). A
    subscripted target such as `s.cells[i] = …` is taken to be a per-task
    slot and left alone; atomics never appear on the left of `=`.
    """
    var out = List[Finding]()
    for f in mod.funcs:
        var shape = _task_shape(f)
        if shape.byte_length() == 0:
            continue
        var state = f.params[1].name
        for j in range(f.body_start, f.body_end):
            ref l = lines[j]
            if l.allows("L003"):
                continue
            var target = _assignment_target(l.code)
            if target.byte_length() == 0:
                continue
            var prefix = state + "."
            var deref = target.find("[].")
            var cut = -1
            if shape == "typed" and target.startswith(prefix):
                cut = prefix.byte_length()
            elif deref >= 0:
                cut = deref + 3
            if cut < 0:
                continue
            var rest = String(target[byte=cut:])
            var field = String(rest.removesuffix("[]"))
            if _is_field_path(field):
                out.append(
                    Finding(
                        path,
                        l.lineno,
                        _col(l, target),
                        "L003",
                        "plain store to `"
                        + target
                        + "` from a task that runs on several threads at once;"
                        " use an atomic, a mutex, or a slot only this task"
                        " writes",
                    )
                )
    return out^


# ── entry point ──────────────────────────────────────────────────────────────


def run_rule(
    id: String, path: String, lines: List[Line], mod: Module
) -> List[Finding]:
    if id == "L001":
        return check_l001(path, lines, mod)
    if id == "L002":
        return check_l002(path, lines, mod)
    if id == "L003":
        return check_l003(path, lines, mod)
    return List[Finding]()


def lint_source(path: String, source: String) -> List[Finding]:
    """Every finding for one file, sorted by line."""
    var lines = logical_lines(source)
    var mod = parse_module(lines)
    var out = List[Finding]()
    for r in rules():
        for fnd in run_rule(r.id, path, lines, mod):
            # Insertion by line keeps the output readable without a sort.
            var k = len(out)
            out.append(fnd.copy())
            while k > 0 and out[k - 1].line > out[k].line:
                var tmp = out[k - 1].copy()
                out[k - 1] = out[k].copy()
                out[k] = tmp^
                k -= 1
    return out^
