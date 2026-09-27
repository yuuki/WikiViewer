//
//  main.swift
//  wikiindex
//
//  Command-line entry point. See `wikiindex help`.
//

import Foundation
import IndexerCore
import WikiShared
import WikiViewerKit

let usage = """
wikiindex — read-only Obsidian vault indexer and artifact publisher for WikiViewer

USAGE
  wikiindex build   --vault DIR --state DIR --publish DIR [options]
      Reconcile the vault into builder.sqlite and publish a generation if anything changed.
  wikiindex watch   --vault DIR --state DIR --publish DIR [options]
      Long-running daemon: FSEvents fast path + periodic reconciliation +
      quiet-period publication.
  wikiindex verify  --publish DIR
      Validate manifest.json, database hash/size, integrity and asset blobs.
  wikiindex synth   --out DIR [--notes N] [--seed S] [--avg-bytes B] [--links L]
                    [--folders F] [--tags T] [--ja-ratio R] [--asset-rate A]
      Generate a deterministic synthetic vault for tests and benchmarks.
  wikiindex bench   --vault DIR --work DIR [--updates N]
      Host benchmarks: initial index, single update, burst, reconcile, publish.
  wikiindex bench-queries --db FILE [--iterations N]
      Latency of the viewer's bounded queries against a published database.
  wikiindex serve   --publish DIR [--port 8080] [--bind 127.0.0.1]
      Minimal read-only static HTTP server for a publish directory (LAN/testing).
      Keeps connections alive and answers GET /manifest.json?wait=N as soon
      as a generation newer than N is published (long poll).

OPTIONS
  --image-max N        longest side of image derivatives (default 2048)
  --retain N           published generations to keep (default 3)
  --quiet SECONDS      publication quiet period after a burst (default 20)
  --quick-quiet SECONDS
                       quiet period after a small edit (default 3)
  --quick-files N      edits of at most N files count as small (default 5)
  --max-delay SECONDS  maximum publication delay (default 300)
  --reconcile SECONDS  periodic reconciliation interval (default 600)
  --full-check         use PRAGMA integrity_check instead of quick_check
  --chunk-size BYTES   delta-transport chunk size (default 131072)
  --chunks-only        publish chunks + chunk list but not the whole database
                       file (recommended for iCloud Drive publish folders)
  --pack-bases N       publish page-level delta packs from the last N
                       generations (default 3); the state directory keeps a
                       private copy of each of those databases
  --no-packs           publish no page-level packs (chunks only)
  --exclude PATTERN    never index this folder; repeatable. "Private" matches
                       a folder of that name at any depth, "/Private" or
                       "Archive/2024" a path from the vault root; * and ?
                       match within one path component; case-insensitive
  --exclude-file FILE  read --exclude patterns from FILE, one per line
                       ("#" starts a comment); watch re-reads it on change
  --include PATTERN    index and publish only this folder (and everything
                       inside it); repeatable. Always a path from the vault
                       root: "Projects" or "Work/Notes"; * and ? as above.
                       Without --include the whole vault is published
  --include-file FILE  read --include patterns from FILE, one per line; it
                       must list at least one folder; watch re-reads it
  --graph-include PATTERN
                       build the link graph (clusters and map) only from
                       notes matching PATTERN; repeatable. A folder ("wiki")
                       or an fnmatch pattern on the note path ("wiki/*.md");
                       * also crosses "/". Default: every published note
  --graph-exclude PATTERN
                       leave matching notes out of the graph, e.g. index or
                       log notes that link to everything; repeatable
  --graph-label-types LIST
                       comma-separated frontmatter types a cluster is named
                       after first (default concept,question,entity,source)
  --no-graph           do not build the link graph
  --force              publish even if nothing changed
  --verbose            debug logging

The vault is never written to; --state and --publish must be outside it.
Hidden folders (.obsidian, .trash, …) and node_modules are always excluded.
With --include, notes at the vault root are not published, and --exclude still
applies inside the included folders.
Changing the exclusions or inclusions takes effect on the next build; a running
watch applies edits to --exclude-file and --include-file without a restart.
Newly excluded notes are removed from the next generation.
"""

