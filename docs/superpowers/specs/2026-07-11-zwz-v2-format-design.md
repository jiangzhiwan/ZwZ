# ZWZ v2 Format Design

## 1. Objective

ZWZ v2 replaces the current format without backward compatibility. The new format prioritizes a balanced combination of compression ratio, throughput, and bounded memory use. It must support macOS and Windows, archives larger than 1 TB, fast preview, independent file extraction, multithreaded compression and extraction, password encryption, split volumes, hidden files, and corruption recovery.

Old ZWZ archives are intentionally unsupported. The application must identify them and report a clear unsupported-version error instead of attempting best-effort parsing.

## 2. Constraints

- Compression and encryption dependencies must be implemented entirely in Swift.
- Existing LZ4 and Deflate implementations from SWCompression may be reused.
- A mature pure Swift cryptography package may be added for AES-256-GCM, PBKDF2-HMAC-SHA256, and required primitives.
- The archive stores paths, directories, modification times, and hidden files.
- Symbolic links, permissions, extended attributes, and macOS resource forks are not archived.
- Memory use must be bounded by configured block and queue sizes, not input size.
- Preview and individual extraction must not require scanning or decompressing unrelated file data.

## 3. Container Layout

A non-split archive is one logical byte stream:

1. Fixed-size main header.
2. Independently encoded data block records.
3. Index payload, encrypted when a password is enabled.
4. Fixed-size footer locating and authenticating the index.

The header includes the v2 magic and version, feature flags, archive identifier, block-size policy, index-encryption metadata, password-derivation parameters, and reserved extension space. Integer fields use little-endian fixed-width encoding. Variable-length records use explicit lengths and reject overflow, truncation, impossible counts, and unsupported flags.

The footer repeats the archive identifier, index location and length, index integrity data, and format version. Readers validate agreement between the header and footer before trusting offsets.

## 4. Entry Model

The index describes explicit directory and regular-file entries. Each entry contains:

- normalized UTF-8 relative path;
- entry type;
- original byte size;
- modification timestamp;
- ordered block descriptors for regular files.

Each block descriptor contains:

- global block sequence number;
- logical file offset;
- physical archive offset;
- stored and original lengths;
- codec identifier: store, LZ4, or Deflate;
- fast corruption checksum;
- encryption nonce derivation input and authentication tag when encrypted.

Paths must not be absolute, contain parent traversal, contain NUL, escape the destination after normalization, or conflict by mapping multiple entries to the same output path. Platform-specific path conflicts are reported before extraction.

## 5. Adaptive Block Compression

Regular files are read as independent bounded blocks. The default block size is 4 MiB and is recorded in the archive. The implementation may reduce block size for memory pressure, but readers rely only on the lengths recorded per block.

Compression levels map to policies:

- `none`: store blocks without compression.
- `fastest`: prefer LZ4 with minimal analysis; store output when compression is not beneficial.
- `normal`: sample each block and choose among LZ4, Deflate, and store. Deflate is favored for highly compressible data, LZ4 for moderate compressibility, and store for already-compressed or incompressible data.
- `max`: prefer Deflate; store a block when Deflate does not reduce its size enough to cover record overhead.

The exact sampling thresholds are implementation constants covered by benchmark and regression tests. They do not affect reader compatibility because every block records its selected codec.

## 6. Streaming and Multithreading

Compression uses a bounded pipeline:

1. One producer enumerates entries and reads numbered blocks.
2. A bounded worker pool analyzes, compresses, checksums, and encrypts blocks concurrently.
3. One ordered writer emits completed records by sequence number and builds index descriptors.

Extraction reads and validates the index first, schedules only requested entries, and processes block reads, authentication, decryption, decompression, and checksums concurrently. Blocks are written at their declared file offsets. A file is finalized only after all its blocks pass the selected recovery policy.

Automatic concurrency considers active processors and a memory budget. Manual thread-count settings remain supported. Queue capacity is derived from the memory budget so increasing thread count cannot create unbounded buffering. The design supports both one huge file and many small files without loading a complete file into memory.

