#!/usr/bin/env swift

// drive-rescue - Synology Drive 未同期ファイル救出ツール
//
// macOS URLResourceValues API で FileProvider 管理下ファイルの同期状態を確認し、
// 未同期ファイルを抽出・コピーする。
//
// stdout: パイプ可能な TSV / パス出力
// stderr: 進捗・サマリ・エラー

import Foundation

// MARK: - Resource Keys

let syncResourceKeys: Set<URLResourceKey> = [
    .isRegularFileKey,
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .fileSizeKey,
    .contentModificationDateKey,
    .isUbiquitousItemKey,
    .ubiquitousItemIsUploadedKey,
    .ubiquitousItemIsUploadingKey,
    .ubiquitousItemHasUnresolvedConflictsKey,
    .ubiquitousItemDownloadingStatusKey,
    .ubiquitousItemUploadingErrorKey,
    .ubiquitousItemDownloadRequestedKey,
    .ubiquitousItemContainerDisplayNameKey,
]

// MARK: - Extended Attributes

func listXattrs(at path: String) -> [String] {
    let bufSize = listxattr(path, nil, 0, 0)
    guard bufSize > 0 else { return [] }

    var buf = [CChar](repeating: 0, count: bufSize)
    let result = listxattr(path, &buf, bufSize, 0)
    guard result > 0 else { return [] }

    var names: [String] = []
    var current = ""
    for i in 0..<result {
        if buf[i] == 0 {
            if !current.isEmpty { names.append(current) }
            current = ""
        } else {
            current.append(Character(UnicodeScalar(UInt8(bitPattern: buf[i]))))
        }
    }
    if !current.isEmpty { names.append(current) }
    return names
}

// MARK: - CloudStorage Root Detection

/// ~/Library/CloudStorage/SynologyDrive-xxx/some/sub/dir
///  -> ~/Library/CloudStorage/SynologyDrive-xxx
func detectCloudStorageRoot(_ dir: URL) -> URL {
    let path = dir.path
    guard let range = path.range(of: "/Library/CloudStorage/") else {
        return dir
    }
    let after = path[range.upperBound...]
    // CloudStorage 直下の最初のコンポーネント（例: SynologyDrive-mksc）
    let rootEnd: String.Index
    if let slash = after.firstIndex(of: "/") {
        rootEnd = slash
    } else {
        rootEnd = after.endIndex
    }
    let rootPath = String(path[...path.index(before: range.upperBound)]) + String(after[..<rootEnd])
    return URL(fileURLWithPath: rootPath, isDirectory: true)
}

// MARK: - File Status

struct FileStatus {
    let url: URL
    let relativePath: String
    let fileSize: Int?
    let modificationDate: Date?
    let isUbiquitous: Bool?
    let isUploaded: Bool?
    let isUploading: Bool?
    let hasConflicts: Bool?
    let downloadingStatus: URLUbiquitousItemDownloadingStatus?
    let uploadingError: NSError?
    let xattrs: [String]

    var needsRescue: Bool {
        if let uploaded = isUploaded {
            if !uploaded { return true }
        }
        if isUploading == true { return true }
        if hasConflicts == true { return true }
        if uploadingError != nil { return true }
        return false
    }

    var hasFileProviderMetadata: Bool {
        return isUbiquitous != nil || isUploaded != nil
    }

    var reason: String {
        if isUploaded == false { return "not_uploaded" }
        if isUploading == true { return "uploading" }
        if hasConflicts == true { return "conflict" }
        if uploadingError != nil { return "upload_error" }
        return "synced"
    }

    var downloadStatusShort: String {
        guard let ds = downloadingStatus else { return "-" }
        switch ds {
        case .current: return "current"
        case .downloaded: return "downloaded"
        case .notDownloaded: return "not_downloaded"
        default: return ds.rawValue
        }
    }
}

let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f
}()

