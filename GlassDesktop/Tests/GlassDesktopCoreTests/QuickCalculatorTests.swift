import GlassDesktopCore
import XCTest

final class QuickCalculatorTests: XCTestCase {
    func testRespectsOperatorPrecedenceAndParentheses() {
        XCTAssertEqual(QuickCalculator.evaluate("2 + 3 * 4")?.value, 14)
        XCTAssertEqual(QuickCalculator.evaluate("(2 + 3) * 4")?.value, 20)
    }

    func testSupportsDecimalsUnarySignsAndWhitespace() {
        XCTAssertEqual(QuickCalculator.evaluate(" -2.5 * ( 4 + 2 ) ")?.value, -15)
        XCTAssertEqual(QuickCalculator.evaluate("8 / 2 / 2")?.value, 2)
    }

    func testRejectsInvalidUnsafeAndNonFiniteExpressions() {
        XCTAssertNil(QuickCalculator.evaluate("hello + 2"))
        XCTAssertNil(QuickCalculator.evaluate("1 / 0"))
        XCTAssertNil(QuickCalculator.evaluate("2 +"))
        XCTAssertNil(QuickCalculator.evaluate("2 ^ 8"))
        XCTAssertNil(QuickCalculator.evaluate("999999999999999999999999999999999999999999999999999999 * 999999999999999999999999999999999999999999999999999999"))
    }

    func testRequiresAnArithmeticOperator() {
        XCTAssertNil(QuickCalculator.evaluate("123"))
        XCTAssertNotNil(QuickCalculator.evaluate("123 + 0"))
    }
}
