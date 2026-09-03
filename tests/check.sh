#!/usr/bin/env bash
# The corpus, sorted by what the linter must do with it — run twice, in text
# mode and in `--lsp` mode.
#
#   tests/corpus/positive/*.mojo  must produce findings, and the set of rule
#                                 ids fired must equal the file's
#                                 `# lint-expect:` ids — no more, no fewer.
#   tests/corpus/negative/*.mojo  must produce no findings at all.
#
# The positives are the `uncaught` cases from magmalake/threads.example — the
# programs the compiler accepts and gets wrong. The negatives are the correct
# programs next to them: threads.example's origins.mojo, and threads.mojo's
# parallel.mojo and its tests, which contain the same tokens (`Pointer(to=`,
# `MutUntrackedOrigin`, `mut` task parameters) used correctly.
#
# `--lsp` mode needs `mojo-lsp-server` on PATH and the `threads` package the
# corpus imports: `-I ../threads.mojo/src` when that checkout is there.
set -u
cd "$(dirname "$0")/.."
command -v mojo >/dev/null || { echo "mojo not on PATH — run as: pixi run corpus"; exit 2; }
command -v mojo-lsp-server >/dev/null || { echo "mojo-lsp-server not on PATH — run as: pixi run corpus"; exit 2; }
mkdir -p build
mojo build src/mojolint/main.mojo -I src -o build/mojolint || exit 2
fail=0
pass=0
lsp_flags=(--lsp)
[ -d ../threads.mojo/src ] && lsp_flags+=(-I ../threads.mojo/src)

findings() { # the finding lines only (no `note:` lines)
    grep '^[^:]*:[0-9]*:[0-9]*: L[0-9]* '
}

fired() { # rule ids in the linter's output, one per line, sorted, unique
    "./build/mojolint" "$@" | findings | sed -n 's/^[^:]*:[0-9]*:[0-9]*: \(L[0-9]*\) .*/\1/p' | sort -u
}

for mode in text lsp; do
    flags=()
    [ "$mode" = lsp ] && flags=("${lsp_flags[@]}")
    for f in tests/corpus/positive/*.mojo; do
        name=$(basename "$f" .mojo)
        want=$(sed -n 's/^# lint-expect: //p' "$f" | tr ', ' '\n\n' | grep . | sort -u)
        got=$(fired ${flags[@]+"${flags[@]}"} "$f")
        if [ "$got" = "$want" ]; then
            echo "ok   $mode positive/$name: $(echo $got)"
            pass=$((pass + 1))
        else
            echo "FAIL $mode positive/$name: wanted [$(echo $want)] got [$(echo $got)]"
            ./build/mojolint ${flags[@]+"${flags[@]}"} "$f" | sed 's/^/    /'
            fail=$((fail + 1))
        fi
    done

    for f in tests/corpus/negative/*.mojo; do
        name=$(basename "$f" .mojo)
        out=$(./build/mojolint ${flags[@]+"${flags[@]}"} "$f" | findings)
        if [ -z "$out" ]; then
            echo "ok   $mode negative/$name: silent"
            pass=$((pass + 1))
        else
            echo "FAIL $mode negative/$name: fired"
            echo "$out" | sed 's/^/    /'
            fail=$((fail + 1))
        fi
    done
done

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