func checkFile(url: URL, relativeTo baseDir: URL) -> FileStatus? {
    let values = try? url.resourceValues(forKeys: syncResourceKeys)
    guard values?.isRegularFile == true else { return nil }

    let relativePath = String(url.path.dropFirst(baseDir.path.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let xattrs = listXattrs(at: url.path)

    return FileStatus(
        url: url,
        relativePath: relativePath,
        fileSize: values?.fileSize,
        modificationDate: values?.contentModificationDate,
        isUbiquitous: values?.isUbiquitousItem,
        isUploaded: values?.ubiquitousItemIsUploaded,
        isUploading: values?.ubiquitousItemIsUploading,
        hasConflicts: values?.ubiquitousItemHasUnresolvedConflicts,
        downloadingStatus: values?.ubiquitousItemDownloadingStatus,
        uploadingError: values?.ubiquitousItemUploadingError as NSError?,
        xattrs: xattrs
    )
}

// MARK: - Directory Enumeration

func enumerateFiles(in dir: URL, action: (URL) -> Bool) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: dir,
        includingPropertiesForKeys: Array(syncResourceKeys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        fputs("error: cannot enumerate \(dir.path)\n", stderr)
        exit(1)
    }

    for case let fileURL as URL in enumerator {
        if !action(fileURL) { break }
    }
}

// MARK: - Output helpers

func boolStr(_ v: Bool?) -> String {
    guard let v = v else { return "-" }
    return v ? "true" : "false"
}

// MARK: - Diagnose
// stdout: TSV (path, size, mtime, ubiquitous, uploaded, uploading, conflicts, dl_status, reason, xattrs)

func diagnose(scanDir: URL, rootDir: URL) {
    let fm = FileManager.default

    let dirIsUbiquitous = fm.isUbiquitousItem(at: scanDir)
    let isCloudStorage = scanDir.path.contains("/Library/CloudStorage/")

    fputs("scan: \(scanDir.path)\n", stderr)
    fputs("root: \(rootDir.path)\n", stderr)
    fputs("ubiquitous: \(dirIsUbiquitous), cloud_storage: \(isCloudStorage)\n", stderr)

    if !dirIsUbiquitous && !isCloudStorage {
        fputs("warning: directory not managed by FileProvider, metadata may be nil\n", stderr)
    }

    // TSV header
    print("path\tsize\tmtime\tubiquitous\tuploaded\tuploading\tconflicts\tdl_status\treason\txattrs")

    var hasMetadata = false

    enumerateFiles(in: scanDir) { fileURL in
        guard let s = checkFile(url: fileURL, relativeTo: rootDir) else { return true }
        if s.hasFileProviderMetadata { hasMetadata = true }

        let size = s.fileSize.map(String.init) ?? "-"
        let mtime = s.modificationDate.map { dateFmt.string(from: $0) } ?? "-"
        let xattrs = s.xattrs.isEmpty ? "-" : s.xattrs.joined(separator: ",")

        print("\(s.relativePath)\t\(size)\t\(mtime)\t\(boolStr(s.isUbiquitous))\t\(boolStr(s.isUploaded))\t\(boolStr(s.isUploading))\t\(boolStr(s.hasConflicts))\t\(s.downloadStatusShort)\t\(s.reason)\t\(xattrs)")
        return true
    }

    if !hasMetadata {
        fputs("warning: no FileProvider metadata found\n", stderr)
    }
}

// MARK: - Rescue
// stdout: rescued file paths (1 per line)

func rescue(scanDir: URL, rootDir: URL, destDir: URL?, dryRun: Bool) {
    let fm = FileManager.default

    fputs("scan: \(scanDir.path)\n", stderr)
    fputs("root: \(rootDir.path)\n", stderr)
    if let destDir = destDir {
        fputs("dest: \(destDir.path)\n", stderr)
    }
    if dryRun {
        fputs("mode: dry-run\n", stderr)
    }

    var scanned = 0
    var rescued: [FileStatus] = []
    var noMetadataCount = 0

    enumerateFiles(in: scanDir) { fileURL in
        guard let status = checkFile(url: fileURL, relativeTo: rootDir) else { return true }
        scanned += 1

        if scanned % 500 == 0 {
            fputs("scanning: \(scanned) files...\n", stderr)
        }

        if !status.hasFileProviderMetadata {
            noMetadataCount += 1
        }

        if status.needsRescue {
            rescued.append(status)
        }
        return true
    }

    fputs("scanned: \(scanned)\n", stderr)

    if noMetadataCount == scanned && scanned > 0 {
        fputs("error: no FileProvider metadata, cannot determine sync status\n", stderr)
        fputs("hint: drive-rescue --diagnose \(scanDir.path)\n", stderr)
        exit(1)
    }

    fputs("unsynced: \(rescued.count)\n", stderr)

    if rescued.isEmpty {
        exit(0)
    }

    var totalSize: Int64 = 0
    var errors = 0

    for status in rescued {
        if let s = status.fileSize { totalSize += Int64(s) }

        if dryRun {
            print(status.relativePath)
        } else if let destDir = destDir {
            let destURL = destDir.appendingPathComponent(status.relativePath)
            do {
                try fm.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: status.url, to: destURL)
                print(status.relativePath)
            } catch {
                fputs("error: \(status.relativePath): \(error.localizedDescription)\n", stderr)
                errors += 1
            }
        }
    }

    fputs("rescued: \(rescued.count - errors), size: \(totalSize), errors: \(errors)\n", stderr)
}

