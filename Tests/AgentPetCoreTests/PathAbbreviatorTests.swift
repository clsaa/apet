import XCTest
@testable import AgentPetCore

final class PathAbbreviatorTests: XCTestCase {
    func test_homePrefix_toTilde() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/Users/n/workspace/apet", home: "/Users/n"), "~/workspace/apet")
    }
    func test_nonHome_unchanged_ifShort() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/opt/x", home: "/Users/n"), "/opt/x")
    }
    func test_tooLong_collapsesToParentLeaf() {
        let long = "/Users/n/a/b/c/d/e/f/g/really-long-project-name-here"
        let out = PathAbbreviator.abbreviate(long, home: "/Users/n", maxLen: 24)
        XCTAssertTrue(out.hasPrefix("…/"), out)
        XCTAssertTrue(out.hasSuffix("really-long-project-name-here"), out)
    }
    func test_empty_returnsEmpty() {
        XCTAssertEqual(PathAbbreviator.abbreviate("", home: "/Users/n"), "")
    }
    func test_homeExactly_toTilde() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/Users/n", home: "/Users/n"), "~")
    }

    func test_homeIsPrefixButNotDirBoundary_notAbbreviated() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/Users/nab", home: "/Users/n"), "/Users/nab")
    }
    func test_homeExactPrefixWord_notAbbreviated() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/Users/nathan", home: "/Users/nat"), "/Users/nathan")
    }
    func test_windowsStyle_noForwardSlash_asIsIfShort() {
        XCTAssertEqual(PathAbbreviator.abbreviate(#"C:\Users\n\proj"#, home: "/Users/n"), #"C:\Users\n\proj"#)
    }
}
