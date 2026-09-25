//
//  VaultFiles.swift
//  IndexerCore
//
//  Read-only access to the vault: metadata walk and stable reads.
//  Nothing in this file (or anywhere in the indexer) opens a vault file for
//  writing: files are opened with O_RDONLY | O_NOFOLLOW only.
//

import Foundation
import WikiShared

/// File metadata used to detect changes without reading content.
public struct FileMeta: Sendable, Equatable {
    public var size: Int64
    /// Modification time in nanoseconds since 1970.
    public var mtimeNs: Int64
    public var inode: UInt64

    init(_ st: stat) {
        size = Int64(st.st_size)
        mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        inode = UInt64(st.st_ino)
    }

    public init(size: Int64, mtimeNs: Int64, inode: UInt64 = 0) {
        self.size = size
        self.mtimeNs = mtimeNs
        self.inode = inode
    }

    /// Size and mtime are what reconciliation compares.
    func sameContentSignature(_ other: FileMeta) -> Bool {
        size == other.size && mtimeNs == other.mtimeNs
    }
}

public enum VaultEntryKind: Sendable, Equatable {
    case note
    case asset(ViewerSchema.AssetKind)

    /// Classifies a vault-relative path. Returns nil for files the viewer
    /// ignores (dotfiles, `.obsidian/`, canvases, unknown types).
    public static func classify(_ relativePath: String) -> VaultEntryKind? {
        for component in relativePath.split(separator: "/") where component.hasPrefix(".") {
            return nil
        }
        let ext = VaultPath.fileExtension(of: relativePath)
        if ext == "md" { return .note }
        if let kind = ViewerSchema.AssetKind.forExtension(ext) { return .asset(kind) }
        return nil
    }
}

public struct VaultEntry: Sendable, Equatable {
    public var path: String
    public var meta: FileMeta
    public var kind: VaultEntryKind
}

public enum VaultWalker {
    /// Walks the vault (or a subfolder) collecting metadata of indexable
    /// files. Uses fts(3) with FTS_PHYSICAL so symlinks are never followed
    /// (a symlink could otherwise point outside the vault), and skips hidden
    /// directories such as `.obsidian` and `.trash` without descending.
    public static func walk(vault: URL, subpath: String? = nil) throws -> [VaultEntry] {
        let rootPath = vault.canonicalPath
        let start = subpath.map { rootPath + "/" + $0 } ?? rootPath
        var entries: [VaultEntry] = []
        guard let cStart = strdup(start) else { throw POSIXError(.ENOMEM) }
        defer { free(cStart) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cStart, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { fts_close(fts) }
        let prefixLength = rootPath.utf8.count + 1
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            let fullPath = String(cString: entry.pointee.fts_path)
            let name = VaultPath.fileName(of: fullPath)
            switch info {
            case FTS_D:
                if entry.pointee.fts_level > 0, name.hasPrefix(".") {
                    fts_set(fts, entry, FTS_SKIP)
                }
            case FTS_F:
                guard fullPath.utf8.count > prefixLength else { continue }
                let rawRelative = String(decoding: fullPath.utf8.dropFirst(prefixLength), as: UTF8.self)
                guard let relative = VaultPath.normalizeRelative(rawRelative),
                      let kind = VaultEntryKind.classify(relative),
                      let st = entry.pointee.fts_statp?.pointee else { continue }
                entries.append(VaultEntry(path: relative, meta: FileMeta(st), kind: kind))
            case FTS_DNR, FTS_ERR, FTS_NS:
                Log.warning("walk: cannot read \(fullPath): \(String(cString: strerror(entry.pointee.fts_errno)))")
            default:
                // Symlinks (FTS_SL), special files, post-order dirs: ignored.
                break
            }
        }
        return entries
    }

    /// lstat of a single vault-relative path. nil if missing or not a
    /// regular file.
    public static func meta(vault: URL, relativePath: String) -> (meta: FileMeta, isDirectory: Bool)? {
        let path = vault.canonicalPath + "/" + relativePath
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        if type == S_IFDIR { return (FileMeta(st), true) }
        guard type == S_IFREG else { return nil }
        return (FileMeta(st), false)
    }
}

public enum StableRead: Sendable {
    case stable(Data, FileMeta)
    /// The file changed while it was being read; retry later.
    case unstable
    /// Missing, a symlink, or not a regular file.
    case missing
    case tooLarge(FileMeta)
    case failed(String)
}

/// Checks the real path of an open file (F_GETPATH):
/// - it must lie inside the vault (a directory above the file could have been
///   replaced by a symlink; O_NOFOLLOW only protects the last component);
/// - its vault-relative name must equal `relativePath` exactly after NFC
///   normalization. On case-insensitive APFS, opening "a/Note.md" succeeds
///   after a case-only rename to "a/note.md"; the old path must then count
///   as deleted, not as still present.
func openedFileMatches(fd: Int32, vault: URL, relativePath: String) -> Bool {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
    let length = buffer.firstIndex(of: 0) ?? buffer.count
    let real = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let root = vault.canonicalPath + "/"
    guard real.hasPrefix(root) else { return false }
    return VaultPath.normalizeRelative(String(real.dropFirst(root.count))) == relativePath
}

public enum StableReader {
    /// Reads a vault file only if it did not change during the read:
    ///
    ///     fstat A → read → fstat B → lstat(path) C
    ///     accept iff A == B == C (size, mtime, inode) and bytes read == size
    ///
    /// C catches the case where Obsidian atomically replaced the file
    /// (rename over the path) while we were reading the old inode.
    public static func read(vault: URL, relativePath: String, maximumBytes: Int) -> StableRead {
        read(vault: vault, relativePath: relativePath, maximumBytes: maximumBytes, afterRead: nil)
    }

    /// `afterRead` is a test hook that runs between the read and the second stat.
    static func read(vault: URL, relativePath: String, maximumBytes: Int, afterRead: (() -> Void)?) -> StableRead {
        let path = vault.canonicalPath + "/" + relativePath
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT || err == ELOOP || err == ENOTDIR { return .missing }
            return .failed(String(cString: strerror(err)))
        }
        defer { close(fd) }
        // O_NOFOLLOW only covers the last component; a directory above it
        // could have been replaced by a symlink pointing outside the vault.
        guard openedFileMatches(fd: fd, vault: vault, relativePath: relativePath) else { return .missing }
        var a = stat()
        guard fstat(fd, &a) == 0 else { return .failed(String(cString: strerror(errno))) }
        guard a.st_mode & S_IFMT == S_IFREG else { return .missing }
        let metaA = FileMeta(a)
        if metaA.size > Int64(maximumBytes) { return .tooLarge(metaA) }

        var data = Data(count: Int(metaA.size))
        var total = 0
        let expected = Int(metaA.size)
        let readOK: Bool = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            while total < expected {
                let n = Darwin.read(fd, base + total, expected - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { break }
                total += n
            }
            return true
        }
        guard readOK else { return .failed(String(cString: strerror(errno))) }
        afterRead?()
        // One extra byte probe: if the file grew, it is not stable.
        var probe: UInt8 = 0
        let extra = Darwin.read(fd, &probe, 1)

        var b = stat()
        guard fstat(fd, &b) == 0 else { return .failed(String(cString: strerror(errno))) }
        var c = stat()
        guard lstat(path, &c) == 0 else { return .unstable }
        let metaB = FileMeta(b)
        let metaC = FileMeta(c)
        guard total == expected, extra == 0, metaA == metaB, metaA == metaC else { return .unstable }
        return .stable(data, metaA)
    }
}
