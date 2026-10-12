# WikiViewer for macOS — 設計案（ドラフト）

iOS 版と同じ公開スナップショットを読む、ネイティブの macOS デスクトップアプリの設計。
確定したら要点を ARCHITECTURE.md / TASKS.md に英語で移す。

## 1. 位置づけ

**何を作るか.** Mac 上の、読み取り専用・オフライン可・高速なボルトビューア。
iPhone 版と同じく `wikiindex` が公開した世代（generation）をダウンロード・検証し、
SQLite に小さなクエリを投げるだけで全画面を描く。編集は引き続き Obsidian Desktop。

**想定する使い方.**

| 場面 | ソース | 価値 |
|---|---|---|
| A. 外出先の MacBook（ボルト本体も Obsidian Sync も無い） | iCloud Drive フォルダ / HTTPS (Tailscale) | 10 万ノートのボルトを、同期も Electron も無しに軽く読める |
| B. Mac mini 本体（Obsidian の隣） | 公開ディレクトリをローカルフォルダとして直接指定 | 巨大ボルトでも即座に開く検索・グラフ（wiki-lens 相当）・Bases 閲覧 |

**非目標（v1）.** 編集、ボルトを直接インデックスする（インデクサをアプリに内蔵する）こと、
Spotlight への全ノート登録、iOS 版に無い機能の先行実装。

**守る不変条件（ARCHITECTURE.md と同じ）.** ボルトに書かない／検証前の DB を開かない／
起動や画面の負荷がノート数に比例しない／更新失敗時も前の世代で読める。
Mac はメモリに余裕があるが、境界付きクエリの原則は崩さない（キャッシュ上限を上げるだけ）。

## 2. 現状の調査結果

- Xcode のアプリターゲットは**既にマルチプラットフォーム**
  （`SDKROOT = auto`, `SUPPORTED_PLATFORMS` に `macosx`, `MACOSX_DEPLOYMENT_TARGET = 27.0`,
  App Sandbox + `ENABLE_USER_SELECTED_FILES = readonly`, Mac 用アイコンもある）。
- `WikiKit`（WikiShared / WikiViewerKit）は `.macOS(.v15)` 対応で、テストは既に macOS ホストで走っている。
  データ層・更新器・トランスポート・検索・描画モデルはそのまま使える。
- `xcodebuild -destination 'platform=macOS'` は現在失敗する
  （`NoteActions.swift` の `import UIKit` で依存解決が止まる）。iOS 専用 API の使用箇所は以下で全部:

| 箇所 | iOS 専用のもの | macOS での置き換え |
|---|---|---|
| `NoteActions.swift`, `NotePreview.swift` | `UIPasteboard` | `Pasteboard` 小ヘルパ（`NSPasteboard`） |
| `WikiViewerApp.swift` | `UIApplication.didReceiveMemoryWarningNotification` | `DispatchSource.makeMemoryPressureSource` |
| `MathRenderer.swift` (`#if canImport(UIKit)`), `BlockView.headingStyle` | `UIFont.TextStyle`, `UITraitCollection` | AppKit 分岐（SwiftMath は macOS 12+ 対応済み。`Package.swift` の `condition: .when(platforms: [.iOS])` に macOS を追加） |
| `NoteView`, `AssetViewer` | `.fullScreenCover` | 別ウインドウ or Quick Look (`.quickLookPreview`) |
| 7 画面 | `.navigationBarTitleDisplayMode` | `inlineNavigationTitle()` ヘルパ（macOS では no-op） |
| `SearchView`, `GraphOverviewView` | `.searchable(placement: .navigationBarDrawer)` | `.toolbar` 配置 |
| `SettingsView` | 共有ブックマーク `options: []` | macOS は `.withSecurityScope` で作成・解決が必須、stale 時は再作成 |
| entitlements | — | HTTP ソースに `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`（sandbox の network.client）が必要 |

つまり「動くだけ」なら小さな修正で済む。設計の本題は**デスクトップらしい操作体系**の方。

## 3. 実装方式の選択

