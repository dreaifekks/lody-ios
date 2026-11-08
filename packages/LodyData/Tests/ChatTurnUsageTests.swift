import XCTest
@testable import LodyData

final class ChatTurnUsageTests: XCTestCase {
  private let tokens: [String: Any] = ["inputTokens": 12, "outputTokens": 3, "reasoningOutputTokens": 0,
    "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0]
  private func usage(_ cost: Any? = nil) throws -> ChatTurnUsage {
    var raw = tokens
    raw["costUSD"] = cost
    return try JSONDecoder().decode(ChatTurnUsage.self, from: JSONSerialization.data(withJSONObject: raw))
  }

  func testMissingNullAndInvalidCostNeverDiscardValidTokens() throws {
    var values: [Any?] = [nil, NSNull(), -1, true, "1", ["amount": 1]]
    values.append([1, 2])
    for value in values {
      let result = try usage(value)
      XCTAssertNil(result.costUSD)
      XCTAssertEqual(result.values?["inputTokens"], 12)
      XCTAssertEqual(result.values?["outputTokens"], 3)
    }
  }

  func testZeroAndFractionalCostAreNotRequiredIntegerKeys() throws {
    for cost in [0.0, 0.00000001, 0.0099, 0.123456, 1.234, 120.75] {
      let result = try usage(cost)
      XCTAssertEqual(result.costUSD, cost)
      XCTAssertEqual(result.values?.count, 5)
      XCTAssertNil(result.values?["costUSD"])
    }
    var raw = tokens
    raw["costUSD"] = 0.25
    raw["inputTokens"] = 1.5
    XCTAssertNil(try JSONDecoder().decode(ChatTurnUsage.self, from: JSONSerialization.data(withJSONObject: raw)).values)
  }

  func testNonFiniteProviderCostIsAbsentWhileTokensRemain() throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    for value in ["Infinity", "-Infinity", "NaN"] {
      var raw = tokens; raw["costUSD"] = value
      let result = try decoder.decode(ChatTurnUsage.self, from: JSONSerialization.data(withJSONObject: raw))
      XCTAssertNil(result.costUSD)
      XCTAssertEqual(result.values?["inputTokens"], 12)
    }
  }
}
