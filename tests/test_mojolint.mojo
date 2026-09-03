"""Unit tests: the tokenizer, the structure pass, and each rule on a small
inline program. The corpus in `tests/corpus` is the end-to-end check."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mojolint import (
    Finding,
    lint_source,
    logical_lines,
    parse_module,
    parse_params,
    words_of,
)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
