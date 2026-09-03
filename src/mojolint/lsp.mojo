"""A batch client for `mojo-lsp-server`.

The server's `--mojo-test` mode reads `// -----`-delimited JSON-RPC messages
from stdin, answers every request before it honours `shutdown`, and runs
single-threaded — a design for scripted use. So the client is a batch: queue
`initialize`, `didOpen`, any number of `hover`/`references` queries, then
`shutdown`/`exit`; write the lot to a file; run the server once with stdin
redirected; parse the `Content-Length`-framed replies and index them by id.
No pipes, no threads, one process per file, well under a second with `std`
loaded.

Positions are LSP positions: 0-based line, 0-based UTF-16 column. The linter
works in bytes and 1-based lines; `Pos` converts at the boundary and the
column difference only matters after a non-ASCII character on the same line.
"""

from std.os import getenv, remove, rmdir
from std.pathlib import Path, cwd
from std.subprocess import run
from std.tempfile import mkdtemp

from .json import JsonDoc, json_quote, parse_json


@fieldwise_init
struct Pos(Equatable, ImplicitlyCopyable, Movable, Writable):
    """A 1-based line and 0-based byte column, as the linter counts."""

    var line: Int
    var col: Int

    def __eq__(self, other: Self) -> Bool:
        return self.line == other.line and self.col == other.col

    def __lt__(self, other: Self) -> Bool:
        return self.line < other.line or (
            self.line == other.line and self.col < other.col
        )

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.line, ":", self.col)


def _file_uri(path: String) -> String:
    var p = path
    if not p.startswith("/"):
        try:
            p = String(cwd() / path)
        except:
            pass
    return "file://" + p


struct LspBatch(Movable):
    """The requests for one document, in order."""

    var uri: String
    var text: String
    var next_id: Int
    var body: String
    """The delimited request stream, without the closing shutdown/exit."""

    def __init__(out self, path: String, source: String):
        self.uri = _file_uri(path)
        self.text = source
        self.next_id = 1
        self.body = String()
        self._notify(
            "initialize",
            (
                '"id": 0, "params": {"processId": null, "rootUri": null,'
                ' "capabilities": {}}'
            ),
        )
        self._notify("initialized", '"params": {}')
        self._notify(
            "textDocument/didOpen",
            '"params": {"textDocument": {"uri": '
            + json_quote(self.uri)
            + ', "languageId": "mojo", "version": 1, "text": '
            + json_quote(self.text)
            + "}}",
        )

    def _notify(mut self, method: String, rest: String):
        self.body += (
            '{"jsonrpc": "2.0", "method": "'
            + method
            + '", '
            + rest
            + "}\n// -----\n"
        )

    def _query(mut self, method: String, at: Pos, extra: String) -> Int:
        var id = self.next_id
        self.next_id += 1
        self._notify(
            method,
            '"id": '
            + String(id)
            + ', "params": {"textDocument": {"uri": '
            + json_quote(self.uri)
            + '}, "position": {"line": '
            + String(at.line - 1)
            + ', "character": '
            + String(at.col)
            + "}"
            + extra
            + "}",
        )
        return id

    def hover(mut self, at: Pos) -> Int:
        """Queue a hover at `at`; returns the request id."""
        return self._query("textDocument/hover", at, String())

    def references(mut self, at: Pos) -> Int:
        """Queue a references query (declaration included) at `at`."""
        return self._query(
            "textDocument/references",
            at,
            ', "context": {"includeDeclaration": true}',
        )

    def run(self, include: List[String]) raises -> LspReplies:
        """Run the server over the queued requests and collect its replies.

        The server is `mojo-lsp-server` on `PATH`, or `$MOJO_LSP_SERVER`."""
        var server = getenv("MOJO_LSP_SERVER", "mojo-lsp-server")
        var stream = self.body
        stream += (
            '{"jsonrpc": "2.0", "id": 999999, "method": "shutdown", "params":'
            " null}\n// -----\n"
        )
        stream += (
            '{"jsonrpc": "2.0", "method": "exit", "params": null}\n// -----\n'
        )
        var dir = mkdtemp(prefix="mojolint-")
        var req = dir + "/requests.jsonrpc"
        Path(req).write_text(stream)
        var cmd = _shell_quote(server) + " --mojo-test --wait-on-shutdown"
        for inc in include:
            cmd += " -I " + _shell_quote(inc)
        cmd += " < " + _shell_quote(req) + " 2>/dev/null"
        var out: String
        try:
            out = run(cmd)
        finally:
            remove(req)
            rmdir(dir)
        var replies = LspReplies(out^)
        if len(replies.docs) == 0:
            raise Error(
                "no reply from `"
                + server
                + "` — is it on PATH (it ships in the `mojo` conda package)?"
            )
        return replies^


