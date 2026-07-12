import XCTest
import ZwzCore
@testable import ZwzGUI

final class ArchiveEntryHierarchyTests: XCTestCase {
    func testRootProjectionSynthesizesDirectoriesAndPreservesSourceOrder() {
        let entries = [
            entry(name: "first.txt", path: "first.txt"),
            entry(name: "nested.txt", path: "Docs/Nested/nested.txt"),
            entry(name: "middle.txt", path: "middle.txt"),
            entry(name: "Docs", path: "Docs/", isDirectory: true),
            entry(name: "image.png", path: "Images/image.png"),
        ]

        let children = ArchiveEntryHierarchy.immediateChildren(
            of: entries,
            in: "",
            showHiddenFiles: true
        )

        XCTAssertEqual(children.map(\.path), ["first.txt", "Docs/", "middle.txt", "Images/"])
        XCTAssertEqual(children.map(\.isDirectory), [false, true, false, true])
        XCTAssertEqual(children[1].id, entries[3].id, "An explicit directory should be reused even when listed later")
    }

    func testNestedProjectionAcceptsNormalizedDirectoryVariants() {
        let entries = [
            entry(name: "guide.txt", path: "./Docs/guide.txt"),
            entry(name: "photo.jpg", path: "Docs/Media/photo.jpg"),
            entry(name: "root.txt", path: "root.txt"),
        ]

        let children = ArchiveEntryHierarchy.immediateChildren(
            of: entries,
            in: "/./Docs//",
            showHiddenFiles: true
        )

        XCTAssertEqual(children.map(\.name), ["guide.txt", "Media"])
        XCTAssertEqual(children.map(\.path), ["./Docs/guide.txt", "Docs/Media/"])
    }

    func testProjectionRespectsHiddenFilesAcrossAllPathComponents() {
        let entries = [
            entry(name: ".env", path: ".env"),
            entry(name: "visible.txt", path: "Project/visible.txt"),
            entry(name: "secret.txt", path: "Project/.private/secret.txt"),
            entry(name: "config", path: ".config/settings.json"),
        ]

        let visibleRoot = ArchiveEntryHierarchy.immediateChildren(
            of: entries,
            in: "",
            showHiddenFiles: false
        )
        let allRoot = ArchiveEntryHierarchy.immediateChildren(
            of: entries,
            in: "",
            showHiddenFiles: true
        )
        let visibleProject = ArchiveEntryHierarchy.immediateChildren(
            of: entries,
            in: "Project/",
            showHiddenFiles: false
        )

        XCTAssertEqual(visibleRoot.map(\.path), ["Project/"])
        XCTAssertEqual(allRoot.map(\.path), [".env", "Project/", ".config/"])
        XCTAssertEqual(visibleProject.map(\.path), ["Project/visible.txt"])
    }

    func testNormalizedDirectoryPathCanonicalizesRootAndSeparators() {
        XCTAssertEqual(ArchiveEntryHierarchy.normalizedDirectoryPath(""), "")
        XCTAssertEqual(ArchiveEntryHierarchy.normalizedDirectoryPath("./"), "")
        XCTAssertEqual(ArchiveEntryHierarchy.normalizedDirectoryPath("/"), "")
        XCTAssertEqual(ArchiveEntryHierarchy.normalizedDirectoryPath("Docs"), "Docs/")
        XCTAssertEqual(ArchiveEntryHierarchy.normalizedDirectoryPath("./Docs//Nested/"), "Docs/Nested/")
    }

    func testBreadcrumbPartsContainNormalizedAccumulatedPaths() {
        let parts = ArchiveEntryHierarchy.breadcrumbParts(
            for: "./Docs//Nested/",
            rootName: "Root"
        )

        XCTAssertEqual(parts.map(\.name), ["Root", "Docs", "Nested"])
        XCTAssertEqual(parts.map(\.path), ["", "Docs/", "Docs/Nested/"])
        XCTAssertEqual(parts.map(\.id), parts.map(\.path))
    }

    private func entry(
        name: String,
        path: String,
        isDirectory: Bool = false
    ) -> ArchiveEntry {
        ArchiveEntry(
            name: name,
            path: path,
            size: isDirectory ? 0 : 1,
            isDirectory: isDirectory,
            modifiedDate: nil
        )
    }
}
