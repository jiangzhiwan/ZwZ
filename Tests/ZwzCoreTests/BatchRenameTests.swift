import XCTest
@testable import ZwzCore

final class BatchRenameTests: XCTestCase {

    // MARK: - Find & Replace

    func testFindReplaceBasic() throws {
        let entries = [("photo1.jpg", false), ("photo2.jpg", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "photo", replace: "img"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "img1.jpg")
        XCTAssertEqual(result[1].finalName, "img2.jpg")
        XCTAssertFalse(result[0].hasConflict)
    }

    func testFindReplaceMultipleMatches() throws {
        let entries = [("foo_foo_foo.txt", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "foo", replace: "bar"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "bar_bar_bar.txt")
    }

    func testFindReplaceEmptyReplaceDeletesText() throws {
        let entries = [("photo123.jpg", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "123", replace: ""))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "photo.jpg")
    }

    func testFindReplaceNoMatch() throws {
        let entries = [("photo.jpg", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "xyz", replace: "abc"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "photo.jpg")
    }

    func testFindReplaceEmptyFindKeepsOriginal() throws {
        let entries = [("hello.txt", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "", replace: "x"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "hello.txt")
    }

    // MARK: - Prefix/Suffix

    func testPrefixOnly() throws {
        let entries = [("doc.txt", false)]
        let config = BatchRenameConfig(rule: .prefixSuffix(prefix: "pre_", suffix: ""))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "pre_doc.txt")
    }

    func testSuffixOnly() throws {
        let entries = [("doc.txt", false)]
        let config = BatchRenameConfig(rule: .prefixSuffix(prefix: "", suffix: "_post"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "doc_post.txt")
    }

    func testPrefixAndSuffix() throws {
        let entries = [("doc.txt", false)]
        let config = BatchRenameConfig(rule: .prefixSuffix(prefix: "pre_", suffix: "_post"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "pre_doc_post.txt")
    }

    func testPrefixSuffixEmptyValues() throws {
        let entries = [("doc.txt", false)]
        let config = BatchRenameConfig(rule: .prefixSuffix(prefix: "", suffix: ""))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "doc.txt")
    }

    // MARK: - Numbering (Simple)

    func testNumberingSimpleDefault() throws {
        let entries = [("a.txt", false), ("b.txt", false), ("c.txt", false)]
        let config = BatchRenameConfig(rule: .numbering(mode: .simple(start: 1, step: 1, digits: 3, prefix: "file_")))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "file_001.txt")
        XCTAssertEqual(result[1].finalName, "file_002.txt")
        XCTAssertEqual(result[2].finalName, "file_003.txt")
    }

    func testNumberingSimpleStart10Step2() throws {
        let entries = [("a.txt", false), ("b.txt", false), ("c.txt", false)]
        let config = BatchRenameConfig(rule: .numbering(mode: .simple(start: 10, step: 2, digits: 3, prefix: "")))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "010.txt")
        XCTAssertEqual(result[1].finalName, "012.txt")
        XCTAssertEqual(result[2].finalName, "014.txt")
    }

    func testNumberingSimpleZeroDigits() throws {
        let entries = [("a.txt", false), ("b.txt", false)]
        let config = BatchRenameConfig(rule: .numbering(mode: .simple(start: 1, step: 1, digits: 0, prefix: "item")))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "item1.txt")
        XCTAssertEqual(result[1].finalName, "item2.txt")
    }

    // MARK: - Numbering (Template)