| 方式 | 評価 |
|---|---|
| Designed for iPad（Apple Silicon で iPad 版をそのまま） | 作業ゼロだがタブバー・シート・タッチ前提の UI のまま。不採用 |
| Mac Catalyst | UIKit を経由する意味がない（全画面 SwiftUI）。不採用 |
| **既存のマルチプラットフォームターゲットに macOS ネイティブで載せる** | **採用**。機能ビューを共有し、ウインドウの「殻」だけ OS ごとに持つ |
| macOS 専用ターゲットを別に作る | pbxproj の手編集が増え、ソース共有の設定が二重になる。必要になったら分ける |

## 4. 画面構成

### 4.1 ウインドウ

```
┌──────────────┬─────────────────────┬───────────────────────────────┬──────────────┐
│ Sidebar      │ Content (list)      │ Detail (NavigationStack)      │ Inspector    │
│              │                     │  ◀ ▶  Note title     ⋯  ⓘ   │ (toggle ⌥⌘I) │
│ ⌂ Home       │ Files › Projects ›  │                               │ Outline      │
│ 🔍 Search     │  📁 2024            │  # Heading                    │ Backlinks    │
│ 📁 Files      │  📄 Plan.md    ←選択 │  body …  [[Link]]             │ Properties   │
│ # Tags       │  📄 Notes.md        │                               │ Tags         │
│ ◎ Graph      │  … Show more        │                               │ Local graph  │
│ ── Pinned ── │                     │                               │              │
│ 📌 Today     │                     │                               │              │
└──────────────┴─────────────────────┴───────────────────────────────┴──────────────┘
```

`NavigationSplitView`（3 カラム）+ `.inspector`。iOS 版との対応:

| iOS | macOS |
|---|---|
| TabView の各タブ（Files / Tags / Graph / Search） | サイドバー項目（+ Home、Pinned） |
| 各タブのルート一覧（FolderView, TagsView, SearchView, クラスタ一覧） | Content カラム。フォルダはこのカラム内で潜る（パンくず + 戻る） |
| push された画面（Note, Base, Tag の一覧, Graph クラスタ, Local graph） | Detail カラムの NavigationStack。戻る／進む付き |
| ノート末尾の Backlinks・Properties、Outline シート | Inspector（ノートを読みながら常時見える） |
| Settings シート | `Settings {}` シーン（⌘,） |
| AssetViewer の fullScreenCover | Quick Look パネル（画像のズームも OS 任せ） |

Graph はマップ（バブル／クラスタ図）を Detail に大きく描き、Content にはクラスタ一覧
（iOS で VoiceOver 用に既にある一覧）を出す。

### 4.2 複数ウインドウ・タブ

- `WindowGroup` を値付き（`WindowGroup(for: Route.self)`）にし、ノートを新しいウインドウ／
  ネイティブタブで開ける（⌘クリック = 新規タブ、⌥⌘クリック = 新規ウインドウ）。
- `Library` はプロセスに 1 つ（既存の `SharedLibrary`）。ウインドウごとに持つのはナビゲーション状態だけ。
  ルートは vault パスで表すので、世代切り替えをまたいでも全ウインドウの画面がそのまま有効。
- 各ウインドウのサイドバー選択・Content の状態・Detail の履歴は `@SceneStorage` で復元
  （`Route` は既に `Codable`）。

### 4.3 ナビゲーションの抽象化（共有コードの中心的な変更）

現在の機能ビューは `NavigationLink(value: Route)` と `navigation.push(route)` を直接使っている。
これを環境値 `openRoute`（`OpenRouteAction`）に寄せ、殻ごとに解釈させる:

```swift
enum RouteTarget { case current, newTab, newWindow }
struct OpenRouteAction { let handler: (Route, RouteTarget) -> Void }
// 機能ビュー側: openRoute(.note(path: p, anchor: nil))
```

- iOS: 常に現在のタブの stack に push（今と同じ挙動）。
- macOS: ルートを 2 種に分類して振り分ける。
  - **一覧ルート**（`folder`, `tags`, `search`, `recents`, `graph`）を Content カラムから開いた → Content を置き換え
  - **文書ルート**（`note`, `base`, `tag`, `missing`, `graphCluster`, `localGraph`）→ Detail に navigate
  - 修飾キーで `newTab` / `newWindow`
