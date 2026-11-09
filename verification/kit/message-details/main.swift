import Foundation

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T { try! JSONDecoder().decode(type, from: Data(json.utf8)) }
let input = decode(ChatTurnInput.self, """
{"modeId":"plan","configOptionValues":{"effort":"low","fast":false,"api_token":"hidden","custom_mode":"on","model":"duplicate","invalid":42}}
""")
let usage = decode(ChatTurnUsage.self, """
{"inputTokens":1234,"outputTokens":6640,"reasoningOutputTokens":2000,"cacheReadInputTokens":120000,"cacheCreationInputTokens":4096}
""")
let sections = MessageDetailsSections.make(model: "id-only", reasoning: "High", input: input, usage: usage)
let rows = sections.flatMap(\.rows)
@MainActor func row(_ id: String) -> LodyListRow { rows.first { $0.id == id }! }
precondition(row("model").subtitle == "id-only" && row("model").wrapSubtitle)
precondition(row("reasoning").value == "High")
precondition(rows.filter { $0.id == "reasoning" }.count == 1)
precondition(row("fast").value == String(localized: "message.details.off", bundle: .lody))
precondition(row("plan").value == String(localized: "message.details.on", bundle: .lody))
precondition(row("output").value == "8,640")
precondition(row("cacheRead").value == "120,000")
precondition(input.options["api_token"] == nil && input.options["invalid"] == nil)
precondition(MessageDetailsSections.make(model: nil, reasoning: nil, input: nil, usage: nil).isEmpty)
for invalid in [-1, 1.5, true, "100", 9_007_199_254_740_992.0, NSNull()] as [Any] {
  var raw: [String: Any] = usage.values!
  raw["inputTokens"] = invalid
  let data = try! JSONSerialization.data(withJSONObject: raw)
  precondition(try! JSONDecoder().decode(ChatTurnUsage.self, from: data).values == nil)
}
precondition(decode(ChatTurnUsage.self, "{}").values == nil)
precondition(decode(ChatTurnUsage.self, "false").values == nil)
let zeros = decode(ChatTurnUsage.self, """
{"inputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}
""")
let zeroRows = MessageDetailsSections.make(model: nil, reasoning: nil, input: nil, usage: zeros).flatMap(\.rows)
precondition(zeroRows.first { $0.id == "input" }?.value == "0")
precondition(!zeroRows.contains { $0.id == "reasoningTokens" })
print("PASS: metadata precedence, exact usage, missing/invalid usage, zero usage and configuration filtering")

// F28: optional cost is independent of the required integer token fields.
do {
  func metadata(_ cost: Any?, includeCost: Bool = true) -> ChatTurnUsage {
    var raw: [String: Any] = ["inputTokens": 12, "outputTokens": 3, "reasoningOutputTokens": 0,
      "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0]
    if includeCost { raw["costUSD"] = cost }
    return try! JSONDecoder().decode(ChatTurnUsage.self, from: JSONSerialization.data(withJSONObject: raw))
  }
  @MainActor func projected(_ usage: ChatTurnUsage) -> [LodyListRow] {
    MessageDetailsSections.make(model: nil, reasoning: nil, input: nil, usage: usage).flatMap(\.rows)
  }
  for (cost, amount) in [(0.0, "0.00"), (0.00000001, "0.00000001"), (0.0012345678, "0.00123457"),
                         (0.01, "0.01"), (0.123456, "0.1235"), (1.234, "1.23"), (12.3456, "12.35")] {
    let usage = metadata(cost)
    precondition(usage.values?["inputTokens"] == 12 && usage.costUSD == cost)
    let rows = projected(usage)
    let row = rows.first { $0.id == "cost" }!
    precondition(row.value.filter { "0123456789.,".contains($0) } == amount, row.value)
    precondition(row.value.contains("$") || row.value.contains("USD"), "Cost is denominated in USD")
    precondition(row.subtitle == String(localized: "message.details.costHint", bundle: .lody) && row.wrapSubtitle)
    precondition(rows.last?.id == "cost", "Cost follows the native token breakdown")
  }
  for invalid in [NSNull(), -1, true, "0.25", ["amount": 1]] as [Any] {
    let usage = metadata(invalid)
    precondition(usage.costUSD == nil && usage.values?["inputTokens"] == 12)
    precondition(!projected(usage).contains { $0.id == "cost" })
    precondition(projected(usage).first { $0.id == "input" }?.value == "12")
  }
  precondition(metadata(nil, includeCost: false).values?["outputTokens"] == 3)
  precondition(!projected(metadata(nil, includeCost: false)).contains { $0.id == "cost" })
  let decoder = JSONDecoder()
  decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
  for invalid in ["Infinity", "-Infinity", "NaN"] {
    let raw: [String: Any] = ["inputTokens": 12, "outputTokens": 3, "reasoningOutputTokens": 0,
      "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": invalid]
    let usage = try! decoder.decode(ChatTurnUsage.self, from: JSONSerialization.data(withJSONObject: raw))
    precondition(usage.costUSD == nil && usage.values?["inputTokens"] == 12)
  }
}
print("PASS: provider USD cost, tiny precision, zero, absent/null/invalid cost with unchanged tokens")
