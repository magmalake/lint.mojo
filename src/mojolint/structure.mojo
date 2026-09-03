"""Functions, parameters, structs and fields, recovered from logical lines by
indentation alone.

A `def` header at indent *k* owns every following line with indent > *k*;
the same for `struct`. That is enough to know, for any line, which function
it is in and what that function's parameters and `var` locals are called —
the whole vocabulary the rules use.
"""

from .tokenize import Line, words_of


@fieldwise_init
struct Param(Copyable, Movable):
    var name: String
    var conv: String
    """`read`, `mut`, `ref`, `var`, `out` or `deinit` — `read` when unwritten."""
    var type: String
    """The declared type text, default value removed; empty if untyped."""


@fieldwise_init
struct Func(Copyable, Movable):
    var name: String
    var owner: String
    """The enclosing struct's name, or empty for a free function."""
    var params: List[Param]
    var header: Int
    """Index of the header line in the `List[Line]`."""
    var body_start: Int
    var body_end: Int
    """Exclusive end of the body in the `List[Line]`."""

    def param(self, name: String) -> Optional[Param]:
        for p in self.params:
            if p.name == name:
                return p.copy()
        return None

    def is_param(self, name: String) -> Bool:
        return Bool(self.param(name))


@fieldwise_init
struct Field(Copyable, Movable):
    var name: String
    var type: String


@fieldwise_init
struct Struct(Copyable, Movable):
    var name: String
    var fields: List[Field]
    var has_deinit: Bool
    """Defines `__deinit__` or `__del__`."""
    var header: Int
    var body_end: Int

    def field(self, name: String) -> Optional[Field]:
        for f in self.fields:
            if f.name == name:
                return f.copy()
        return None


def _split_top_level(text: String, sep: UInt8) -> List[String]:
    """Split on `sep` outside any bracket."""
    var out = List[String]()
    var b = text.as_bytes()
    var depth = 0
    var start = 0
    for i in range(len(b)):
        var c = b[i]
        if c == 40 or c == 91 or c == 123:
            depth += 1
        elif c == 41 or c == 93 or c == 125:
            depth -= 1
        elif c == sep and depth == 0:
            out.append(String(text[byte=start:i]))
            start = i + 1
    out.append(String(text[byte=start:]))
    return out^


def _param_list(header: String) -> String:
    """The text between the parentheses of a `def` header.

    Skips the `[...]` compile-time parameter block, if any, by taking the
    first `(` that is not inside brackets.
    """
    var b = header.as_bytes()
    var depth = 0
    var open = -1
    for i in range(len(b)):
        var c = b[i]
        if c == 91:
            depth += 1
        elif c == 93:
            depth -= 1
        elif c == 40 and depth == 0:
            open = i
            break
    if open < 0:
        return String()
    depth = 0
    for i in range(open, len(b)):
        var c = b[i]
        if c == 40:
            depth += 1
        elif c == 41:
            depth -= 1
            if depth == 0:
                return String(header[byte = open + 1 : i])
    return String()


def parse_params(header: String) -> List[Param]:
    """Parameters of a `def` header line, in order."""
    var out = List[Param]()
    for piece_ in _split_top_level(_param_list(header), 44):  # ','
        var piece = String(String(piece_).strip())
        if (
            piece.byte_length() == 0
            or piece == "//"
            or piece == "*"
            or piece == "/"
        ):
            continue
        var decl = piece
        var type = String()
        var colon = _split_top_level(piece, 58)  # ':'
        if len(colon) > 1:
            decl = String(String(colon[0]).strip())
            type = String(String(colon[1]).strip())
            var eq = _split_top_level(type, 61)  # '='
            if len(eq) > 1:
                type = String(String(eq[0]).strip())
        var ws = words_of(decl)
        if len(ws) == 0:
            continue
        var name = ws[len(ws) - 1]
        var conv = String("read")
        if len(ws) > 1:
            conv = ws[0]  # `ref[origin] x` gives ref, origin, x — ws[0] is ref
        out.append(Param(name, conv, type))
    return out^


@fieldwise_init
struct Module(Movable):
    """The functions and structs of one file."""

    var funcs: List[Func]
    var structs: List[Struct]

    def func_at(self, line_index: Int) -> Optional[Func]:
        """The innermost function whose body contains `line_index`."""
        var best: Optional[Func] = None
        for f in self.funcs:
            if line_index >= f.body_start and line_index < f.body_end:
                if not best or f.header > best.value().header:
                    best = f.copy()
        return best^

    def struct_named(self, name: String) -> Optional[Struct]:
        for s in self.structs:
            if s.name == name:
                return s.copy()
        return None


def _block_end(lines: List[Line], header: Int) -> Int:
    """Index one past the last line indented deeper than `lines[header]`."""
    var indent = lines[header].indent
    var i = header + 1
    while i < len(lines) and lines[i].indent > indent:
        i += 1
    return i


def _is_def(line: Line) -> Bool:
    return (
        len(line.words) >= 2
        and line.words[0] == "def"
        and line.code.endswith(":")
    )


def parse_module(lines: List[Line]) -> Module:
    """Recover functions and structs from `lines`."""
    var funcs = List[Func]()
    var structs = List[Struct]()
    for i in range(len(lines)):
        ref line = lines[i]
        if len(line.words) >= 2 and line.words[0] == "struct":
            var end = _block_end(lines, i)
            var fields = List[Field]()
            var has_deinit = False
            var member_indent = -1
            for j in range(i + 1, end):
                ref m = lines[j]
                if member_indent < 0:
                    member_indent = m.indent
                if m.indent != member_indent:
                    continue
                if len(m.words) >= 2 and m.words[0] == "var":
                    var type = String()
                    var colon = m.code.find(":")
                    if colon >= 0:
                        type = String(
                            String(m.code[byte = colon + 1 :]).strip()
                        )
                        var eq = _split_top_level(type, 61)
                        if len(eq) > 1:
                            type = String(String(eq[0]).strip())
                    fields.append(Field(m.words[1], type))
                elif _is_def(m) and (
                    m.words[1] == "__deinit__" or m.words[1] == "__del__"
                ):
                    has_deinit = True
            structs.append(Struct(line.words[1], fields^, has_deinit, i, end))
        elif _is_def(line):
            var end = _block_end(lines, i)
            var owner = String()
            for s in structs:
                if i > s.header and i < s.body_end:
                    owner = s.name
            funcs.append(
                Func(
                    line.words[1], owner, parse_params(line.code), i, i + 1, end
                )
            )
    return Module(funcs^, structs^)


def locals_of(lines: List[Line], f: Func) -> List[String]:
    """Names declared with `var` in `f`'s body, in order of declaration."""
    var out = List[String]()
    for j in range(f.body_start, f.body_end):
        ref l = lines[j]
        if len(l.words) >= 2 and l.words[0] == "var":
            out.append(l.words[1])
    return out^


def has_local(lines: List[Line], f: Func, name: String) -> Bool:
    for l in locals_of(lines, f):
        if l == name:
            return True
    return False


def used_after(
    lines: List[Line], f: Func, line_index: Int, name: String
) -> Bool:
    """Is `name` mentioned on any line of `f` after `line_index`?"""
    for j in range(line_index + 1, f.body_end):
        if lines[j].has_word(name):
            return True
    return False