- `NavigationModel` に forward スタックを持たせ、push で forward を捨て、back で積む
  （ブラウザ型の ⌘[ / ⌘]）。iOS でも害はない。

分類関数と履歴モデルは UI 非依存にして単体テストする。

### 4.4 デスクトップらしい操作

| 機能 | 設計 |
|---|---|
| Quick Open（⌘O） | Spotlight 風のフローティングパレット。既存の検索エンジン（タイトル・エイリアス優先）を流用、↑↓/Enter、⌘Enter で新規タブ |
| 全文検索（⌘⇧F） | サイドバーの Search を選び Content に結果（スニペット・ハイライト付き）。選択で Detail にマッチ位置へジャンプ（既存の `Anchor.text`） |
| ノート内検索（⌘F） | ブロック単位の Text では標準の Find が効かないため、自前の検索バー: レンダリング済みブロックを走査 → 該当ブロックへスクロール + ハイライト（`flashHighlight` の流用） |
| リンクのホバープレビュー | wikilink に一定時間ホバー（または ⌘ホバー）で popover に `NotePreview`。iOS の contextMenu プレビューと同じデータ |
| コンテキストメニュー | リンク・一覧行に「新しいタブで開く」「Obsidian で編集」「Wikilink をコピー」 |
| メニュー | File: New Window / New Tab / Open Quickly、View: Sidebar / Inspector / 文字サイズ（⌘+ / ⌘-）、Go: Back / Forward / Today's Note / Graph、Note: Edit in Obsidian（⌘E）/ Pin / Copy Wikilink / Copy Obsidian Link / Copy Note Text |
| 本文の組版 | 読みやすい最大行幅（~720pt）で中央寄せ。Dynamic Type が無いので文字サイズは自前の設定（AppStorage）で `MathRenderer.fontSize` に渡す |
| テキスト選択 | 各ブロック `.textSelection(.enabled)`。ブロックをまたぐ選択は既知の制約（「Copy Note Text」で補う） |
| グラフ | ホバー = wiki-lens と同じハイライト（`onContinuousHover`）、クリック = 選択、ダブルクリック = ノートを開く、スクロール/ピンチ = ズーム、ドラッグ = パン。GraphCards は Inspector に表示。ラベル予算は画面面積に比例させる。ノード上限（クラスタ 400、ローカル 36）は維持 |
| 添付 | 画像は Quick Look。PDF/音声/動画のプレビューも Quick Look で将来まとめて解決できる（ただし現状それらの実体は公開されていない） |
| Handoff | ノート表示時に `NSUserActivity`（vault パス）を出し、iPhone ⇄ Mac で同じノートを開き継げる。安価で効果が大きいので v1 後半に入れる |

## 5. データ層・更新（WikiViewerKit）

- **更新の追従.** Mac アプリは裏でも止まらないので、`scenePhase` ではなく**アプリ単位**で
  `library.watchForUpdates()` を走らせる（`UpdateCoordinator`：起動時に開始、
  `NSWorkspace.willSleep` で停止、`didWake` と `NSApplication.didBecomeActive` で即時チェックして再開）。
  BGAppRefresh は iOS 専用のまま。
- **ブックマーク.** `SourceConfiguration.folder` の作成・解決に macOS では `.withSecurityScope` を付け、
  `bookmarkDataIsStale` なら再作成して保存する（iOS 側も stale 対応はしていないので共通で直す）。
- **ローカル公開ディレクトリ（場面 B）.** 既存の `LocalFolderArtifactSource` で足りる。
  不変条件どおり公開ディレクトリの DB を直接開かず、アプリのコンテナにコピーして検証する
  （同一 APFS ボリュームならコピーはクローンになり、追加容量はほぼ無い）。
- **メモリ.** `ImageCache` の上限と SQLite のキャッシュをプラットフォーム別の既定値に
  （例: 画像 48 MiB → 256 MiB）。メモリ圧迫時は `DispatchSource` のメモリプレッシャで解放。
- **ネットワーク.** sandbox の outgoing network を有効化。ATS 方針（HTTPS のみ）は iOS と同じ。

## 6. コード構成

