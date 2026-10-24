// Minimal XCTest stand-in so the Foundation-only unit tests run on a Mac with just the Command Line Tools
// (no Xcode). CI runs the same files against the real XCTest. See scripts/core-tests.sh.
@_exported import Foundation

open class XCTestCase: NSObject {
    public override required init() { super.init() }
}

public struct XCTShimFailure: Error, CustomStringConvertible {
    public let description: String
}

public enum XCTShim {
    nonisolated(unsafe) public static var failures: [String] = []
    public static func record(_ message: String, _ file: StaticString, _ line: UInt) {
        failures.append("\(("\(file)" as NSString).lastPathComponent):\(line): \(message)")
    }
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTShim.record("XCTFail \(message)", file, line)
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if x != y { XCTShim.record("XCTAssertEqual failed: (\(x)) != (\(y)) \(message())", file, line) }
    } catch { XCTShim.record("XCTAssertEqual threw \(error)", file, line) }
}

public func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if let v = try a() { XCTShim.record("XCTAssertNil failed: \(v) \(message())", file, line) } }
    catch { XCTShim.record("XCTAssertNil threw \(error)", file, line) }
}

public func XCTAssertNotNil<T>(_ a: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() == nil { XCTShim.record("XCTAssertNotNil failed \(message())", file, line) } }
    catch { XCTShim.record("XCTAssertNotNil threw \(error)", file, line) }
}

public func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if !(try a()) { XCTShim.record("XCTAssertTrue failed \(message())", file, line) } }
    catch { XCTShim.record("XCTAssertTrue threw \(error)", file, line) }
}

public func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() { XCTShim.record("XCTAssertFalse failed \(message())", file, line) } }
    catch { XCTShim.record("XCTAssertFalse threw \(error)", file, line) }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x > y) { XCTShim.record("XCTAssertGreaterThan failed: \(x) <= \(y) \(message())", file, line) }
    } catch { XCTShim.record("XCTAssertGreaterThan threw \(error)", file, line) }
}

public func XCTUnwrap<T>(_ a: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try a() else {
        XCTShim.record("XCTUnwrap failed \(message())", file, line)
        throw XCTShimFailure(description: "XCTUnwrap failed \(message())")
    }
    return value
}
