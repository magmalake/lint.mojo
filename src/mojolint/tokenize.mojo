"""Logical lines: Mojo source with comments removed, string contents blanked,
and bracketed continuations joined.

This is all the "parsing" `mojolint` does. A rule sees a `Line` — one
statement or header, its first physical line number, its indent, the code
text, and the identifier words in it — and matches on text. No AST, no
types, no dataflow. That ceiling is deliberate; see the README.
"""


@fieldwise_init
struct Line(Copyable, Movable):
    """One logical line of code."""

    var lineno: Int
    """1-based number of the first physical line."""
    var indent: Int
    """Leading spaces of the first physical line."""
    var code: String
    """The text, comments stripped, every string literal reduced to `""`."""
    var words: List[String]
    """Identifier tokens of `code`, in order."""
    var allow: List[String]
    """Rule ids named in a `# lint: allow(...)` comment on or just above it."""

    def has_word(self, word: String) -> Bool:
        for w in self.words:
            if w == word:
                return True
        return False

    def allows(self, rule: String) -> Bool:
        for a in self.allow:
            if a == rule:
                return True
        return False


def _is_ident_start(c: UInt8) -> Bool:
    return (
        (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
    )  # A-Z a-z _


def _is_ident_char(c: UInt8) -> Bool:
    return _is_ident_start(c) or (c >= 48 and c <= 57)


def words_of(code: String) -> List[String]:
    """The identifier tokens of `code`, in order.

    Numbers are skipped, so `1_000` never becomes a word; string contents are
    already gone by the time this runs.
    """
    var out = List[String]()
    var b = code.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if _is_ident_start(c):
            var j = i
            while j < n and _is_ident_char(b[j]):
                j += 1
            out.append(String(code[byte=i:j]))
            i = j
        elif c >= 48 and c <= 57:
            # A number: consume digits, letters and underscores so `0x1F`
            # and `20_000` do not shed identifier fragments.
            while i < n and _is_ident_char(b[i]):
                i += 1
        else:
            i += 1
    return out^


def _allow_codes(comment: String) -> List[String]:
    """Rule ids in a `lint: allow(L001, L002)` comment; empty otherwise."""
    var out = List[String]()
    var at = comment.find("lint: allow(")
    if at < 0:
        return out^
    var rest = String(comment[byte = at + 12 :])
    var close = rest.find(")")
    if close < 0:
        return out^
    for part in String(rest[byte=0:close]).split(","):
        var id = String(part).strip()
        if id.byte_length() > 0:
            out.append(String(id))
    return out^


@fieldwise_init
struct _Cleaned(Movable):
    var text: String
    """The source, comments removed, string literals reduced to `""`."""
    var allows: List[String]
    """Per physical line: comma-joined `lint: allow` ids from its comment."""


def _blank_strings(text: String) -> _Cleaned:
    """Physical lines with comments removed and strings reduced to `""`.

    Triple-quoted strings can span lines: every line inside one comes back
    empty, and the line that opens it keeps a `""` placeholder.
    """
    var out = String()
    var allows = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var in_str = False
    var triple = False
    var quote: UInt8 = 0
    var line_allow = String()
    while i < n:
        var c = b[i]
        if in_str:
            if c == 10:  # newline inside a triple-quoted string
                out += "\n"
                allows.append(line_allow)
                line_allow = String()
                i += 1
            elif c == 92 and i + 1 < n:  # backslash escape
                i += 2
            elif (
                triple
                and c == quote
                and i + 2 < n
                and b[i + 1] == quote
                and b[i + 2] == quote
            ):
                in_str = False
                out += '"'
                i += 3
            elif not triple and c == quote:
                in_str = False
                out += '"'
                i += 1
            else:
                i += 1
            continue
        if c == 35:  # '#': comment to end of line
            var j = i
            while j < n and b[j] != 10:
                j += 1
            for id in _allow_codes(String(text[byte=i:j])):
                if line_allow.byte_length() > 0:
                    line_allow += ","
                line_allow += id
            i = j
            continue
        if c == 34 or c == 39:  # '"' or '\''
            in_str = True
            quote = c
            triple = i + 2 < n and b[i + 1] == c and b[i + 2] == c
            out += '"'
            i += 3 if triple else 1
            continue
        if c == 10:
            out += "\n"
            allows.append(line_allow)
            line_allow = String()
            i += 1
            continue
        out += String(text[byte = i : i + 1])
        i += 1
    allows.append(line_allow)
    return _Cleaned(out^, allows^)


def _only_quotes(text: String) -> Bool:
    if text.byte_length() == 0:
        return False
    for c in text.as_bytes():
        if c != 34:
            return False
    return True


def logical_lines(source: String) -> List[Line]:
    """Split `source` into logical lines.

    Comments are removed first, then string literals are blanked, then
    physical lines are joined while brackets are open. Blank lines are
    dropped. A `# lint: allow(...)` comment on a line applies to that line;
    on a line of its own it applies to the next code line.
    """
    var cleaned = _blank_strings(source)
    var physical = cleaned.text.split("\n")
    var out = List[Line]()
    var depth = 0
    var code = String()
    var allow = List[String]()
    var pending_allow = List[String]()
    var lineno = 0
    var indent = 0
    var idx = 0
    for raw in physical:
        idx += 1
        var line = String(raw)
        var stripped = String(line.strip())
        # A blanked string literal on a line of its own — a docstring's opener
        # or closer, whose indent is gone — is not code.
        if _only_quotes(stripped):
            stripped = String()
        var line_allow = (
            String(cleaned.allows[idx - 1]) if idx - 1
            < len(cleaned.allows) else String()
        )
        if depth == 0:
            if stripped.byte_length() == 0:
                # A bare allow comment carries over to the next code line.
                for id in line_allow.split(","):
                    if String(id).byte_length() > 0:
                        pending_allow.append(String(id))
                continue
            lineno = idx
            indent = 0
            var lb = line.as_bytes()
            while indent < len(lb) and lb[indent] == 32:
                indent += 1
            code = stripped
            allow = pending_allow^
            pending_allow = List[String]()
        else:
            code += " " + stripped
        for id in line_allow.split(","):
            if String(id).byte_length() > 0:
                allow.append(String(id))
        for ch in stripped.as_bytes():
            if ch == 40 or ch == 91 or ch == 123:  # ( [ {
                depth += 1
            elif ch == 41 or ch == 93 or ch == 125:  # ) ] }
                depth -= 1
        if depth <= 0:
            depth = 0
            out.append(Line(lineno, indent, code, words_of(code), allow^))
            allow = List[String]()
    return out^
