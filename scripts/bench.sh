#!/bin/sh
# Reproducible host benchmarks on synthetic vaults. Never touches a real vault.
#
#   scripts/bench.sh 20000 50000 100000
#
# Writes bench-work/results-<N>.md (bench-work/ is git-ignored). Each run
# regenerates the synthetic vault from a fixed seed so results are comparable.
set -eu
cd "$(dirname "$0")/.."
swift build --package-path Indexer -c release >/dev/null
BIN=Indexer/.build/release/wikiindex
mkdir -p bench-work
for N in "$@"; do
  OUT=bench-work/results-$N.md
  {
    echo "# Synthetic vault: $N notes ($(date -u +%Y-%m-%dT%H:%M:%SZ), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m))"
    echo
    echo '## Generation'
    echo '```'
    "$BIN" synth --out bench-work/vault-$N --notes "$N" --seed 42
    echo '```'
    echo
    echo '## Host indexer / publisher'
    echo
    /usr/bin/time -l "$BIN" bench --vault bench-work/vault-$N --work bench-work/work-$N --updates 1000 2>bench-work/time-$N.txt | grep -v '^\[info\]'
    echo
    echo '```'
    grep -E 'real|maximum resident|peak memory footprint' bench-work/time-$N.txt
    echo '```'
    echo
    echo '## Viewer queries on the host (macOS, same code as the app)'
    echo
    DB=$(ls bench-work/work-$N/publish/generations/viewer-*.sqlite | tail -1)
    "$BIN" bench-queries --db "$DB" --iterations 30 | grep -v '^JSON'
  } > "$OUT" 2>&1
  echo "wrote $OUT"
done