    func testNumberingTemplateSeqWithDigits() throws {
        let entries = [("a.txt", false), ("b.txt", false)]
        let config = BatchRenameConfig(rule: .numbering(mode: .template(template: "img_{seq:2}_x", start: 1, step: 1)))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "img_01_x.txt")
        XCTAssertEqual(result[1].finalName, "img_02_x.txt")
    }

    func testNumberingTemplateSeqNoPad() throws {
        let entries = [("a.txt", false), ("b.txt", false)]
        let config = BatchRenameConfig(rule: .numbering(mode: .template(template: "item{seq}", start: 5, step: 5)))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "item5.txt")
        XCTAssertEqual(result[1].finalName, "item10.txt")
    }

    // MARK: - Regex Replace

    func testRegexReplaceBasic() throws {
        let entries = [("file123.txt", false), ("data456.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "\\d+", template: "NUM"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "fileNUM.txt")
        XCTAssertEqual(result[1].finalName, "dataNUM.txt")
    }

    func testRegexReplaceGroupReference() throws {
        let entries = [("2024_report.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "(\\d+)_(\\w+)", template: "$2_$1"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "report_2024.txt")
    }

    func testRegexReplaceNoMatch() throws {
        let entries = [("hello.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "\\d+", template: "NUM"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "hello.txt")
    }

    func testRegexReplaceInvalidPatternThrows() {
        let entries = [("test.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "[invalid", template: "x"))
        XCTAssertThrowsError(try BatchRenameEngine.compute(entries: entries, config: config)) { error in
            guard case BatchRenameError.invalidRegex = error else {
                XCTFail("Expected invalidRegex error, got: \(error)")
                return
            }
        }
    }

    func testRegexReplaceEmptyPatternKeepsOriginal() throws {
        let entries = [("test.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "", template: "x"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "test.txt")
    }

    // MARK: - Case Conversion

    func testCaseUpper() throws {
        let entries = [("Hello.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .upper))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "HELLO.txt")
    }

    func testCaseLower() throws {
        let entries = [("HeLLo.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .lower))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "hello.txt")
    }

    func testTitleCase() throws {
        let entries = [("hello world.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .titleCase))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "Hello World.txt")
    }

    func testCamelCase() throws {
        let entries = [("hello world.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .camelCase))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "helloWorld.txt")
    }

    func testSnakeCase() throws {
        let entries = [("HelloWorld.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .snakeCase))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "hello_world.txt")
    }

    // MARK: - Extension Handling

    func testExtensionPreservedByDefault() throws {
        let entries = [("photo.jpg", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "photo", replace: "image"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "image.jpg")
    }

    func testIncludeExtensionTrue() throws {
        let entries = [("photo.jpg", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: ".jpg", replace: ".png"), includeExtension: true)
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "photo.png")
    }

    // MARK: - Double Extension

    func testDoubleExtensionTarGz() throws {
        let entries = [("archive.tar.gz", false)]
        let config = BatchRenameConfig(rule: .prefixSuffix(prefix: "backup_", suffix: ""))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "backup_archive.tar.gz")
    }

    func testDoubleExtensionTarBz2() throws {
        let entries = [("data.tar.bz2", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .upper))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        // base "data" → "DATA", ext "tar.bz2" preserved
        XCTAssertEqual(result[0].finalName, "DATA.tar.bz2")
    }

    func testDoubleExtensionTarXz() throws {
        let (base, ext) = BatchRenameEngine.splitNameAndExtension("archive.tar.xz")
        XCTAssertEqual(base, "archive")
        XCTAssertEqual(ext, "tar.xz")
    }

    func testHiddenFileNoExtension() throws {
        let (base, ext) = BatchRenameEngine.splitNameAndExtension(".gitignore")
        XCTAssertEqual(base, ".gitignore")
        XCTAssertEqual(ext, "")
    }

    func testNoExtension() throws {
        let (base, ext) = BatchRenameEngine.splitNameAndExtension("Makefile")
        XCTAssertEqual(base, "Makefile")
        XCTAssertEqual(ext, "")
    }

    // MARK: - Conflict Detection

    func testNoConflictWhenAllUnique() throws {
        let entries = [("a.txt", false), ("b.txt", false), ("c.txt", false)]
        let config = BatchRenameConfig(rule: .prefixSuffix(prefix: "x_", suffix: ""))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result.map(\.finalName), ["x_a.txt", "x_b.txt", "x_c.txt"])
        XCTAssertFalse(result.contains { $0.hasConflict })
    }

    func testConflictAutoNumbering() throws {
        // Use regex to replace entire base name with "same", creating conflict
        let entries = [("cat.txt", false), ("dog.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "^[^.]+", template: "same"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "same.txt")
        XCTAssertEqual(result[1].finalName, "same_2.txt")
        XCTAssertFalse(result[0].hasConflict)
        XCTAssertTrue(result[1].hasConflict)
    }

    func testConflictThreeDuplicates() throws {
        let entries = [("a.txt", false), ("b.txt", false), ("c.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "^[^.]+", template: "same"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "same.txt")
        XCTAssertEqual(result[1].finalName, "same_2.txt")
        XCTAssertEqual(result[2].finalName, "same_3.txt")
    }

    func testConflictWithExistingNames() throws {
        let entries = [("new.txt", false)]
        let config = BatchRenameConfig(rule: .findReplace(find: "new", replace: "existing"))
        let existing: Set<String> = ["existing.txt"]
        let result = try BatchRenameEngine.compute(entries: entries, config: config, existingNames: existing)
        XCTAssertEqual(result[0].finalName, "existing_2.txt")
        XCTAssertTrue(result[0].hasConflict)
    }

    func testConflictRenamesWithDoubleExtension() throws {
        let entries = [("a.tar.gz", false), ("b.tar.gz", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "^[^.]+", template: "same"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "same.tar.gz")
        XCTAssertEqual(result[1].finalName, "same_2.tar.gz")
    }

    // MARK: - Directory Support

    func testDirectoryRenamed() throws {
        let entries = [("mydir", true)]
        let config = BatchRenameConfig(rule: .findReplace(find: "my", replace: "our"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "ourdir")
        XCTAssertTrue(result[0].isDirectory)
    }

    func testNumberingIncludesDirectories() throws {
        let entries = [("file.txt", false), ("folder", true), ("data.txt", false)]
        let config = BatchRenameConfig(rule: .numbering(mode: .simple(start: 1, step: 1, digits: 2, prefix: "item_")))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "item_01.txt")
        XCTAssertEqual(result[1].finalName, "item_02")  // directory, no extension
        XCTAssertEqual(result[2].finalName, "item_03.txt")
    }

    // MARK: - Edge Cases

    func testEmptyEntriesReturnsEmpty() throws {
        let result = try BatchRenameEngine.compute(entries: [], config: BatchRenameConfig(rule: .findReplace(find: "a", replace: "b")))
        XCTAssertTrue(result.isEmpty)
    }

    func testApplyRuleSingleNoConflict() throws {
        let name = try BatchRenameEngine.applyRule(
            to: "test.txt", isDirectory: false,
            rule: .findReplace(find: "test", replace: "demo"),
            includeExtension: false, index: 0
        )
        XCTAssertEqual(name, "demo.txt")
    }

    func testApplyRuleIncludeExtension() throws {
        let name = try BatchRenameEngine.applyRule(
            to: "test.txt", isDirectory: false,
            rule: .caseConversion(mode: .upper),
            includeExtension: true, index: 0
        )
        XCTAssertEqual(name, "TEST.TXT")
    }

    // MARK: - Snake Case Edge Cases

    func testSnakeCaseFromCamelCase() throws {
        let entries = [("myVariableName.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .snakeCase))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "my_variable_name.txt")
    }

    func testCamelCaseFromSnakeCase() throws {
        let entries = [("my_variable_name.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .camelCase))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "myVariableName.txt")
    }

    func testTitleCaseWithDashes() throws {
        let entries = [("hello-world.txt", false)]
        let config = BatchRenameConfig(rule: .caseConversion(mode: .titleCase))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].finalName, "Hello-World.txt")
    }

    // MARK: - computedName vs finalName

    func testComputedNameDiffersFromFinalNameOnConflict() throws {
        let entries = [("a.txt", false), ("b.txt", false)]
        let config = BatchRenameConfig(rule: .regexReplace(pattern: "^[^.]+", template: "same"))
        let result = try BatchRenameEngine.compute(entries: entries, config: config)
        XCTAssertEqual(result[0].computedName, "same.txt")
        XCTAssertEqual(result[0].finalName, "same.txt")
        XCTAssertEqual(result[1].computedName, "same.txt")  // computed is same
        XCTAssertEqual(result[1].finalName, "same_2.txt")  // final has conflict resolution
    }
}

// MARK: - Test Helpers

private extension CaseMode {
    func toCaseRule() -> BatchRenameRule {
        .caseConversion(mode: self)
    }
}