## 7. Encryption and Privacy

Password-protected archives use AES-256-GCM. A key is derived with PBKDF2-HMAC-SHA256 from a random per-archive salt. The header stores the KDF identifier and work factor so security parameters can evolve without changing the container version.

Every data block is independently authenticated and encrypted with a unique nonce derived from the archive identity and block sequence under a defined domain. The encrypted index uses a separate nonce domain. Nonce uniqueness is enforced before writing.

The encrypted index hides paths, names, entry counts, file sizes, timestamps, directory structure, block locations, and codecs. Without a password, readers expose only unavoidable container information such as version, encryption/KDF parameters, split-volume metadata, and total archive size.

Authentication failure never produces plaintext output, including in recovery mode. Wrong-password and damaged-data errors are distinguished only when the authenticated metadata permits doing so without weakening verification.

## 8. Split Volumes

Split archives represent the same logical archive stream without first creating a complete temporary archive. Each volume has a small envelope containing:

- split-volume magic and envelope version;
- archive identifier;
- zero-based volume number;
- final-volume marker when known;
- logical byte range;
- payload length and checksum.

The writer rotates volumes at the requested size while streaming. A block may span volumes; the logical reader abstracts this boundary. Preview requires the first and final volumes because the header and footer/index locator live at opposite ends. Individual extraction requests only volumes intersecting the required block ranges plus volumes containing metadata.

Missing, duplicated, reordered, mixed-archive, and checksum-invalid volumes are rejected with specific errors.

## 9. Integrity and Recovery

Strict mode is the default. It stops on missing volumes, malformed metadata, authentication failure, decompression failure, checksum mismatch, or unsafe output paths. It removes unfinished temporary outputs before returning an error.

Recovery mode continues with independent valid entries and blocks. It never bypasses format bounds, path safety, cryptographic authentication, or checksum checks. Complete files retain their names. Files with missing or invalid blocks are written only under an explicit partial-recovery suffix and are listed in a machine-readable and user-readable recovery report. Failed blocks are never silently replaced with valid-looking content.

## 10. Application Integration

The existing GUI and core API retain:

- compression levels;
- automatic and manual thread selection;
- password protection;
- split-volume selection;
- archive preview and individual extraction;
- hidden-file preview settings.

The extractor adds strict and recovery policies, defaulting to strict. Encrypted archive preview requests a password before returning any entries. Old v1 archives return a localized unsupported-version message.

The core implementation is separated into format codec, logical volume I/O, block codec selection, cryptography, compression pipeline, extraction pipeline, index model, path validation, and recovery reporting. These units communicate through typed interfaces and can be tested independently.

## 11. Validation

Round-trip tests cover empty files, hidden files, explicit empty directories, deep trees, Unicode and long paths, incompressible data, mixed content, files spanning many blocks, and data spanning volumes.

Concurrency tests cover deterministic ordering, automatic and manual thread counts, a single huge file, many small files, bounded queues, cancellation, and error propagation.

Security tests cover encrypted index privacy, correct and wrong passwords, modified header/index/block/tag data, nonce uniqueness, path traversal, absolute paths, duplicate paths, truncation, oversized lengths, and malformed counts.

Recovery tests cover isolated corrupt blocks, damaged files among valid files, missing volumes, strict cleanup, partial-file naming, and complete recovery reports.

Performance tests compare the new implementation across representative text, source, document, media, random, large-file, and many-small-file datasets. Acceptance is qualitative rather than a fixed percentage: processing must show stable bounded memory, reliable progress, and materially improved stability and responsiveness over v1. Benchmark results determine future threshold tuning without changing the format.

## 12. Explicit Non-Goals

- Reading or writing ZWZ v1.
- Solid compression across unrelated files.
- Deduplication between files or blocks.
- In-place archive mutation or append-only updates.
- Symbolic links, permissions, extended attributes, or resource forks.
- Unauthenticated encryption or extraction of unauthenticated plaintext.