def _shell_quote(text: String) -> String:
    return "'" + text.replace("'", "'\\''") + "'"


def split_frames(stream: String) -> List[String]:
    """The bodies of the `Content-Length:`-framed messages in `stream`."""
    var out = List[String]()
    var pos = 0
    while True:
        var at = stream.find("Content-Length:", pos)
        if at < 0:
            break
        var eol = stream.find("\n", at)
        if eol < 0:
            break
        var n: Int
        try:
            n = Int(String(stream[byte = at + 15 : eol]).strip())
        except:
            break
        # Skip the header block: a blank line ends it.
        var body = eol + 1
        while body < stream.byte_length():
            var next_eol = stream.find("\n", body)
            if next_eol < 0:
                next_eol = stream.byte_length()
            var header = String(stream[byte=body:next_eol]).strip()
            body = next_eol + 1
            if header.byte_length() == 0:
                break
        if body + n > stream.byte_length():
            break
        out.append(String(stream[byte = body : body + n]))
        pos = body + n
    return out^


struct LspReplies(Movable):
    """Every message the server sent, parsed, with requests indexed by id."""

    var docs: List[JsonDoc]
    var ids: List[Int]
    """`ids[k]` is the id of `docs[k]`, or -1 for a notification."""
    var errors: Int
    """Diagnostics of severity 1 (error) the server published."""
    var raw: String

    def __init__(out self, var stream: String):
        self.docs = List[JsonDoc]()
        self.ids = List[Int]()
        self.errors = 0
        self.raw = stream^
        for frame in split_frames(self.raw):
            var doc: JsonDoc
            try:
                doc = parse_json(frame)
            except:
                continue
            var id = doc.int(doc.get(0, "id"))
            if (
                doc.string(doc.get(0, "method"))
                == "textDocument/publishDiagnostics"
            ):
                var diags = doc.get(doc.get(0, "params"), "diagnostics")
                for i in range(doc.count(diags)):
                    if doc.int(doc.get(doc.at(diags, i), "severity")) == 1:
                        self.errors += 1
            self.docs.append(doc^)
            self.ids.append(id)

    def _reply(self, id: Int) -> Int:
        for k in range(len(self.ids)):
            if self.ids[k] == id:
                return k
        return -1

    def hover_text(self, id: Int) -> String:
        """The first line of the hover's code block: `(variable) var t: T`,
        `(argument) p: T`, `(field) var cell: T`, `(function) def f(...)`.
        Empty when the server had nothing to say."""
        var k = self._reply(id)
        if k < 0:
            return String()
        ref doc = self.docs[k]
        var value = doc.string(
            doc.get(doc.get(doc.get(0, "result"), "contents"), "value")
        )
        var lines = value.split("\n")
        for l in lines:
            var line = String(String(l).strip())
            if line.byte_length() == 0 or line.startswith("```"):
                continue
            return line
        return String()

    def positions(self, id: Int) -> List[Pos]:
        """The start of every location in a references reply, sorted."""
        var out = List[Pos]()
        var k = self._reply(id)
        if k < 0:
            return out^
        ref doc = self.docs[k]
        var result = doc.get(0, "result")
        for i in range(doc.count(result)):
            var start = doc.get(doc.get(doc.at(result, i), "range"), "start")
            out.append(
                Pos(
                    doc.int(doc.get(start, "line")) + 1,
                    doc.int(doc.get(start, "character")),
                )
            )
        # Insertion sort; a variable has a handful of uses.
        for a in range(1, len(out)):
            var b = a
            while b > 0 and out[b] < out[b - 1]:
                var tmp = out[b - 1]
                out[b - 1] = out[b]
                out[b] = tmp
                b -= 1
        return out^


def hover_type(text: String) -> String:
    """The type in a hover line: everything after the first `: ` of
    `(variable) var t: Pointer[T, MutUntrackedOrigin]`; empty if none."""
    var at = text.find(": ")
    if at < 0:
        return String()
    return String(text[byte = at + 2 :])


def hover_signature(text: String) -> String:
    """The `def ...` of a `(function) def f(...)` hover line; empty if none."""
    var at = text.find("def ")
    if at < 0:
        return String()
    return String(text[byte=at:])
