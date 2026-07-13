import XCTest

final class CompressionOptionsLayoutTests: XCTestCase {
    func testArchiveEditorRowsSelectOnSingleClickAndRetainDoubleClickOpening() throws {
        let source = try guiSource()
        let editor = try XCTUnwrap(source.slice(
            from: "struct ZWZArchiveEditorView: View",
            to: "struct ZWZArchiveTextEditor: View"
        ))

        XCTAssertTrue(
            editor.contains(".onTapGesture {\n                        selectedPath = entry.path\n                    }\n                    .onTapGesture(count: 2)"),
            "Editor rows must explicitly select on a single click before handling double-click opening."
        )
    }

    func testCompressionOptionsSectionsUseOneLeadingEdgeAndHideDuplicatePickerLabels() throws {
        let source = try guiSource()

        let compressView = try XCTUnwrap(source.slice(from: "struct ZWZCompressOptionsView: View", to: "// MARK: - Extract Options Sheet"))
        XCTAssertEqual(
            compressView.components(separatedBy: ".labelsHidden()\n                .pickerStyle(.segmented)").count - 1,
            3,
            "The three segmented pickers must hide labels already displayed by their sections."
        )

        let section = try XCTUnwrap(source.slice(from: "struct ZWZSheetSection<Content: View>: View", to: "// MARK: - Sheet Button Style"))
        XCTAssertTrue(
            section.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "Every sheet section must expand to the same leading edge."
        )
    }

    private func guiSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZwzGUI/ZwzApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard
            let startRange = range(of: start),
            let endRange = range(of: end, range: startRange.upperBound..<endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
