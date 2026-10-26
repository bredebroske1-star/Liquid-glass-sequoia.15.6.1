import Foundation

public struct Calculation: Equatable, Sendable {
    public let expression: String
    public let value: Double

    public var formattedValue: String {
        value.formatted(.number.precision(.significantDigits(1...10)).grouping(.never))
    }

    public init(expression: String, value: Double) {
        self.expression = expression
        self.value = value
    }
}

public enum QuickCalculator {
    public static func evaluate(_ expression: String) -> Calculation? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120,
              trimmed.contains(where: { "+-*/".contains($0) }),
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789.+-*/() \t").contains($0)
              })
        else {
            return nil
        }

        var parser = ExpressionParser(Array(trimmed))
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Calculation(expression: trimmed, value: value)
    }
}

private struct ExpressionParser {
    private let characters: [Character]
    private var index = 0

    init(_ characters: [Character]) {
        self.characters = characters
    }

    mutating func parse() -> Double? {
        guard let value = parseAddition(), skipWhitespace(), index == characters.count else { return nil }
        return value
    }

    private mutating func parseAddition() -> Double? {
        guard var value = parseMultiplication() else { return nil }

        while true {
            skipWhitespace()
            if consume("+") {
                guard let rhs = parseMultiplication() else { return nil }
                value += rhs
            } else if consume("-") {
                guard let rhs = parseMultiplication() else { return nil }
                value -= rhs
            } else {
                return value
            }
        }
    }

    private mutating func parseMultiplication() -> Double? {
        guard var value = parseUnary() else { return nil }

        while true {
            skipWhitespace()
            if consume("*") {
                guard let rhs = parseUnary() else { return nil }
                value *= rhs
            } else if consume("/") {
                guard let rhs = parseUnary(), rhs != 0 else { return nil }
                value /= rhs
            } else {
                return value
            }
        }
    }

    private mutating func parseUnary() -> Double? {
        skipWhitespace()
        if consume("+") { return parseUnary() }
        if consume("-"), let value = parseUnary() { return -value }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Double? {
        skipWhitespace()
        if consume("(") {
            guard let value = parseAddition() else { return nil }
            skipWhitespace()
            guard consume(")") else { return nil }
            return value
        }

        let start = index
        var hasDigit = false
        var hasDecimalPoint = false

        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                hasDigit = true
                index += 1
            } else if character == ".", !hasDecimalPoint {
                hasDecimalPoint = true
                index += 1
            } else {
                break
            }
        }

        guard hasDigit, let value = Double(String(characters[start..<index])) else { return nil }
        return value
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    @discardableResult
    private mutating func skipWhitespace() -> Bool {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        return true
    }
}
