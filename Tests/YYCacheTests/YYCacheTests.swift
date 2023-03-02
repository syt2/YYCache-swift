import XCTest
@testable import YYCache

final class YYCacheTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        let cache = Cache(name: "Test")
        cache?.set(key: "xxx", value: "yyy")
        XCTAssertEqual(cache?.memoryCache["xxx"] as? String, "yyy")
        XCTAssertEqual(cache?.diskCache.get(type: String.self, key: "xxx"), "yyy")
        
        XCTAssertEqual(cache?.get(type: String.self, key: "xxx"), "yyy")
    }
}
