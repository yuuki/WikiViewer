# Beta

## Goals

1. Ship the viewer
2. Keep memory bounded

## 決定事項

We decided to use SQLite FTS5 with the trigram tokenizer. ^decision-1

Nested tag: #project/beta and see [[Alpha#Details]].

FTS5 ships with SQLite[^fts5], and the trigram tokenizer needs 3.34 or later[^trigram].

[^fts5]: The SQLite documentation
[^trigram]: SQLite 3.34.0 release notes
