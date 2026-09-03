# lint.mojo

A proof of concept: a source-level linter for the origin and threading mistakes
the Mojo compiler accepts and gets wrong — the `uncaught` programs in
`threads.example`. It reads Mojo as text (logical lines, indentation-recovered
functions and structs), does no dataflow, and stays silent on the correct
programs next to those cases. Local-only; nothing here is published.

## Rules

**L001 untracked-pointer-from-dying-local.** Mojo destroys a value at its last
use, and `Int(Pointer(to=x))`, `MutUntrackedOrigin` and `opaque_ptr` erase the
origin that would have kept `x` alive. A `var` local erased on the line of its
last mention dies there, before anything reads the pointer; an erased address
that is `return`ed outlives its referent. A parameter erased and passed to a
call is fine — it outlives the call — so `parallel_for`'s own `Pointer(to=state)`
is silent. *Limits:* "used again" is textual; erasure inside a helper
(`Ctx.to(totals)`) is caught at the helper, not the call site; only bare
identifiers after `to=`; view types built from the address are not told apart
from raw escapes.

**L002 owning-untracked-field.** A struct with `__deinit__` holding a
`Pointer[T, MutUntrackedOrigin]` field owns the memory without saying so:
`local.field[]` copies the pointer out, and if that is `local`'s last use the
destructor runs between copy and deref. A method borrows the whole struct for
the call, and so does `OwnedPointer.__getitem__` — the suggested fix. *Limits:*
only locals built as `var x = S(` in the same function; a deref through a
second variable or a parameter is missed.

**L003 plain-store-in-task.** A function shaped like a task — `(i: Int, mut t:
T)` or `(i: Int, p: OpaquePtr)` — runs on many threads at once, so a plain store
to its shared state (`t.sum = …`, `t.sum += …`, `p[].sum = …`) is a race;
atomics never appear left of `=`. *Limits:* task shape is judged by signature
only; any subscripted target (`s.cells[i]`) is assumed a per-task slot, so
`s.cells[0] = …` passes; a store hidden in a method call is invisible.

Silence a line with `# lint: allow(L001)` on it or on the line above.

## Corpus

| file (`tests/corpus/`) | source | result |
|---|---|---|
| `positive/untracked_ctx_drops_early.mojo` | threads.example `typed`, uncaught | L001 |
| `positive/opaque_escapes_origin.mojo` | threads.example `typed`, uncaught | L001 |
| `positive/field_deref_after_last_use.mojo` | threads.example `typed`, uncaught | L002 |
| `positive/plain_store_races.mojo` | threads.example `typed`, uncaught | L003 |
| `negative/origins.mojo` | threads.example `typed`, correct | silent |
| `negative/parallel.mojo` | threads.mojo `src/threads/parallel.mojo` | silent |
| `negative/test_threads.mojo` | threads.mojo `tests/test_threads.mojo` | silent |

Each positive fires exactly its `# lint-expect:` set. 7/7 corpus and 13/13 unit
tests on Mojo 1.0.0 stable and on nightly.

    pixi run check                 # unit tests + corpus (nightly); -e stable for 1.0.0
    pixi run lint FILE.mojo ...    # path:line:col: L00N message; exit 1 on findings
    pixi run fmt                   # nightly only; stable ships no formatter

## Two tiers toward `shelf lint`

**Tier 1 — this POC, now.** Pattern lints over source text: no compiler
dependency, milliseconds per file, allow-comments as the escape hatch, run by
`shelf lint` or a pre-commit hook. It covers the four known-bad programs and any
that spell the same idioms the same way. It cannot cover erasure through a
helper or a second variable (L001, L002), view types versus raw escapes (L001),
task shapes not visible in the signature, or stores through methods and shared
subscripts (L003).

**Tier 2 — dataflow lints on the open compiler.** The compiler is open source
([modular/modular](https://github.com/modular/modular), Apache 2.0 w/ LLVM
exceptions). Its diagnostic surface
([`DiagnosticOptions.td`](https://github.com/modular/modular/blob/main/Mojo/tools/mojo/Common/DiagnosticOptions.td))
is `-Werror`/`-Wno-error`, `--disable-warnings`, `--warn-on-unstable-apis`,
`--ignore-deprecated NAME` and an experimental clang-tidy-style fix-it export;
there is no per-warning `-W<name>` family, no diagnostics registry, and no
`lint` subcommand (the [driver](https://github.com/modular/modular/blob/main/Mojo/tools/mojo/mojo.cpp)
registers build, demangle, doc, format, precompile, repl, debug, run). Lifetime
warnings come from
[`CheckLifetimes.cpp`](https://github.com/modular/modular/blob/main/Mojo/lib/LowerLIT/CheckLifetimes.cpp),
which already knows every ASAP-destruction point. Two routes, not exclusive:
upstream a rule as a compiler warning (bringing a `-W` family with it;
contributions open end of 2026), or a lint pass linked against the open frontend
that `shelf lint` runs after tier 1. With real destruction points and origins,
L001 becomes exact (referent destroyed before the pointer's last use, helper or
not), L002 drops the `var x = S(` heuristic (any copy of an untracked field out
of a value with a destructor, dereferenced past its last use), and L003 follows
state through method calls — but deciding which stores race at all needs a
`Sync`-like notion the language lacks, so L003 stays a lint.

Of the three, L001 belongs upstream as a compiler warning: it is nothing but
ASAP destruction meeting an origin-erasing cast, both already visible to
`CheckLifetimes.cpp`.
