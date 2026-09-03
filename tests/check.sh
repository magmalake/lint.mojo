#!/usr/bin/env bash
# The corpus, sorted by what the linter must do with it.
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
set -u
cd "$(dirname "$0")/.."
command -v mojo >/dev/null || { echo "mojo not on PATH — run as: pixi run corpus"; exit 2; }
mkdir -p build
mojo build src/mojolint/main.mojo -I src -o build/mojolint || exit 2
fail=0
pass=0

fired() { # rule ids in the linter's output, one per line, sorted, unique
    "./build/mojolint" "$1" | sed -n 's/^[^:]*:[0-9]*:[0-9]*: \(L[0-9]*\) .*/\1/p' | sort -u
}

for f in tests/corpus/positive/*.mojo; do
    name=$(basename "$f" .mojo)
    want=$(sed -n 's/^# lint-expect: //p' "$f" | tr ', ' '\n\n' | grep . | sort -u)
    got=$(fired "$f")
    if [ "$got" = "$want" ]; then
        echo "ok   positive/$name: $(echo $got)"
        pass=$((pass + 1))
    else
        echo "FAIL positive/$name: wanted [$(echo $want)] got [$(echo $got)]"
        ./build/mojolint "$f" | sed 's/^/    /'
        fail=$((fail + 1))
    fi
done

for f in tests/corpus/negative/*.mojo; do
    name=$(basename "$f" .mojo)
    if out=$(./build/mojolint "$f"); then
        echo "ok   negative/$name: silent"
        pass=$((pass + 1))
    else
        echo "FAIL negative/$name: fired"
        echo "$out" | sed 's/^/    /'
        fail=$((fail + 1))
    fi
done

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
