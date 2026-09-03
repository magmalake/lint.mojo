"""What the compiler knows and the text does not, fetched in one LSP batch.

For every function: its resolved signature. For every `var` local: its
resolved type and every name-resolved use. For every struct field: its
resolved type. That is the whole of what the rules ask the compiler for, and
it is enough to replace the three textual guesses in tier 1 — "mentioned
again" (references), "spelled `MutUntrackedOrigin`" (types, so aliases and
helpers count), and "built as `var x = S(`" (types again).

`Facts()` with no arguments is the empty set; every lookup then comes back
empty and the rules fall back to their textual form.
"""

from std.collections import Dict

from .lsp import LspBatch, Pos, hover_signature, hover_type
from .structure import Func, Module, Struct
from .tokenize import Line


struct Facts(Movable):
    var available: Bool
    var errors: Int
    """Parse errors the server reported: types may be missing when > 0."""
    var local_types: Dict[String, String]
    var local_uses: Dict[String, List[Pos]]
    """Every reference to a local, declaration first, sorted."""
    var field_types: Dict[String, String]
    var signatures: Dict[String, String]

    def __init__(out self):
        self.available = False
        self.errors = 0
        self.local_types = Dict[String, String]()
        self.local_uses = Dict[String, List[Pos]]()
        self.field_types = Dict[String, String]()
        self.signatures = Dict[String, String]()

    @staticmethod
    def _local_key(f: Func, name: String) -> String:
        return String(f.header) + ":" + name

    def local_type(self, f: Func, name: String) -> String:
        """The resolved type of local `name` in `f`; empty if unknown."""
        return self.local_types.get(Self._local_key(f, name), String())

    def last_use(self, f: Func, name: String) -> Optional[Pos]:
        """The last reference to local `name` after its declaration."""
        var uses = self.local_uses.get(Self._local_key(f, name))
        if not uses or len(uses.value()) < 2:
            return None
        return uses.value()[len(uses.value()) - 1]

    def field_type(self, s: Struct, field: String) -> String:
        return self.field_types.get(s.name + "." + field, String())

    def signature(self, f: Func) -> String:
        """`def f(...)` with every type resolved; empty if unknown."""
        return self.signatures.get(String(f.header), String())


def _decl_pos(line: Line) -> Pos:
    """Where the name after `var ` / `def ` sits on the first physical line."""
    return Pos(line.lineno, line.indent + 4)


def collect_facts(
    path: String,
    source: String,
    lines: List[Line],
    mod: Module,
    include: List[String],
) raises -> Facts:
    """Ask the server about every function, local and field in `mod`."""
    var batch = LspBatch(path, source)
    var sig_ids = List[Int]()
    var local_keys = List[String]()
    var local_hover = List[Int]()
    var local_refs = List[Int]()
    var field_keys = List[String]()
    var field_ids = List[Int]()
    for f in mod.funcs:
        sig_ids.append(batch.hover(_decl_pos(lines[f.header])))
        for j in range(f.body_start, f.body_end):
            ref l = lines[j]
            if len(l.words) >= 2 and l.words[0] == "var":
                var at = _decl_pos(l)
                local_keys.append(Facts._local_key(f, l.words[1]))
                local_hover.append(batch.hover(at))
                local_refs.append(batch.references(at))
    for s in mod.structs:
        # Fields sit at the members' indent; a `var` deeper in is a local.
        var member_indent = -1
        for j in range(s.header + 1, s.body_end):
            ref l = lines[j]
            if member_indent < 0:
                member_indent = l.indent
            if (
                l.indent == member_indent
                and len(l.words) >= 2
                and l.words[0] == "var"
                and s.field(l.words[1])
            ):
                field_keys.append(s.name + "." + l.words[1])
                field_ids.append(batch.hover(_decl_pos(l)))
    var replies = batch.run(include)
    var facts = Facts()
    facts.available = True
    facts.errors = replies.errors
    for k in range(len(mod.funcs)):
        facts.signatures[String(mod.funcs[k].header)] = hover_signature(
            replies.hover_text(sig_ids[k])
        )
    for k in range(len(local_keys)):
        facts.local_types[local_keys[k]] = hover_type(
            replies.hover_text(local_hover[k])
        )
        facts.local_uses[local_keys[k]] = replies.positions(local_refs[k])
    for k in range(len(field_keys)):
        facts.field_types[field_keys[k]] = hover_type(
            replies.hover_text(field_ids[k])
        )
    return facts^
