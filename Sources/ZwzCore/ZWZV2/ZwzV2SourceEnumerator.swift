import Foundation

public struct ZwzV2SourceItem: Equatable, Sendable {
    public var url: URL
    public var archivePath: String
    public var type: ZwzV2EntryType
    public var size: UInt64
    public var modificationTime: Date
    public var isHidden: Bool

    public init(
        url: URL,
        archivePath: String,
        type: ZwzV2EntryType,
        size: UInt64,
        modificationTime: Date,
        isHidden: Bool
    ) {
        self.url = url
        self.archivePath = archivePath
        self.type = type
        self.size = size
        self.modificationTime = modificationTime
        self.isHidden = isHidden
    }
}

public struct ZwzV2SourceEnumerator {
    public init() {}

    public func enumerate(root: URL) throws -> [ZwzV2SourceItem] {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ZwzV2Error.unsafePath(root.path)
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw ZwzV2Error.unsafePath(root.path)
        }

        var items: [ZwzV2SourceItem] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let type: ZwzV2EntryType = values.isDirectory == true ? .directory : .file
            let size = UInt64(max(0, values.fileSize ?? 0))
            let isHidden = values.isHidden == true || url.lastPathComponent.hasPrefix(".")
            items.append(
                ZwzV2SourceItem(
                    url: url,
                    archivePath: try ZwzV2PathValidator.normalizedArchivePath(root: root, item: url),
                    type: type,
                    size: size,
                    modificationTime: values.contentModificationDate ?? .distantPast,
                    isHidden: isHidden
                )
            )
        }

        return items.sorted { $0.archivePath < $1.archivePath }
    }
}
