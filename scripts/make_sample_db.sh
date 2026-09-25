#!/bin/sh
# Generates WikiViewer/Resources/sample.sqlite from synthetic notes.
# Never reads a real Obsidian vault.
set -eu

cd "$(dirname "$0")/.."
OUT=WikiViewer/Resources/sample.sqlite
NOTE_COUNT=${NOTE_COUNT:-300}

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

sqlite3 "$OUT" <<SQL
PRAGMA journal_mode = DELETE;
PRAGMA user_version = 1;

CREATE TABLE notes (
  id          INTEGER PRIMARY KEY,
  path        TEXT NOT NULL UNIQUE,
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  modified_at INTEGER NOT NULL
);
CREATE INDEX notes_title ON notes(title COLLATE NOCASE);

WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $NOTE_COUNT
),
topics(i, name) AS (
  VALUES (0, 'Algorithms'), (1, 'Books'), (2, 'Cooking'), (3, 'Daily'),
         (4, 'Gardening'), (5, 'Ideas'), (6, 'Meeting'), (7, 'Projects'),
         (8, 'Travel'), (9, '読書メモ')
)
INSERT INTO notes (path, title, body, modified_at)
SELECT
  t.name || '/' || t.name || ' ' || printf('%03d', s.n) || '.md',
  t.name || ' ' || printf('%03d', s.n),
  '# ' || t.name || ' ' || printf('%03d', s.n) || char(10) || char(10)
    || 'Synthetic sample note for WikiViewer.',
  1758800000 + s.n * 3600
FROM seq s
JOIN topics t ON t.i = s.n % 10;

VACUUM;
SQL

echo "Wrote $OUT ($(sqlite3 "$OUT" 'SELECT count(*) FROM notes') notes)"
