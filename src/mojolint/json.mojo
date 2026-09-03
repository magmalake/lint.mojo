"""A small JSON reader and writer — enough for JSON-RPC.

Parsed documents are arenas: every value is a `JsonNode` in `JsonDoc.nodes`,
children are indices, and the root is node 0. That keeps the type flat (no
recursive struct) and makes lookups cheap: `doc.get(node, "key")`,
`doc.at(node, i)`, `doc.string(node)`, `doc.int(node)`. A missing key or a
type mismatch gives `-1` / an empty value rather than raising, so a chain of
lookups over a reply that may not have the shape we hoped for reads straight.
"""

comptime NULL: UInt8 = 0
comptime BOOL: UInt8 = 1
comptime NUMBER: UInt8 = 2
comptime STRING: UInt8 = 3
comptime ARRAY: UInt8 = 4
comptime OBJECT: UInt8 = 5


@fieldwise_init
struct JsonNode(Copyable, Movable):
    var kind: UInt8
    var text: String
    """The decoded string, the number's spelling, or `true`/`false`."""
    var keys: List[String]
    """Object keys, parallel to `children`; empty for arrays."""
    var children: List[Int]
    """Indices of array items or object values, in document order."""


struct JsonDoc(Movable):
    var nodes: List[JsonNode]

    def __init__(out self):
        self.nodes = List[JsonNode]()

    def kind(self, node: Int) -> UInt8:
        if node < 0 or node >= len(self.nodes):
            return NULL
        return self.nodes[node].kind

    def get(self, node: Int, key: String) -> Int:
        """The value of `key` in object `node`, or -1."""
        if self.kind(node) != OBJECT:
            return -1
        ref n = self.nodes[node]
        for i in range(len(n.keys)):
            if n.keys[i] == key:
                return n.children[i]
        return -1

    def at(self, node: Int, index: Int) -> Int:
        """Item `index` of array `node`, or -1."""
        if self.kind(node) != ARRAY:
            return -1
        ref n = self.nodes[node]
        if index < 0 or index >= len(n.children):
            return -1
        return n.children[index]

    def count(self, node: Int) -> Int:
        """Number of items in an array or members in an object; 0 otherwise."""
        var k = self.kind(node)
        if k != ARRAY and k != OBJECT:
            return 0
        return len(self.nodes[node].children)

    def string(self, node: Int) -> String:
        """The text of a string node; empty for anything else."""
        if self.kind(node) != STRING:
            return String()
        return self.nodes[node].text

    def int(self, node: Int, default: Int = -1) -> Int:
        """The value of an integer number node, else `default`."""
        if self.kind(node) != NUMBER:
            return default
        try:
            return Int(self.nodes[node].text)
        except:
            return default

    def is_null(self, node: Int) -> Bool:
        return self.kind(node) == NULL


