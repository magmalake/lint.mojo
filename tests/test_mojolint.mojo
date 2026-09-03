"""Unit tests: the tokenizer, the structure pass, and each rule on a small
inline program. The corpus in `tests/corpus` is the end-to-end check."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mojolint import (
    Facts,
    Finding,
    Pos,
    hover_signature,
    hover_type,
    json_quote,
    lint_source,
    lint_with_facts,
    logical_lines,
    parse_json,
    parse_module,
    parse_params,
    words_of,
)
from mojolint.lsp import split_frames
from mojolint.tokenize import handed_whole


def _ids(findings: List[Finding]) -> String:
    var out = String()
    for f in findings:
        if out.byte_length() > 0:
            out += ","
        out += f.rule
    return out^


# ── tokenizer ────────────────────────────────────────────────────────────────


def test_words_skip_numbers_and_split_on_punctuation() raises:
    var ws = words_of("t.sum = seen + Int64(i) * 20_000 + 0x1F")
    assert_equal(len(ws), 5)  # t sum seen Int64 i — no `20_000`, no `x1F`
    assert_equal(ws[0], "t")
    assert_equal(ws[1], "sum")
    assert_equal(ws[4], "i")


def test_comments_are_stripped_and_strings_blanked() raises:
    var lines = logical_lines(
        "print(\"totals here\", x)  # totals not used\nvar s = 'it # is'\n"
    )
    assert_equal(len(lines), 2)
    assert_equal(lines[0].code, 'print("", x)')
    assert_false(lines[0].has_word("totals"))
    assert_true(lines[0].has_word("x"))
    assert_equal(lines[1].code, 'var s = ""')


def test_docstrings_vanish_and_do_not_break_indentation() raises:
    var src = String(
        'struct S:\n    """A doc.\n\n    More.\n    """\n    var p: Int\n'
    )
    var lines = logical_lines(src)
    assert_equal(len(lines), 2)
    assert_equal(lines[1].lineno, 6)
    assert_equal(lines[1].indent, 4)


def test_bracketed_continuations_join_into_one_line() raises:
    var lines = logical_lines(
        "def main():\n    foo(\n        a,\n        [b, c],\n    )\n    bar()\n"
    )
    assert_equal(len(lines), 3)
    assert_equal(lines[1].lineno, 2)
    assert_equal(lines[1].code, "foo( a, [b, c], )")
    assert_equal(lines[2].lineno, 6)
    # Offsets into the joined code map back to the physical line they sit on.
    var foo = lines[1].locate(lines[1].code.find("foo"))
    assert_equal(foo[0], 2)
    assert_equal(foo[1], 5)
    var c = lines[1].locate(lines[1].code.find("c]"))
    assert_equal(c[0], 4)
    assert_equal(c[1], 13)


def test_allow_comment_on_line_and_on_previous_line() raises:
    var lines = logical_lines(
        "x = 1  # lint: allow(L001, L003)\n# lint: allow(L002)\ny = 2\nz = 3\n"
    )
    assert_true(lines[0].allows("L001"))
    assert_true(lines[0].allows("L003"))
    assert_false(lines[0].allows("L002"))
    assert_true(lines[1].allows("L002"))
    assert_false(lines[2].allows("L002"))


# ── structure ────────────────────────────────────────────────────────────────


def test_params_with_conventions_origins_and_defaults() raises:
    var ps = parse_params(
        "def parallel_for[T: AnyType, origin: MutOrigin, //, task: TaskFn[T]]"
        "(n_tasks: Int, ref[origin] state: T, num_workers: Int = 0) raises:"
    )
    assert_equal(len(ps), 3)
    assert_equal(ps[0].conv, "read")
    assert_equal(ps[0].type, "Int")
    assert_equal(ps[1].conv, "ref")
    assert_equal(ps[1].name, "state")
    assert_equal(ps[2].type, "Int")


def test_methods_know_their_struct_and_deinit_is_seen() raises:
    var lines = logical_lines(
        "struct T(Movable):\n"
        "    var cell: Pointer[Int64, MutUntrackedOrigin]\n"
        "    def __deinit__(deinit self):\n"
        "        pass\n"
        "def free():\n"
        "    pass\n"
    )
    var m = parse_module(lines)
    assert_equal(len(m.structs), 1)
    assert_true(m.structs[0].has_deinit)
    assert_equal(m.structs[0].fields[0].name, "cell")
    assert_equal(len(m.funcs), 2)
    assert_equal(m.funcs[0].owner, "T")
    assert_equal(m.funcs[1].owner, "")


# ── rules ────────────────────────────────────────────────────────────────────


def test_l001_fires_on_dying_local_and_on_returned_address() raises:
    var src = String(
        "def to(ref state: T) -> Self:\n    return Self(Pointer[T,"
        " MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=state))))\ndef"
        " main() raises:\n    var totals = Totals()\n    var ptr ="
        " opaque_ptr(Int(Pointer(to=totals)))\n    parallel_for[task](1000,"
        " ptr)\n"
    )
    var f = lint_source("x.mojo", src)
    assert_equal(_ids(f), "L001,L001")
    assert_equal(f[0].line, 2)
    assert_equal(f[1].line, 5)


def test_l001_is_silent_when_the_local_is_used_after_or_passed_by_ref() raises:
    var src = String(
        "def main() raises:\n"
        "    var totals = Totals()\n"
        "    var ptr = opaque_ptr(Int(Pointer(to=totals)))\n"
        "    parallel_for[task](1000, ptr)\n"
        "    print(totals.sum)\n"
        "def typed(n: Int, ref[origin] state: T) raises:\n"
        "    parallel_for[w](n, opaque_ptr(Int(Pointer(to=state))))\n"
    )
    assert_equal(_ids(lint_source("x.mojo", src)), "")


def test_l001_respects_allow() raises:
    var src = String(
        "def main() raises:\n    var totals = Totals()\n    var ptr ="
        " opaque_ptr(Int(Pointer(to=totals)))  # lint: allow(L001)\n   "
        " parallel_for[task](1000, ptr)\n"
    )
    assert_equal(_ids(lint_source("x.mojo", src)), "")


def test_l002_fires_on_field_copy_deref_outside_methods_only() raises:
    var src = String(
        "struct Totals(Movable):\n"
        "    var cell: Pointer[Int64, MutUntrackedOrigin]\n"
        "    def sum(self) -> Int64:\n"
        "        return self.cell[]\n"
        "    def __deinit__(deinit self):\n"
        "        self.cell[] = -1\n"
        "struct Owned(Movable):\n"
        "    var cell: OwnedPointer[Int64]\n"
        "    def __deinit__(deinit self):\n"
        "        pass\n"
        "def main() raises:\n"
        "    var totals = Totals()\n"
        "    var owned = Owned()\n"
        "    print(totals.sum(), totals.cell[], owned.cell[])\n"
    )
    var f = lint_source("x.mojo", src)
    assert_equal(_ids(f), "L002")
    assert_equal(f[0].line, 14)


def test_l002_needs_a_destructor() raises:
    var src = String(
        "struct View(Copyable):\n"
        "    var cell: Pointer[Int64, MutUntrackedOrigin]\n"
        "def main() raises:\n"
        "    var v = View()\n"
        "    print(v.cell[])\n"
    )
    assert_equal(_ids(lint_source("x.mojo", src)), "")


def test_l003_fires_on_plain_store_not_on_atomic_or_own_slot() raises:
    var src = String(
        "def racy(i: Int, mut t: Totals) -> None:\n"
        "    var seen = t.sum\n"
        "    t.sum = seen + Int64(i)\n"
        "def racy_aug(i: Int, mut t: Totals) -> None:\n"
        "    t.sum += Int64(i)\n"
        "def opaque(i: Int, ptr: OpaquePtr) -> None:\n"
        "    var t = Ctx[Totals].of(ptr)\n"
        "    t[].sum = 0\n"
        "def atomic(i: Int, mut t: Totals) -> None:\n"
        "    _ = counter(t.sum).fetch_add(Int64(i))\n"
        "def own_slot(i: Int, mut s: Slots) -> None:\n"
        "    s.cells[i] = Int64(i * i)\n"
        "def not_a_task(mut t: Totals) -> None:\n"
        "    t.sum = 0\n"
        "def compare(i: Int, mut t: Totals) -> None:\n"
        "    if t.sum == 0:\n"
        "        pass\n"
    )
    var f = lint_source("x.mojo", src)
    assert_equal(_ids(f), "L003,L003,L003")
    assert_equal(f[0].line, 3)
    assert_equal(f[1].line, 5)
    assert_equal(f[2].line, 8)


# ── json and lsp framing ─────────────────────────────────────────────────────


def test_json_reads_nested_values_and_escapes() raises:
    var d = parse_json(
        '{"id": 7, "result": {"contents": {"value": "a\\nb \\"q\\" \\u00e9"}},'
        ' "arr": [1, true, null, {"k": []}]}'
    )
    assert_equal(d.int(d.get(0, "id")), 7)
    assert_equal(
        d.string(d.get(d.get(d.get(0, "result"), "contents"), "value")),
        'a\nb "q" é',
    )
    var arr = d.get(0, "arr")
    assert_equal(d.count(arr), 4)
    assert_true(d.is_null(d.at(arr, 2)))
    assert_equal(d.count(d.get(d.at(arr, 3), "k")), 0)
    assert_equal(d.get(0, "missing"), -1)
    assert_equal(d.int(d.get(0, "missing")), -1)
    assert_equal(d.string(d.get(0, "id")), "")


def test_json_quote_round_trips() raises:
    var text = String('def f():\n    return "x\\y"\t# é')
    var d = parse_json(json_quote(text))
    assert_equal(d.string(0), text)


def test_frames_are_split_by_content_length() raises:
    var stream = String(
        'Content-Length: 13\r\n\r\n{"id": 1234}\nContent-Length: 2\r\n\r\n{}'
    )
    var frames = split_frames(stream)
    assert_equal(len(frames), 2)
    assert_equal(frames[0], '{"id": 1234}\n')
    assert_equal(frames[1], "{}")


def test_hover_lines_yield_type_and_signature() raises:
    assert_equal(
        hover_type("(variable) var t: Pointer[Totals, MutUntrackedOrigin]"),
        "Pointer[Totals, MutUntrackedOrigin]",
    )
    assert_equal(hover_type("(argument) mut t: Totals"), "Totals")
    assert_equal(hover_type("(function) def f()"), "")
    assert_equal(
        hover_signature("(function) def task(i: Int, mut t: Totals)"),
        "def task(i: Int, mut t: Totals)",
    )
    assert_equal(hover_signature("(variable) var x: Int"), "")


# ── rules with facts ─────────────────────────────────────────────────────────


def test_l001_with_facts_catches_erasure_through_a_helper() raises:
    var src = String(
        "struct Ctx[T: AnyType]:\n"
        "    var _ptr: Pointer[Self.T, MutUntrackedOrigin]\n"
        "def main() raises:\n"
        "    var totals = Totals()\n"
        "    var ctx = Ctx[Totals].to(totals).opaque()\n"
        "    parallel_for[task](1000, ctx)\n"
    )
    # Logical line 2 (index) is `def main`; its locals are keyed by that.
    var facts = Facts()
    facts.available = True
    facts.local_types["2:totals"] = "Totals"
    facts.local_types["2:ctx"] = "OpaquePtr"
    facts.local_uses["2:totals"] = [Pos(4, 8), Pos(5, 29)]
    facts.local_uses["2:ctx"] = [Pos(5, 8), Pos(6, 29)]
    var f = lint_with_facts("x.mojo", src, facts)
    assert_equal(_ids(f), "L001")
    assert_equal(f[0].line, 5)
    assert_true(f[0].message.find("`ctx: OpaquePtr`") >= 0)
    # Text mode cannot see through the helper.
    assert_equal(_ids(lint_source("x.mojo", src)), "")


def test_l001_with_facts_ignores_reads_through_a_pointer() raises:
    # threads.mojo's own worker: `cells` is an aliased untracked pointer
    # (`I64Ptr`, so not trivially typed by name) whose last use *reads a
    # cell* into an OpaquePtr. Nothing is handed over; `cells` dying is
    # meaningless.
    var src = String(
        "def worker(arg: OpaquePtr) -> OpaquePtr:\n"
        "    var cells = i64_ptr(Int(arg))\n"
        "    var n_tasks = Int(cells[unsafe_offset=1])\n"
        "    var user_ctx = opaque_ptr(Int(cells[unsafe_offset=2]))\n"
        "    work(n_tasks, user_ctx)\n"
        "    return arg\n"
    )
    var facts = Facts()
    facts.available = True
    facts.local_types["0:cells"] = "I64Ptr"
    facts.local_uses["0:cells"] = [Pos(2, 8), Pos(3, 22), Pos(4, 34)]
    facts.local_types["0:user_ctx"] = "OpaquePtr"
    facts.local_uses["0:user_ctx"] = [Pos(4, 8), Pos(5, 18)]
    assert_equal(_ids(lint_with_facts("x.mojo", src, facts)), "")
    assert_true(handed_whole("Ctx[Totals].to(totals).opaque()", "totals"))
    assert_true(handed_whole("f(a, totals, b)", "totals"))
    assert_true(handed_whole("totals.as_opaque()", "totals"))
    assert_false(handed_whole("Int(cells[unsafe_offset=2])", "cells"))
    assert_false(handed_whole("print(other.totals)", "totals"))
    assert_false(handed_whole("f(totals_2)", "totals"))


def test_l001_with_facts_trusts_resolved_uses_over_text() raises:
    var src = String(
        "def main() raises:\n"
        "    var totals = Totals()\n"
        "    var ptr = opaque_ptr(Int(Pointer(to=totals)))\n"
        "    parallel_for[task](1000, ptr)\n"
        "    print(other.totals)\n"
    )
    # Text mode: `totals` appears on line 5, so it is "used after". The
    # compiler says line 5 is a different name.
    assert_equal(_ids(lint_source("x.mojo", src)), "")
    var facts = Facts()
    facts.available = True
    facts.local_types["0:totals"] = "Totals"
    facts.local_uses["0:totals"] = [Pos(2, 8), Pos(3, 40)]
    facts.local_types["0:ptr"] = "OpaquePtr"
    facts.local_uses["0:ptr"] = [Pos(3, 8), Pos(4, 29)]
    var f = lint_with_facts("x.mojo", src, facts)
    assert_equal(_ids(f), "L001")
    assert_equal(f[0].line, 3)
    # And a trivially-destroyed local is never worth a warning.
    facts.local_types["0:totals"] = "Int"
    assert_equal(_ids(lint_with_facts("x.mojo", src, facts)), "")


def test_l002_with_facts_needs_the_deref_on_the_last_use() raises:
    var src = String(
        "struct Totals(Movable):\n"
        "    var cell: Pointer[Int64, MutUntrackedOrigin]\n"
        "    def __deinit__(deinit self):\n"
        "        self.cell[] = -1\n"
        "def main() raises:\n"
        "    var totals = make()\n"
        "    print(totals.cell[])\n"
        "    print(totals.cell[])\n"
    )
    # Text mode: no `var totals = Totals(`, so no owner, silent.
    assert_equal(_ids(lint_source("x.mojo", src)), "")
    var facts = Facts()
    facts.available = True
    facts.local_types["4:totals"] = "Totals"
    facts.local_uses["4:totals"] = [Pos(6, 8), Pos(7, 10), Pos(8, 10)]
    facts.field_types["Totals.cell"] = "Pointer[Int64, MutUntrackedOrigin]"
    var f = lint_with_facts("x.mojo", src, facts)
    assert_equal(_ids(f), "L002")
    assert_equal(f[0].line, 8)


def test_l003_with_facts_sees_task_shape_through_aliases() raises:
    var src = String("def task(i: Int, p: Ctx) -> None:\n    p[].sum = 0\n")
    assert_equal(_ids(lint_source("x.mojo", src)), "")
    var facts = Facts()
    facts.available = True
    facts.signatures[
        "0"
    ] = "def task(i: Int, p: Pointer[UInt8, MutUntrackedOrigin])"
    assert_equal(_ids(lint_with_facts("x.mojo", src, facts)), "L003")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