// MARK: - Main

func printUsage() {
    let p = (CommandLine.arguments[0] as NSString).lastPathComponent
    fputs("""
    Usage:
      \(p) <sourcedir> <destdir>       Copy unsynced files
      \(p) --dry-run <sourcedir>       List unsynced files
      \(p) --diagnose <sourcedir>      Show metadata (TSV)

    sourcedir can be a CloudStorage root or any subdirectory:
      \(p) --diagnose ~/Library/CloudStorage/SynologyDrive-mksc
      \(p) --diagnose ~/Library/CloudStorage/SynologyDrive-mksc/10_Project/106_新明工業
      \(p) --dry-run  ~/Library/CloudStorage/SynologyDrive-mksc/10_Project
      \(p) ~/Library/CloudStorage/SynologyDrive-mksc ~/Desktop/rescue

    Output:
      --diagnose  stdout=TSV  stderr=summary
      --dry-run   stdout=paths  stderr=summary
      rescue      stdout=copied paths  stderr=progress

    \n
    """, stderr)
}

func resolveDir(_ path: String) -> URL {
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true)
}

// MARK: - Argument Parsing

struct ParsedArgs {
    var mode: String = "rescue"
    var sourceDir: URL?
    var destDir: URL?
}

func parseArgs(_ args: [String]) -> ParsedArgs {
    var parsed = ParsedArgs()
    var remaining: [String] = []
    var i = 0

    while i < args.count {
        switch args[i] {
        case "--dry-run":
            parsed.mode = "dry-run"
        case "--diagnose":
            parsed.mode = "diagnose"
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            remaining.append(args[i])
        }
        i += 1
    }

    switch parsed.mode {
    case "diagnose", "dry-run":
        guard remaining.count >= 1 else {
            fputs("error: --\(parsed.mode) requires <sourcedir>\n", stderr)
            exit(1)
        }
        parsed.sourceDir = resolveDir(remaining[0])
    default:
        guard remaining.count >= 2 else {
            if remaining.count == 1 {
                fputs("error: requires <sourcedir> <destdir>\n", stderr)
            } else {
                printUsage()
            }
            exit(1)
        }
        parsed.sourceDir = resolveDir(remaining[0])
        parsed.destDir = resolveDir(remaining[1])
    }

    return parsed
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    printUsage()
    exit(0)
}

let parsed = parseArgs(args)
let scanDir = parsed.sourceDir!
let rootDir = detectCloudStorageRoot(scanDir)

switch parsed.mode {
case "diagnose":
    diagnose(scanDir: scanDir, rootDir: rootDir)

case "dry-run":
    rescue(scanDir: scanDir, rootDir: rootDir, destDir: nil, dryRun: true)

default:
    let destDir = parsed.destDir!
    let fm = FileManager.default
    if !fm.fileExists(atPath: destDir.path) {
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            fputs("error: cannot create destination: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    rescue(scanDir: scanDir, rootDir: rootDir, destDir: destDir, dryRun: false)
}