struct Arguments {
    var command: String
    var options: [String: String] = [:]
    /// Every value of each option, in order, for repeatable options.
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        command = argv.dropFirst().first ?? "help"
        var i = 2
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[name] = argv[i + 1]
                    lists[name, default: []].append(argv[i + 1])
                    i += 2
                    continue
                }
                flags.insert(name)
            }
            i += 1
        }
    }

    func url(_ name: String) throws -> URL {
        guard let value = options[name] else { throw CLIError("missing --\(name)") }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    func int(_ name: String, _ fallback: Int) -> Int { options[name].flatMap(Int.init) ?? fallback }
    func double(_ name: String, _ fallback: Double) -> Double { options[name].flatMap(Double.init) ?? fallback }
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

func makeConfiguration(_ args: Arguments) throws -> IndexerConfiguration {
    var config = IndexerConfiguration(vault: try args.url("vault"), stateDirectory: try args.url("state"), publishDirectory: try args.url("publish"))
    config.imageMaxDimension = args.int("image-max", config.imageMaxDimension)
    config.retainedGenerations = args.int("retain", config.retainedGenerations)
    config.quietPeriod = .milliseconds(Int(args.double("quiet", 20) * 1000))
    config.quickQuietPeriod = .milliseconds(Int(args.double("quick-quiet", 3) * 1000))
    config.quickPublishMaxFiles = args.int("quick-files", config.quickPublishMaxFiles)
    config.maximumPublicationDelay = .milliseconds(Int(args.double("max-delay", 300) * 1000))
    config.reconciliationInterval = .milliseconds(Int(args.double("reconcile", 600) * 1000))
    config.fullIntegrityCheck = args.flags.contains("full-check")
    config.chunkSize = args.int("chunk-size", config.chunkSize)
    config.publishFullDatabase = !args.flags.contains("chunks-only")
    config.publishPacks = !args.flags.contains("no-packs")
    config.packDeltaBases = min(max(1, args.int("pack-bases", config.packDeltaBases)), ArtifactManifest.PackIndex.maximumDeltas)
    config.excludePatterns = args.lists["exclude"] ?? []
    if args.options["exclude-file"] != nil {
        config.excludeFile = try args.url("exclude-file")
    }
    config.includePatterns = args.lists["include"] ?? []
    if args.options["include-file"] != nil {
        config.includeFile = try args.url("include-file")
    }
    config.graph.includePatterns = args.lists["graph-include"] ?? []
    config.graph.excludePatterns = args.lists["graph-exclude"] ?? []
    if let types = args.options["graph-label-types"] {
        config.graph.labelTypes = types.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    config.graph.enabled = !args.flags.contains("no-graph")
    return config
}

func run() async throws {
    let args = Arguments(CommandLine.arguments)
    if args.flags.contains("verbose") { Log.setLevel(.debug) }
    switch args.command {
    case "build":
        let indexer = try Indexer(configuration: try makeConfiguration(args))
        let stats = try await indexer.reconcile()
        Log.info("reconcile: \(stats)")
        if let result = try await indexer.publish(force: args.flags.contains("force")) {
            Log.info("published generation \(result.manifest.generation): \(result.manifest.noteCount) notes, \(result.manifest.database.byteSize) bytes in \(String(format: "%.3f", result.seconds))s")
        } else {
            Log.info("nothing to publish")
        }
    case "watch":
        let daemon = try IndexerDaemon(configuration: try makeConfiguration(args))
        try await daemon.run()
    case "verify":
        let report = try ArtifactVerifier.verify(publishDirectory: try args.url("publish"))
        print(report)
    case "synth":
        var spec = SyntheticVaultSpec()
        spec.noteCount = args.int("notes", spec.noteCount)
        spec.seed = UInt64(args.int("seed", Int(spec.seed)))
        spec.averageNoteBytes = args.int("avg-bytes", spec.averageNoteBytes)
        spec.linksPerNote = args.int("links", spec.linksPerNote)
        spec.folderCount = args.int("folders", spec.folderCount)
        spec.tagCardinality = args.int("tags", spec.tagCardinality)
        spec.japaneseRatio = args.double("ja-ratio", spec.japaneseRatio)
        spec.assetRate = args.double("asset-rate", spec.assetRate)
        let out = try args.url("out")
        let start = Clock.now()
        let summary = try SyntheticVault.generate(spec: spec, at: out)
        print("generated \(summary) in \(String(format: "%.2f", Clock.seconds(since: start)))s")
    case "bench":
        try await HostBenchmark.run(vault: try args.url("vault"), work: try args.url("work"), updates: args.int("updates", 20), imageMax: args.int("image-max", 2048))
    case "bench-queries":
        let report = try await QueryBenchmark(url: try args.url("db"), iterations: args.int("iterations", 30)).run()
        print(report.markdown)
        print("JSON " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    case "serve":
        let server = try StaticHTTPServer(root: try args.url("publish"), port: UInt16(args.int("port", 8080)), bindAddress: args.options["bind"] ?? "127.0.0.1")
        try await server.run()
    default:
        print(usage)
    }
}

do {
    try await run()
} catch {
    Log.error("\(error)")
    exit(1)
}
