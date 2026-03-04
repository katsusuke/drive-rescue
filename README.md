# drive-rescue

Rescue locally modified but unsynced files from Synology Drive on macOS.

## Motivation

Synology Drive Client on macOS occasionally gets into a broken sync state. The common fix is to unlink and re-sync the folder, but this risks overwriting local changes that haven't been uploaded yet.

drive-rescue uses the macOS `URLResourceValues` API to query the FileProvider sync status of each file (`ubiquitousItemIsUploaded`, `ubiquitousItemIsUploading`, etc.) and extracts files that are locally modified but not yet synced to the NAS.

## Requirements

- macOS 13+
- Swift 6.0+
- Synology Drive Client using FileProvider (sync folder under `~/Library/CloudStorage/`)

## Build

```
swift build
```

The binary is at `.build/debug/drive-rescue`.

For a release build:

```
swift build -c release
cp .build/release/drive-rescue /usr/local/bin/
```

## Install from GitHub Releases

Download the latest zip from [Releases](https://github.com/katsusuke/drive-rescue/releases), then:

```bash
unzip drive-rescue-macos-arm64-*.zip
xattr -d com.apple.quarantine ./drive-rescue
chmod +x ./drive-rescue
mv ./drive-rescue /usr/local/bin/
```

The `xattr` command removes the macOS Gatekeeper quarantine flag, which blocks unsigned binaries downloaded from the internet.

## Usage

```
drive-rescue <sourcedir> <destdir>       # copy unsynced files
drive-rescue --dry-run <sourcedir>       # list unsynced files (no copy)
drive-rescue --diagnose <sourcedir>      # show file metadata as TSV
```

`sourcedir` can be the CloudStorage root or any subdirectory. The CloudStorage root is auto-detected from the path.

```
# diagnose a subdirectory
drive-rescue --diagnose ~/Library/CloudStorage/SynologyDrive-MyNAS/Projects

# list unsynced files
drive-rescue --dry-run ~/Library/CloudStorage/SynologyDrive-MyNAS/Projects

# rescue unsynced files
drive-rescue ~/Library/CloudStorage/SynologyDrive-MyNAS ~/Desktop/rescue
```

## Output

All modes write machine-readable data to stdout and human-readable progress to stderr.

| Mode | stdout | stderr |
|------|--------|--------|
| `--diagnose` | TSV with sync metadata | scan info, warnings |
| `--dry-run` | unsynced file paths (one per line) | scan summary |
| rescue | copied file paths (one per line) | progress, summary |

### Pipe examples

```bash
# count unsynced files
drive-rescue --dry-run ~/Library/CloudStorage/SynologyDrive-MyNAS 2>/dev/null | wc -l

# filter diagnose output for unsynced files
drive-rescue --diagnose ~/Library/CloudStorage/SynologyDrive-MyNAS 2>/dev/null | awk -F'\t' '$9 != "synced"'

# save unsynced file list
drive-rescue --dry-run ~/Library/CloudStorage/SynologyDrive-MyNAS > unsynced.txt 2>/dev/null
```

### Diagnose TSV columns

```
path  size  mtime  ubiquitous  uploaded  uploading  conflicts  dl_status  reason  xattrs
```

The `reason` column values: `synced`, `not_uploaded`, `uploading`, `conflict`, `upload_error`.

## How it works

drive-rescue queries `URLResourceValues` for each file in the sync folder:

- `ubiquitousItemIsUploaded` = `false` -- locally modified, not yet synced
- `ubiquitousItemIsUploading` = `true` -- currently uploading
- `ubiquitousItemHasUnresolvedConflicts` = `true` -- conflict detected
- `ubiquitousItemUploadingError` != `nil` -- upload failed

Files matching any of these conditions are considered "unsynced" and eligible for rescue.

Run `--diagnose` first to verify that FileProvider metadata is available for your sync folder. If all values show `-`, the folder may be using traditional sync instead of FileProvider.

## License

MIT
