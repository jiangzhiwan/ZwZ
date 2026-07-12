import Foundation

public enum ArchiveEntryPresentation {
    public static func displaySize(for entry: ArchiveEntry, in entries: [ArchiveEntry]) -> Int64 {
        guard entry.isDirectory else { return entry.size }

        let directoryPath = normalizedDirectoryPath(entry.path)
        return entries.reduce(Int64(0)) { total, candidate in
            guard !candidate.isDirectory else { return total }
            let candidatePath = normalizedPath(candidate.path)
            return candidatePath.hasPrefix(directoryPath) ? total + candidate.size : total
        }
    }

    public static func iconName(forFileNamed name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder.fill" }

        switch fileExtension(from: name) {
        case "zip", "zwz", "rar", "7z", "gz", "tgz", "tar":
            return "doc.zipper"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp":
            return "photo.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "txt", "md", "rtf", "log", "json", "xml", "yaml", "yml", "csv":
            return "doc.text.fill"
        case "swift", "js", "ts", "html", "css", "py", "java", "c", "cpp", "h", "hpp", "sh":
            return "curlybraces.square.fill"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "mp4", "mov", "avi", "mkv", "webm":
            return "film.fill"
        default:
            return "doc.fill"
        }
    }

    public static func isHidden(path: String) -> Bool {
        normalizedPath(path)
            .split(separator: "/")
            .contains { part in
                part.hasPrefix(".") && part != "." && part != ".."
            }
    }

    private static func normalizedPath(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        let normalized = normalizedPath(path)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    private static func fileExtension(from name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}
