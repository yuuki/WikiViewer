#!/bin/sh
# Rebuilds the demo artifact bundled with the app from Fixtures/vault using
# the real indexer/publisher. Never reads a real Obsidian vault.
# Files are copied over the existing output; if the fixture's images change,
# remove stale blobs under the output's assets/ directory by hand.
set -eu
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wikiviewer-demo.XXXXXX")"
OUT=WikiKit/Sources/WikiViewerKit/Resources/DemoArtifact
swift run --package-path Indexer -c release wikiindex build \
  --vault Fixtures/vault --state "$WORK/state" --publish "$WORK/publish" --force
swift run --package-path Indexer -c release wikiindex verify --publish "$WORK/publish"
mkdir -p "$OUT"
cp "$WORK/publish/manifest.json" "$OUT/"
cp -R "$WORK/publish/generations" "$OUT/"
cp -R "$WORK/publish/assets" "$OUT/"
echo "Wrote $OUT (work files left in $WORK)"
find "$OUT" -type f | sort