```
WikiViewer/
  App/            WikiViewerApp（シーン定義を #if os で分岐）, SharedLibrary
  Platform/
    iOS/          IOSRootView（現 ContentView + TabRoot）, BackgroundRefresh
    macOS/        MacRootView（SplitView + Inspector）, MacCommands, QuickOpenPanel,
                  NoteFindBar, UpdateCoordinator, MacSettingsView
    Shared/       Pasteboard, inlineNavigationTitle(), assetPresentation(), OpenRouteAction
  Navigation/     Route（+ 分類）, NavigationModel（+ forward）, ReadingHistory
  Features/       既存のまま。#if os は小さな差分に限定し、殻の違いは Platform/ に閉じ込める
```

`#if os(macOS)` が機能ビューの中に散らばり始めたら、その画面だけ OS 別ファイルに分ける。

## 7. ビルド・テスト・配布

- `scripts/check.sh` に `mac` ステップ（`xcodebuild -destination 'platform=macOS'`、
  derived data は worktree 内）を追加。CI にも macOS アプリのビルドを追加。
- `scripts/mac.sh run|build|test`：worktree ごとに**別のバンドル ID**
  （例 `$(PRODUCT_BUNDLE_IDENTIFIER).wt-<worktree>`）でビルドする。
  sandbox のコンテナと UserDefaults はバンドル ID 単位なので、そうしないと並行セッションの
  Mac アプリが同じ世代ストアを奪い合う（シミュレータを worktree ごとに分けているのと同じ理由）。
- 配布: 個人利用なら Xcode のローカル署名で十分。他の Mac に配るなら Developer ID + 公証。
  Mac App Store は後で判断（sandbox 準拠なので障害は少ない）。
- テスト: 既存 WikiKit テストは macOS で走る。追加分はルート分類・履歴モデル・
  ブックマーク解決（`.withSecurityScope`）・`UpdateCoordinator` の停止/再開。

## 8. 段階的な進め方

| 段階 | 内容 | 完了条件 |
|---|---|---|
| M0 コンパイル | §2 の置き換え、entitlements、`check.sh mac` | macOS でビルドが通り、デモスナップショットが開ける |
| M1 暫定シェル | `TabView` + `.tabViewStyle(.sidebarAdaptable)`（Mac ではサイドバーになる）、Settings シーン、メニューコマンド、Quick Look | 実ボルトのソースを接続して日常的に読める |
| M2 本番シェル | 3 カラム + Inspector、`OpenRouteAction`、戻る/進む、複数ウインドウ・タブ、状態復元、アプリ単位の更新追従 | §4.1〜4.3 の通り |
| M3 デスクトップ操作 | Quick Open パレット、ノート内検索、ホバープレビュー、コンテキストメニュー、グラフのホバー、文字サイズ、Handoff | §4.4 の通り |
| 将来 | メニューバー常駐（更新状態）、URL スキーム（`wikiviewer://open?path=`）、PDF 等のプレビュー、アプリ内インデクサ | 個別に判断 |

M1 を挟むのは、ナビゲーションの抽象化（M2）の前に Mac 上で実データを触って、
どの操作が本当に足りないかを確かめるため。

## 9. 決定事項（2026-10-02）

1. 利用場面は **A・B の両方**。Settings の説明文もそれに合わせる（公開ディレクトリ／iCloud Drive フォルダ／HTTPS）。
2. Backlinks は**右の Inspector に移す**（M2）。
3. 配布は**自分の Mac だけ**。Xcode の Apple Development 署名でローカルに動かす。Developer ID・公証・App Store は対象外。
4. 将来は**インデクサを内蔵して「ボルトを直接開く」形を目指す**。それまでデータ層は「検証済みの世代を読む」ことに限定し、
   内蔵インデクサも同じ世代を作ってアプリのコンテナへ公開する形にする（ビューア側を二系統にしない）。

## 10. 進捗

### M0（完了）

- iOS 専用 API を `Platform/Shared/PlatformSupport.swift` のヘルパ（`Pasteboard`, `Color.platform*`,
  `inlineNavigationTitle()`, `assetPresentation(item:)`, `MemoryPressureMonitor`）に寄せた。
