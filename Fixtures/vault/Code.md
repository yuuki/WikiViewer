# Code

Inline `[[not a link]]` and `#nottag`.

```swift
let x = "[[also not a link]]" // #notatag
```

%% hidden comment with [[Hidden Link]] %%

Real link after code: [[Home]]

A Mermaid flowchart is drawn natively:

```mermaid
flowchart TB
    vault[(Vault)] -->|read only| indexer[["wikiindex"]]
    indexer --> snapshot["Snapshot<br>SQLite"]
    subgraph phone["iPhone"]
        direction LR
        verify{Verified?} -- yes --> show(["Show note"])
    end
    snapshot -.-> verify
    verify -- no --> keep["前の世代を使う"]
```
