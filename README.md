# lint.mojo

[![mojoshelf](https://mojoshelf.org/badge/lint-mojo.svg)](https://mojoshelf.org/tins/lint-mojo) [![mojo nightly](https://mojoshelf.org/badge/lint-mojo/nightly.svg)](https://mojoshelf.org/tins/lint-mojo)

[![CI](https://github.com/magmalake/lint.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/lint.mojo/actions/workflows/ci.yml)

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

A proof of concept: a linter for the origin and threading mistakes the Mojo
compiler accepts and gets wrong — the `uncaught` programs in `threads.example`.
It reads Mojo as text (logical lines, indentation-recovered functions and
structs), does no dataflow, and stays silent on the correct programs next to
those cases. With `--lsp` it asks `mojo-lsp-server` — the compiler's own
frontend — for the facts the text cannot give: resolved types and name-resolved
uses. All Mojo, no C++, no compiler build.

## Install

```sh
pixi shelf add lint-mojo
pixi run mojolint --lsp -I src src tests
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it as a
**pixi git source dependency**: `pixi install` builds the `mojolint`
executable into your environment's `bin/`, next to the `mojo-lsp-server` its
`--lsp` mode runs — so the linter always uses the compiler your project uses.
magmalake tins are not published to a conda channel, so `pixi add lint-mojo`
will not find it.

`mojo-lsp-server` ships in the `mojo` (and `modular`) conda package, not in
`mojo-compiler`; an environment that depends on `mojo-compiler` alone can run
`mojolint` in text mode only. `lint-mojo` itself depends on `mojo`.

As a dependency declaration, or for a nightly consumer:

```toml
# pixi.toml
[dependencies]
lint-mojo = { git = "https://github.com/magmalake/lint.mojo" }
```

`mojolint [--lsp] [-I DIR]... PATH...` prints `path:line:col: L00N message`
and exits 1 on findings. A directory is walked for `.mojo` files (`.pixi`,
`build` and `shelf` skipped). `-I` takes the same source paths as `mojo build`
— `--lsp` needs them to resolve the file's imports.

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

## `--lsp`: the compiler's facts behind the same rules

`mojolint --lsp [-I DIR]... PATH` runs `mojo-lsp-server` once per file (it
ships in the `mojo` conda package, stable and nightly) and feeds three kinds of
fact into the rules:

| fact | LSP request | replaces |
|---|---|---|
| resolved type of every `var` local and struct field | `textDocument/hover` | spelling checks (`MutUntrackedOrigin` in the text); aliases and helpers now count |
| every name-resolved use of a local | `textDocument/references` | "mentioned again" — the same word in another scope, a field name or a `for` variable no longer counts |
| resolved signature of every function | `hover` on the `def` | task shape read from the header text |

What changes per rule:

- **L001** decides "last use" from references, not text, and fires when the
  statement holding that last use binds a value whose *resolved* type is an
  untracked pointer or a struct of this file wrapping one. So
  `var ctx = Ctx[Totals].to(totals).opaque()` is reported at the call site
  (`totals` is handed to `ctx: OpaquePtr`), not just inside the helper — the
  first tier-1 limit above, gone. Locals of trivially-destroyed types (`Int`,
  `Pointer`, `SIMD`, …) never fire.
- **L002** finds owners by type (`var t = make()` counts), reads the field's
  resolved type, and only fires when the `owner.field[]` sits on the owner's
  last use — the actual condition, not every deref.
- **L003** reads the task shape from the resolved signature, so
  `p: Ctx` where `Ctx` is an alias of `OpaquePtr` is a task.

The client (`src/mojolint/lsp.mojo`) is a batch, not a session: the server's
`--mojo-test` mode reads `// -----`-delimited JSON-RPC from stdin, runs
single-threaded, and answers everything before honouring `shutdown`. So
`mojolint` queues `initialize`/`didOpen`/every `hover` and `references` it
wants/`shutdown`, writes the batch to a file, runs the server once with stdin
redirected (`std.subprocess.run`), and parses the `Content-Length`-framed
replies with its own small JSON reader (`src/mojolint/json.mojo`; the std has
none). About half a second per file with `std` loaded. Parse errors in the
file (missing imports, `-I` not given) are reported as a `note:` and the rules
fall back to text for whatever fact is missing.

What `--lsp` still does not give: destruction points. "Last use" is the last
*textual position* the compiler resolves to the name, which is what ASAP
destruction keys on in straight-line code but not across loops and branches
(a use inside a loop body is "before" a use after the loop, textually and in
fact; a use in one branch and an erasure in the other is textual order only).
That, and the diagnostic itself, is what
[modular/modular#7076](https://github.com/modular/modular/issues/7076) asks
the compiler for.

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

Each positive fires exactly its `# lint-expect:` set, in text mode and in
`--lsp` mode; in `--lsp` mode `untracked_ctx_drops_early` additionally reports
the call site. 14/14 corpus and 22/22 unit tests on Mojo 1.0.0 stable and on
nightly.

    pixi run check                      # unit tests + corpus, both modes (nightly); -e stable for 1.0.0
    pixi run lint PATH ...              # path:line:col: L00N message; exit 1 on findings
    pixi run lint-lsp -I DIR PATH ...   # same, with mojo-lsp-server behind the rules
    pixi run fmt                        # nightly only; stable ships no formatter

## Three tiers toward `shelf lint`

**Tier 1 — text, now.** Pattern lints over source text: no compiler
dependency, milliseconds per file, allow-comments as the escape hatch, run by
`shelf lint` or a pre-commit hook. It covers the four known-bad programs and any
that spell the same idioms the same way.

**Tier 2 — `--lsp`, now.** The same rules with the frontend's types and
references, at the cost of `mojo-lsp-server` on `PATH` and ~0.5 s per file.
This is as far as a tool *outside* the compiler can go: the LSP exposes what
the parser resolved, not what `CheckLifetimes.cpp` decided.

**Tier 3 — the compiler.** The compiler is open source
([modular/modular](https://github.com/modular/modular), Apache 2.0 w/ LLVM
exceptions), but its parser is not a library that hands out a syntax tree: it
parses and emits LIT-dialect MLIR in one pass, and expression nodes are
transient. The reusable entry points are `MojoTooling`'s `MojoParserContext`
(`parseFile` → a module of LIT IR with origins and locations) — the same path
`kgen` and the LSP use. A lint pass over that IR is a C++ tool built from the
Bazel tree, and for L001 it is exactly the warning #7076 requests, which
belongs in `CheckLifetimes.cpp` (the pass that already knows every ASAP
destruction point) behind an opt-in flag like the existing
`--diagnose-missing-doc-strings` in
[`DiagnosticOptions.td`](https://github.com/modular/modular/blob/main/Mojo/tools/mojo/Common/DiagnosticOptions.td).
L002 and L003 stay lints: deciding which stores race needs a `Sync`-like
notion the language lacks.