- `MathRenderer` を AppKit 対応（SwiftMath の `NSImage` を 2× でラスタライズ）。SwiftMath を macOS でもリンク。
- フォルダソースのブックマークを macOS では `.withSecurityScope` で作成・解決し、stale なら作り直して保存。
- sandbox の outgoing network を有効化（`ENABLE_OUTGOING_NETWORK_CONNECTIONS`）。
- `scripts/mac.sh build|run|quit|bundle-id`、`scripts/check.sh mac`。worktree では
  `WV_BUNDLE_ID_SUFFIX`（`Config/Signing.xcconfig`）で `<bundle id>.wt-<worktree>` になる。

### M1（完了）

- `TabView` に `.sidebarAdaptable`（Mac ではサイドバー）、`Settings` シーン（⌘,）、既定ウインドウサイズ。
- ウインドウごとの `AppModel`（`WindowRoot`）。メニュー: File（Search Notes ⌘O / Find in Vault ⇧⌘F /
  Check for New Snapshot ⌘R）、Go（Back ⌘[ / Files〜Search ⌘1〜4）、Note（Edit in Obsidian ⌘E / Pin ⌘D /
  Local Graph ⇧⌘G（M3 で ⌥⌘G に変更） / Copy Wikilink ⇧⌘C / Copy Obsidian Link ⌥⌘C / Copy Note Text）。
  コマンドは focused scene value の `AppModel` → 表示中タブの `NavigationModel`（とその上のノート）に作用する。
- 画像の添付は Quick Look（名前と拡張子を付けたコピーを開く）、それ以外は AssetViewer をシートで。
- 更新追従はアプリ単位の `UpdateCoordinator`（ソース変更で再起動、スリープで停止、復帰で再開）。

確認したこと: デモ世代の表示、ローカル公開ディレクトリを Choose Folder で選んで世代 1 を取り込み、
アプリを開いたまま公開した世代 2 を自動で取り込み、再起動後もブックマークが解決して世代 3 を取り込み、
インライン/ディスプレイ数式、Quick Look、⌘[、Note メニュー、状態復元。

### M2（完了）

- `MacRootView`: サイドバー（Files / Tags / Graph / Search と Pinned）・リスト列・ドキュメント列の 3 カラム。
  リスト列はセクションごとに自分のスタックを持ち、戻る先はリストの上のバー（「‹ Vault」）。
  ドキュメント列はウインドウの履歴（`NavigationModel` に forward スタックを追加、⌘[ / ⌘]、上限 100）。
- `OpenRouteAction`（`@Environment(\.openRoute)`）: 画面は push せずにこれを呼ぶ。iOS は今まで通りタブの
  スタックに push。macOS は `Route.isList` で振り分け、リスト列から開いたリストはリスト列へ、
  ドキュメントは詳細列へ、ノート内のフォルダ・タグのリンクは該当セクションに切り替えてリスト列に出す。
  ⌘クリックで新規タブ、⌥⌘クリックで新規ウインドウ（`RouteTarget.fromCurrentEvent`）。
- Inspector（⌥⌘I、ウインドウごとに保存）: 目次（今いる見出しを表示、クリックで移動）・リンク元・情報
  （プロパティ、タグ、パス・更新日・サイズ）。macOS ではノート本文からリンク元とプロパティを外した。
- ウインドウとタブ: `WindowGroup(for: WindowRequest.self)`。タブは新しいウインドウが自分で元のウインドウの
  タブグループに入る（`TabJoiner`）。タブのラベルは開いている文書名（`NSWindow.tab.title`）。
  File > New Tab（⌘T）、タブバーの「+」。サイドバー選択・各リストのスタック・文書の履歴・Inspector の
  表示はウインドウごとに `@SceneStorage` で復元。
- Graph セクションを選ぶと詳細列にマップを出す（リスト列はクラスタ一覧）。

確認したこと: 3 カラムの表示、ノート内リンク、⌘[ / ⌘]、ノート内のフォルダ・タグのリンクでリスト列が
切り替わる、Inspector の 3 ペイン、⌘クリックでタブ、タブバーの「+」、タブの名前、再起動後のタブと状態の復元、
Graph セクション、検索結果からマッチ位置へ。

M2 の残りの修正（M2 の後に対応）:

- リスト列を NavigationStack にした（戻るボタンは隠し、戻るはリストの上のバーか ←）。後ろのリストは生きているので、
  戻るとスクロール位置が残る。
- リスト列のリストは選択できる List（`RouteList` と `ListSelection`）。↑↓ でノートを順に開く。フォルダやタグは
  ↑↓ では開かず（閲覧中のリストが置き換わるため）、クリック・Return・→ で開き、← で戻る。リストから続けて開いた
  ノートは履歴の 1 段を置き換えるので、矢印キーでの閲覧が戻る履歴を埋めない。選択は詳細列の文書に追従するので、
  ノート内のリンクで移った後も元の行をもう一度クリックできる。Recent は、一覧にあるノートを読み直しただけでは
  並べ替えない（↑↓ で読み進めても次の行が次のノートのまま）。
- 検索欄（Search と Tags のフィルタ）はリスト列の上に置いた（`.searchable` はツールバーの右端、ノートの上に出る）。
- `Route`・`NoteAnchor`（SwiftUI の `Anchor` と衝突するため改名）・`AppTab`・`NavigationHistory`・`RouteDispatch` を
  WikiViewerKit に移し、`swift test` で履歴と振り分けをテストする（NavigationTests）。
- 前のビルドのウインドウしか保存されていなくても、起動時に必ずウインドウを開く（`.defaultLaunchBehavior(.presented)`）。

### M3（完了）

- **クイックオープン**（⌘O、macOS）: ウインドウの上に出るパレット。タイトル・エイリアスで絞り込み（クイック
  スイッチャーと同じ検索）、空なら最近のノート。↑↓・Return、⌘Return で新規タブ、⌥⌘Return で新規ウインドウ、
  Esc か外のクリックで閉じる。全文検索の Search セクションは ⇧⌘F。
- **ノート内検索**（⌘F / ⌘G / ⇧⌘G、Edit メニュー）: ノートの上の検索バー。一致するブロック数と「n / m」、
  現在のブロックを強調し、本文中の一致にも背景色。描画済みのブロックだけを走査する（クエリは発行しない、
  `RenderedNote.blocks(containing:)`）。Local Graph のショートカットは ⌥⌘G に移した。
- **文字サイズ**（⌘= / ⌘- / ⌘0、View メニュー）: macOS は `dynamicTypeSize` を無視するので、ノートの本文・
  見出し・埋め込み・数式を「テキストスタイルの大きさ × 倍率」で描く（`noteFont`、`NoteTextScale`）。
  行の最大幅も倍率に合わせる。Inspector と一覧はシステムの大きさのまま。
- **グラフのホバー**: ポインタの下のノードを、選択と同じく強調（リンクと隣接ノードを浮かせ、他を薄く）。
  ノードの上ではリンクのポインタ。選択中は選択が優先。
- **プレビュー**（Obsidian のページプレビューと同じく ⌘ を押しながら）: 一覧の行（ノート、検索結果、
  リンク元、ピン留め、クラスタのノート）と、**ノート本文中のリンク**の上で ⌘ を押すとポップオーバーに
  ノートの冒頭。ポインタが離れるまで出ている。本文中のリンクは、リンクの run に `LinkRunAttribute` を付けて
  （`Text(math:markingLinks:)`）、TextRenderer が描いた位置を記録し、ポインタと照合する。クリック・
  テキスト選択はそのまま動く。一覧の行の右クリックに「新規タブで開く」「新規ウインドウで開く」。
- **Handoff**: 表示中のノートを `app.wikiviewer.note`（vault パス）として出し、iPhone ⇄ Mac で受け取って
  同じノートを開く。アクティビティ種別はバンドル ID から作らない（worktree のビルドで変わるため）。
  2 台の実機での確認はまだ。

### M3 の後（2026-10-03）

- **バグ修正**（PR #24）: 本文のリンクを辿ると一覧がキーボードを奪う、⌘プレビュー中の最初の ⌘クリックが
  ポップオーバーを閉じるだけ、新規タブの名前が「Vault」、起動直後に Recent が出ない、Recent とフォルダで
  同じノートが二重に選択表示、クイックオープン（入力直後の Return で前の結果を開く・外のクリックで閉じない・
  高さ）、Graph セクションの復元で地図が余分に積まれる、添付のコピーの衝突と残留。
- **残り**（PR #25）: 本文リンクの右クリックメニュー、グラフのホイールズーム・トラックパッドのパン・
  ダブルクリックで開く、ラベル数を面積に比例、端のラベルが切れない、グラフの選択を Inspector に、
  前面に戻ったときの更新確認（1 分に 1 回まで）、画像キャッシュ 256 MiB、サイドバーと Go メニューの
  Today / Recent（Files の先頭が既にホームなので別の Home セクションは作らない）、CI での macOS ビルド。
- **デスクトップの慣習**: Window メニューに文書名、印刷（⌘P、PDF は印刷パネルから）、サイドバー下端の
  更新状態、Recent を右クリックで外す、Settings の文字サイズ、ノートの共有（Markdown）、Open Recent、
  Dock メニュー、グラフのキーボード操作、読書モード（⌃⌘R）、⌘ 単独の長押しでだけプレビュー、
  ツールバーのクイックオープン。
- 見送り: ウインドウタイトルはリストの名前のまま（Mail のメールボックス名と同じ役割。文書名はタブと
  Window メニュー）。Spotlight への登録は §1 の非目標。Export as PDF は保存先への書き込み権限が要る
  （サンドボックスは読み取り専用）ので印刷パネルの PDF に任せる。

### デザインレビューの修正（2026-10-03）

- **本文列の幅**: 既定のウインドウを 1400×900 に、リスト列の幅を 260 前後に、本文列の最小幅を 380 にした
  （1100×760 で Inspector を開くと本文列が約 290pt でいちばん狭かった）。
- **組版**: macOS では 100% を本文 15pt にした（`NoteTextScale.readingSize`、システムの 13pt は操作部品向け）。
  本文の最大幅は本文サイズの約 42 字分、行間は本文サイズの 0.35 倍（和文が詰まらない）。
  コード・表・タグ・フォルダのパンくず・プロパティは `.noteDetail`（macOS は callout 12pt。footnote は 10pt で小さすぎた）。
- **本文以外の文字サイズ**（2026-10-12）: リスト列・インスペクタ・カード類は `chromeFont`（`ChromeTextScale`）で組む。
  システム設定の「サイドバーのアイコンサイズ」が大なら 15/13 倍（本文 100% と同じ 15pt）、小・中なら等倍。
  footnote / caption / caption2 は macOS で 10pt なので callout / subheadline に読み替える。
  macOS の List は行ごとに自前のフォントを当て、行内の Label もタイトルのフォントを戻すので、
  列の外側に置いた `.font` は行に届かない。行は `listRowFont()`（`RouteLink` が付ける）で自分で指定する。
- **クイックオープン**: 選択行の背景をシステムの選択色にした（ダークモードの明るいアクセント色に白文字は読めなかった）。
- **ノートのツールバー**: Edit in Obsidian と共有だけを置き、Local Graph・ピン留め・コピーは「…」メニューにまとめた。
  Inspector のボタンは、ノートでもグラフでも右端。グラフの List/Map 切り替えは macOS では出さない（リスト列にクラスタ一覧がある）。
- **Recent の重複**: サイドバーの Recent をやめ、Files の先頭の Recent（と Go > Recent Notes）だけにした。
  逆に Today とピン留めはサイドバーだけにし、Files の先頭からは外した。

### コードレビューの修正（2026-10-03）

- **ボルトのウインドウの登録**（`VaultWindows`）: New Tab（⌘T）と Dock メニューは、Settings が前面でも
  ボルトのウインドウに作用する。タブの参加は 1 回だけ試す（親が閉じていても、次の起動で同じ番号の別の
  ウインドウに入らない）。
- **終了時に閲覧履歴を保存**（`applicationWillTerminate`。⌘Q はウインドウの非アクティブ化を待たない）。
- **印刷**: 長いノートで止まらないよう、数ブロックごとに間を置いて PDF を作る。準備中の ⌘P は無視。
- **Edit メニュー**: 標準の Find・Speech は text view 向けなので、同じ名前のサブメニューに自前の項目を置く。
  Start Speaking はノートの見える文字（コードと数式を除く）を、言語に合った声で読む（`NoteSpeech`）。
- **サイドバー**: Today とピン留めを選択できる行にした（ノートを開く。文書が変わるとセクションの選択に戻る）。
- **開く先**: `openRoute(route)` は呼んだ時点のイベントで新規タブ／ウインドウを決め、渡された target は
  そのまま使う（非同期の後で修飾キーを読み直さない）。
- 前面に戻ったときの更新確認は、HTTPS の監視（ロングポールかもしれない）が動いていて失敗していなければ
  やり直さない。クイックオープンの選択行の文字色と VoiceOver の選択状態、macOS のグラフの VoiceOver ヒント。

### 自分用の配布（2026-10-03）

- `scripts/mac.sh install` で Release 版を /Applications に入れる（動いている版は終了し、前の版はゴミ箱へ）。
  `scripts/mac.sh release` は入れずに build/Release に .app と zip を作る（他の Mac 用）。
- バンドル ID は worktree でも素の ID（インストール版のコンテナは 1 つ）。ビルド番号は `git rev-list --count HEAD`。
- Apple Development 署名は Release でも `get-task-allow` を付けるので、外して署名し直す
  （`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` はビルド設定由来のサンドボックス権限まで落とす）。
- 公証していないので、AirDrop などで受け取った zip は他の Mac で「このまま開く」が要る（SETUP.md §7）。

### macOS で見つかった SwiftUI の挙動（M2 の設計に効く）

- `NavigationStack` に付けた `.environment` が push 先に伝わらない → `navigationDestination` の中でも渡す。
- List 内の `NavigationLink(value:)` は戻った後も行が選択状態のまま残り、同じ行を再クリックしても開かない
  → macOS ではボタンで push する `RouteLink` を使う（M2 の `OpenRouteAction` の前身）。
- List は**別セクションでも同じ id の行を同一視する**（ピン留めと最近の同じノート、フォルダ 3 とノート 3）
  → 複数セクションの List は `ForEach(…, id: \.[row: "section"])` でセクション付きの id にする。
- 同じ focused value を複数のビュー（隠れたタブ）が出すと nil が勝つことがある → 表示中タブの判定は `AppModel` 側で行う。
- 3 カラムでは、ツールバーの `.navigation` 配置（NavigationStack の戻るボタンも）はウインドウタイトル（リスト列の
  タイトル）の左に並ぶ。Finder や Safari と同じ位置なので、そこは文書の戻る/進むに使う。
- SwiftUI は「タブとして開く」を持たず、キーウインドウの `tabbingMode` を一時的に変えても新しいウインドウは
  タブにならなかった → 新しいウインドウ側から `addTabbedWindow` する。
- `WindowGroup(for:)` は同じ値のウインドウがあれば新しく開かずに前に出す → 値に UUID を含める。
- `List(selection:)` の行をクリックしても List はキーボードフォーカスを取らない（first responder はウインドウのまま）
  → 選択が変わったら `@FocusState` で List にフォーカスを移す。
- `.tag(route as Route?)` は `Binding<Route?>` の選択と一致しない（行が選択できない）→ `.tag(route)` にする。
- オーバーレイの TextField を `onAppear` でフォーカスしても、後ろの List がキーボードを持ったまま → 次のターンで。
- `.keyboardShortcut("+")` は ⌘= でも ⌘⇧= でも一致しない → Bigger は ⌘=。
- `.dynamicTypeSize` は macOS では効かない。
- macOS の contextMenu には `preview:` が出ない → ⌘ホバーのポップオーバーで代わりにする。
- ポップオーバー（transient）は外側のクリックを閉じるためだけに使う → 閉じられたときの
  `NSApp.currentEvent` がプレビュー元へのクリックなら、そのクリックで開く。
- 3 カラムの `NavigationSplitView` は macOS で content 列を隠せない（`.detailOnly` が効かない）。
- SwiftUI のビューは AppKit の印刷経路で描かれない（`NSHostingView` を印刷すると白紙）。`ImageRenderer` は
  スクロールビューの中身と `.task` が後で読み込むものを描かない。
- `onTapGesture` は macOS のダブルクリックの 2 回目を拾わない → `SpatialTapGesture(count: 2)` を並べる。
