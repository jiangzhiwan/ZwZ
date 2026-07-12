# ZwZ

ZwZ is a Swift Package Manager compression and extraction application with a macOS GUI, a command-line tool, and a shared `ZwzCore` library.

## ZWZ format compatibility

The current application writes and reads ZWZ v2 archives only. ZWZ v1 archives are intentionally unsupported and return a clear unsupported-version error; recompress the original files with the current application to migrate them.

Password-protected ZWZ v2 archives encrypt and authenticate both file data and the archive index with AES-256-GCM. File names, paths, sizes, timestamps, directory structure, and codec metadata remain hidden until the correct password is supplied.

ZWZ v2 supports independently compressed blocks, multithreaded compression and extraction, split volumes, fast index-based preview, individual entry extraction, hidden files, and strict or recovery extraction policies.

## Build and test

```bash
swift build
swift test
```

Run the CLI with:

```bash
swift run zwz help
```