struct _Parser[origin: Origin[mut=False]]:
    var b: Span[UInt8, Self.origin]
    var i: Int
    var doc: JsonDoc

    def __init__(out self, b: Span[UInt8, Self.origin]):
        self.b = b
        self.i = 0
        self.doc = JsonDoc()

    def _skip_ws(mut self):
        while self.i < len(self.b):
            var c = self.b[self.i]
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.i += 1
            else:
                break

    def _fail(self, what: String) raises:
        raise Error("json: " + what + " at byte " + String(self.i))

    def _expect(mut self, c: UInt8) raises:
        self._skip_ws()
        if self.i >= len(self.b) or self.b[self.i] != c:
            self._fail("expected '" + String(chr(Int(c))) + "'")
        self.i += 1

    def _push(mut self, kind: UInt8, text: String) -> Int:
        self.doc.nodes.append(JsonNode(kind, text, List[String](), List[Int]()))
        return len(self.doc.nodes) - 1

    def _hex4(mut self) raises -> Int:
        if self.i + 4 > len(self.b):
            self._fail("truncated \\u escape")
        var v = 0
        for _ in range(4):
            var c = self.b[self.i]
            var d = 0
            if c >= 48 and c <= 57:
                d = Int(c) - 48
            elif c >= 97 and c <= 102:
                d = Int(c) - 87
            elif c >= 65 and c <= 70:
                d = Int(c) - 55
            else:
                self._fail("bad hex digit")
            v = v * 16 + d
            self.i += 1
        return v

    def _string(mut self) raises -> String:
        """A string literal; `self.i` is on the opening quote."""
        self.i += 1
        var out = String()
        while True:
            if self.i >= len(self.b):
                self._fail("unterminated string")
            var c = self.b[self.i]
            if c == 34:
                self.i += 1
                return out^
            if c == 92:
                self.i += 1
                if self.i >= len(self.b):
                    self._fail("truncated escape")
                var e = self.b[self.i]
                self.i += 1
                if e == 110:
                    out += "\n"
                elif e == 116:
                    out += "\t"
                elif e == 114:
                    out += "\r"
                elif e == 98:
                    out += "\b"
                elif e == 102:
                    out += "\f"
                elif e == 117:
                    var cp = self._hex4()
                    if cp >= 0xD800 and cp < 0xDC00:
                        # A surrogate pair: `😀`.
                        if (
                            self.i + 1 < len(self.b)
                            and self.b[self.i] == 92
                            and self.b[self.i + 1] == 117
                        ):
                            self.i += 2
                            var lo = self._hex4()
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    out += String(Codepoint.from_u32(UInt32(cp)).value())
                else:
                    # `\"`, `\\`, `\/`
                    out += String(chr(Int(e)))
                continue
            # Copy a run of plain bytes at once.
            var j = self.i
            while j < len(self.b) and self.b[j] != 34 and self.b[j] != 92:
                j += 1
            out += String(StringSlice(unsafe_from_utf8=self.b[self.i : j]))
            self.i = j

    def _value(mut self) raises -> Int:
        self._skip_ws()
        if self.i >= len(self.b):
            self._fail("unexpected end")
        var c = self.b[self.i]
        if c == 123:  # {
            var node = self._push(OBJECT, String())
            self.i += 1
            self._skip_ws()
            if self.i < len(self.b) and self.b[self.i] == 125:
                self.i += 1
                return node
            while True:
                self._skip_ws()
                if self.i >= len(self.b) or self.b[self.i] != 34:
                    self._fail("expected key")
                var key = self._string()
                self._expect(58)  # :
                var child = self._value()
                self.doc.nodes[node].keys.append(key^)
                self.doc.nodes[node].children.append(child)
                self._skip_ws()
                if self.i < len(self.b) and self.b[self.i] == 44:
                    self.i += 1
                    continue
                self._expect(125)
                return node
        if c == 91:  # [
            var node = self._push(ARRAY, String())
            self.i += 1
            self._skip_ws()
            if self.i < len(self.b) and self.b[self.i] == 93:
                self.i += 1
                return node
            while True:
                var child = self._value()
                self.doc.nodes[node].children.append(child)
                self._skip_ws()
                if self.i < len(self.b) and self.b[self.i] == 44:
                    self.i += 1
                    continue
                self._expect(93)
                return node
        if c == 34:
            var s = self._string()
            return self._push(STRING, s^)
        if c == 116 and self._word("true"):
            return self._push(BOOL, "true")
        if c == 102 and self._word("false"):
            return self._push(BOOL, "false")
        if c == 110 and self._word("null"):
            return self._push(NULL, String())
        # A number: sign, digits, fraction, exponent.
        var j = self.i
        while j < len(self.b):
            var d = self.b[j]
            var ok = (
                (d >= 48 and d <= 57)
                or d == 45
                or d == 43
                or d == 46
                or d == 101
                or d == 69
            )
            if not ok:
                break
            j += 1
        if j == self.i:
            self._fail("unexpected character")
        var text = String(StringSlice(unsafe_from_utf8=self.b[self.i : j]))
        self.i = j
        return self._push(NUMBER, text^)

    def finish(deinit self) -> JsonDoc:
        return self.doc^

    def _word(mut self, w: StaticString) -> Bool:
        var n = w.byte_length()
        if self.i + n > len(self.b):
            return False
        var wb = w.as_bytes()
        for k in range(n):
            if self.b[self.i + k] != wb[k]:
                return False
        self.i += n
        return True


def parse_json(text: String) raises -> JsonDoc:
    """Parse one JSON value; the root is node 0."""
    var p = _Parser(text.as_bytes())
    _ = p._value()
    p._skip_ws()
    if p.i != len(p.b):
        p._fail("trailing data")
    return p^.finish()


def json_quote(text: String) -> String:
    """`text` as a JSON string literal, quotes included."""
    comptime digits = "0123456789abcdef"
    var out = String('"')
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += "\\u00"
            out += digits[byte=Int(c >> 4)]
            out += digits[byte=Int(c & 15)]
        else:
            # A run of bytes that pass through unchanged, UTF-8 included.
            var j = i
            while j < len(b) and b[j] >= 32 and b[j] != 34 and b[j] != 92:
                j += 1
            out += StringSlice(unsafe_from_utf8=b[i:j])
            i = j
            continue
        i += 1
    out += '"'
    return out^
