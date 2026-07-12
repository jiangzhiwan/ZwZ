import Foundation
import ZwzCore

let previewer = ArchivePreviewer()
let entries = try previewer.preview(archivePath: "/tmp/zwz-chinese-test.zip")
for e in entries {
    print("name=[\(e.name)] path=[\(e.path)] isDir=\(e.isDirectory)")
}
