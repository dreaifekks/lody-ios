import LodyCore
import UIKit

/// The detail-backed part of the provider editor: account credentials (preset key, endpoint and mode,
/// Codex auth), title generation, environment variables and notes. The editor places its rows into its
/// own groups. The runtime path, description and Pi extension list are not edited on mobile; they are
/// left out of the save so the stored values stay untouched.
@MainActor
final class AgentProviderAdvanced {
  var changed: (() -> Void)?
  private(set) var detail: ProviderDetail?
  private var option: AgentProviderCatalogItem?
  private var presets: [ProviderPreset] = []
  private var presetChanged = false
  private var modeID: String?
  private var endpointValue: String?
  /// The new key typed into the credential sheet; empty keeps the stored one.
  private var credentialDraft = ""
  private var titleValues: [String: ProviderJSON] = [:]
  private var titleChanged = false
  private var codexSupported = false
  private var codexMode = "chatgpt"
  private var codexURL = "https://api.openai.com/v1"
  private var editable = true
  private let profileID = UUID().uuidString.lowercased()
  private var capabilities = ProviderCapabilities()

  private let codexChoice = UIButton.lodyFormPicker("provider-codex-mode")
  private let credentialMode = UIButton.lodyFormPicker("provider-credential-mode")
  private let endpointChoice = UIButton.lodyFormPicker("provider-endpoint-choice")
  private(set) lazy var codexModeRow = LodyFormRow(label: AgentProviderSections.text("credentials"), content: codexChoice, picker: true)
  let codexEndpointRow = LodyFormValueRow(id: "provider-codex-endpoint", title: AgentProviderSections.text("endpointURL"))
  private(set) lazy var credentialModeRow = LodyFormRow(label: AgentProviderSections.text("mode"), content: credentialMode, picker: true)
  let credentialRow = LodyFormValueRow(id: "provider-credential", title: AgentProviderSections.text("apiKey"))
  private(set) lazy var endpointChoiceRow = LodyFormRow(label: AgentProviderSections.text("endpoint"), content: endpointChoice, picker: true)
  let endpointRow = LodyFormValueRow(id: "provider-endpoint", title: AgentProviderSections.text("endpointURL"))
  /// Compact tappable row that opens the run-config sheet for title generation options.
  let titleRow = LodyFormValueRow(id: "provider-title-generation", title: AgentProviderSections.text("titleGeneration"))
  let environment = AgentProviderEnvironment()
  /// "N extensions enabled" for Pi; the list itself is kept as saved.
  let extensions = LodyFormGroup.caption()
  let unavailable = LodyFormGroup.caption()
  private weak var titleSheetState: CreatePanelState?
  private static let titleDefaultOption = "__default__"

  init() {
    environment.changed = { [weak self] in self?.changed?() }
    credentialRow.addAction(UIAction { [weak self] _ in self?.editCredential() }, for: .touchUpInside)
    endpointRow.addAction(UIAction { [weak self] _ in self?.editEndpoint() }, for: .touchUpInside)
    codexEndpointRow.addAction(UIAction { [weak self] _ in self?.editCodexEndpoint() }, for: .touchUpInside)
    extensions.accessibilityIdentifier = "provider-pi-extensions"
    unavailable.accessibilityIdentifier = "provider-unavailable-actions"
  }

  private func text(_ key: String) -> String { AgentProviderSections.text(key) }
  private var preset: ProviderPreset? { presets.first { $0.id == option?.presetId } }
  private var mode: ProviderPreset.Mode? { preset?.modes.first { $0.id == modeID } ?? preset?.modes.first }
  private var isDeepSeek: Bool { option?.cliType == "builtin" && option?.agentType == "deepseek" }

  /// Whether the provider takes a key, endpoint or Codex account choice.
  var hasCredentials: Bool { preset != nil || isDeepSeek }
  var showsCodex: Bool { option?.agentType == "codex" && option?.cliType == "builtin" && codexSupported }
  /// Title generation applies only without a preset and when the agent does not title sessions itself.
  var showsTitle: Bool { preset == nil && !capabilities.sessionTitle && !titleOptions.isEmpty }

  private var titleOptions: [ProviderCapabilities.Option] {
    var options = capabilities.options
    if !capabilities.models.isEmpty && !options.contains(where: { $0.id == "model" }) {
      options.insert(.init(id: "model", name: text("titleModel"), type: "select", choices: capabilities.models), at: 0)
    }
    if !capabilities.modes.isEmpty && !options.contains(where: { $0.id == "mode" }) {
      options.append(.init(id: "mode", name: text("titleMode"), type: "select", choices: capabilities.modes))
    }
    return options
  }

  private func titleChoices(for option: ProviderCapabilities.Option) -> [(id: String, name: String, value: ProviderJSON)] {
    if option.type == "boolean" {
      return [("true", text("enabled"), .bool(true)), ("false", text("disabled"), .bool(false))]
    }
    return option.choices.map { ($0.id, $0.name, ProviderJSON.string($0.id)) }
  }

  func makeTitleConfigState() -> CreatePanelState {
    let state = CreatePanelState()
    state.runConfig = titlePickers()
    state.onPick = { [weak self, weak state] rowID, pickedID in
      guard let self, self.editable else { return }
      guard let option = self.titleOptions.first(where: { $0.id == rowID }) else { return }
      if pickedID == Self.titleDefaultOption {
        self.titleValues.removeValue(forKey: rowID)
      } else if let match = self.titleChoices(for: option).first(where: { $0.id == pickedID }) {
        self.titleValues[rowID] = match.value
      }
      self.titleChanged = true
      state?.runConfig = self.titlePickers()
      self.renderTitle()
      self.changed?()
    }
    titleSheetState = state
    return state
  }

  private func titlePickers() -> [CreatePicker] {
    guard preset == nil, !capabilities.sessionTitle else { return [] }
    return titleOptions.map { option in
      let choices = titleChoices(for: option)
      let override = titleValues[option.id]
      let effective = override ?? option.value
      let display = choices.first { $0.value == effective }?.name ?? text("default")
      let defaultOption = CreateOption(id: Self.titleDefaultOption, title: text("default"), selected: override == nil)
      let items = [defaultOption] + choices.map { choice in
        CreateOption(id: choice.id, title: choice.name, selected: override == choice.value)
      }
      return CreatePicker(id: option.id, glyph: .symbol("sparkles"), title: display, label: option.name,
                          placeholder: override == nil, options: items)
    }
  }

  func configure(machine: AgentProviderMachine) { codexSupported = machine.supportsCodexProfiles == true }

  func select(_ option: AgentProviderCatalogItem?, presets: [ProviderPreset]) {
    let different = self.option?.id != option?.id
    self.option = option
    self.presets = presets
    if different {
      credentialDraft = ""
      modeID = preset?.modes.first?.id
      endpointValue = nil
    }
    render()
  }

  func load(_ detail: ProviderDetail) {
    self.detail = detail
    titleChanged = false
    titleValues.removeAll()
    capabilities = detail.capabilities
    codexSupported = detail.supportsCodexProfiles
    if case .object(let profile) = detail.codexAuth {
      if case .string(let mode) = profile["mode"] { codexMode = mode }
      if case .string(let url) = profile["baseUrl"] { codexURL = url }
    }
    if case .object(let generation) = detail.titleGeneration, case .object(let values) = generation["configOptionValues"] { titleValues = values }
    if let current = detail.endpoints.first?.value {
      endpointValue = current
      modeID = preset?.modes.first(where: { $0.endpoint == current || $0.endpoints.contains(where: { $0.url == current }) })?.id ?? preset?.modes.first(where: { $0.customEndpoint })?.id ?? modeID
    }
    presetChanged = false
    render()
  }

  func updateCapabilities(_ capabilities: ProviderCapabilities) {
    self.capabilities = capabilities
    renderTitle()
  }

  private var protectedKeys: Set<String> {
    if let preset { return Set(preset.protectedEnvKeys).union([preset.tokenEnvKey]) }
    if isDeepSeek { return ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL"] }
    return []
  }

  private var tokenKey: String? { preset?.tokenEnvKey ?? (isDeepSeek ? "DEEPSEEK_API_KEY" : nil) }

  private var endpointText: String {
    let endpointKey = isDeepSeek ? "DEEPSEEK_BASE_URL" : "ANTHROPIC_BASE_URL"
    return endpointValue ?? detail?.endpoints.first { $0.key == endpointKey }?.value ?? mode?.endpoint ?? mode?.endpoints.first?.url ?? ""
  }

  private func render() {
    let reason = detail?.unavailableActions.contains(where: { $0.reason == "machine_capability_missing" }) == true ? "sorbetCapabilityMissing" : "sorbetUnavailable"
    unavailable.text = option?.agentType == "sorbet" ? text(reason) : nil
    unavailable.superview?.isHidden = option?.agentType != "sorbet"

    var enabledExtensions = 0
    if case .array(let paths) = detail?.runtimeOverrides["piExtensions"] { enabledExtensions = paths.count }
    extensions.text = String.localizedStringWithFormat(text("piExtensionsEnabled"), enabledExtensions)
    extensions.superview?.isHidden = option?.agentType != "pi" || enabledExtensions == 0

    codexChoice.configuration?.title = codexMode == "chatgpt" ? "ChatGPT" : text("customAPI")
    codexChoice.menu = UIMenu(children: ["chatgpt", "api-key"].map { mode in
      UIAction(title: mode == "chatgpt" ? "ChatGPT" : text("customAPI"), state: mode == codexMode ? .on : .off) { [weak self] _ in
        self?.codexMode = mode
        self?.render()
        self?.changed?()
      }
    })
    LodyFormGroup.setRow(codexModeRow, hidden: !showsCodex)
    codexEndpointRow.update(value: codexURL, placeholder: codexURL.isEmpty)
    LodyFormGroup.setRow(codexEndpointRow, hidden: !showsCodex || codexMode != "api-key")

    LodyFormGroup.setRow(credentialModeRow, hidden: preset == nil || (preset?.modes.count ?? 0) < 2)
    credentialMode.configuration?.title = mode?.name
    credentialMode.menu = UIMenu(children: (preset?.modes ?? []).map { next in
      UIAction(title: next.name, state: next.id == mode?.id ? .on : .off) { [weak self] _ in
        self?.presetChanged = true
        self?.modeID = next.id
        self?.endpointValue = nil
        self?.credentialDraft = ""
        self?.render()
        self?.changed?()
      }
    })
    let saved = tokenKey.map { key in detail?.env.contains { $0.key == key && $0.hasValue } == true } ?? false
    if !credentialDraft.isEmpty { credentialRow.update(value: text("credentialNew")) }
    else if saved { credentialRow.update(value: text("credentialSet")) }
    else { credentialRow.update(value: text("credentialNotSet"), placeholder: true) }
    LodyFormGroup.setRow(credentialRow, hidden: !hasCredentials)

    let endpoints = mode?.endpoints ?? []
    let current = endpointText
    endpointChoice.configuration?.title = endpoints.first { $0.url == current }?.name ?? text("chooseEndpoint")
    endpointChoice.menu = UIMenu(children: endpoints.map { next in
      UIAction(title: next.name, state: next.url == current ? .on : .off) { [weak self] _ in
        self?.presetChanged = true
        self?.endpointValue = next.url
        self?.render()
        self?.changed?()
      }
    })
    LodyFormGroup.setRow(endpointChoiceRow, hidden: !hasCredentials || endpoints.isEmpty)
    endpointRow.update(value: current.isEmpty ? text("notSet") : current, placeholder: current.isEmpty)
    LodyFormGroup.setRow(endpointRow, hidden: !isDeepSeek && mode?.customEndpoint != true)

    environment.configure(keys: detail?.env.map(\.key) ?? [], protectedKeys: protectedKeys)
    renderTitle()
    setEditable(editable)
  }

  private func renderTitle() {
    titleSheetState?.runConfig = titlePickers()
    guard showsTitle else {
      titleRow.update(value: text("default"), placeholder: true)
      return
    }
    var parts: [String] = []
    for option in titleOptions {
      guard let override = titleValues[option.id] else { continue }
      let choices = titleChoices(for: option)
      if let match = choices.first(where: { $0.value == override }) {
        if option.type == "boolean" { parts.append("\(option.name): \(match.name)") } else { parts.append(match.name) }
      } else if case .string(let raw) = override, !raw.isEmpty {
        parts.append(raw)
      }
    }
    if parts.isEmpty {
      titleRow.update(value: text("default"), placeholder: true)
    } else {
      titleRow.update(value: parts.joined(separator: " · "), placeholder: false)
    }
  }

  var isValid: Bool {
    if detail == nil, preset != nil || isDeepSeek, credentialDraft.isEmpty { return false }
    if let prefix = mode?.tokenPrefix, !credentialDraft.isEmpty { return credentialDraft.hasPrefix(prefix) }
    return true
  }

  func setEditable(_ editable: Bool) {
    self.editable = editable
    for row in [credentialRow, endpointRow, titleRow] { row.isEnabled = editable }
    for button in [credentialMode, endpointChoice] { button.isEnabled = editable }
    environment.setEditable(editable)
    codexChoice.isEnabled = editable && detail == nil
    codexEndpointRow.isEnabled = editable && detail == nil
  }

  func apply(to fields: inout AgentProviderFields) {
    fields.detailRevision = detail?.revision
    if detail == nil, codexSupported, option?.cliType == "builtin", option?.agentType == "codex" {
      var profile: [String: ProviderJSON] = ["mode": .string(codexMode), "profileId": .string(profileID)]
      if codexMode == "api-key" { profile["baseUrl"] = .string(codexURL.trimmingCharacters(in: .whitespacesAndNewlines)) }
      fields.codexAuth = .object(profile)
    }
    var patch = environment.patch.filter { !protectedKeys.contains($0.key) }
    let endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let preset {
      if detail == nil || presetChanged || !credentialDraft.isEmpty || detail?.presetId != preset.id {
        fields.presetId = preset.id
        fields.presetModeId = mode?.id
        fields.presetEndpoint = endpoint.isEmpty ? nil : endpoint
      }
      if !credentialDraft.isEmpty { patch.updateValue(credentialDraft, forKey: preset.tokenEnvKey) }
    } else if isDeepSeek {
      if !credentialDraft.isEmpty { patch.updateValue(credentialDraft, forKey: "DEEPSEEK_API_KEY") }
      if endpointValue != nil { patch.updateValue(endpoint.isEmpty ? nil : endpoint, forKey: "DEEPSEEK_BASE_URL") }
    }
    if !patch.isEmpty { fields.envPatch = patch }
    if titleChanged { fields.titleGeneration = .object(["action": .string("set"), "value": .object(["configOptionValues": .object(titleValues)])]) }
  }

  func clearSecrets() {
    credentialDraft = ""
    environment.clearSecrets()
    render()
  }

  private func editCredential() {
    guard editable, hasCredentials else { return }
    var options = AgentProviderTextSheet.Options()
    options.secure = true
    options.footer = text("credentialWriteOnly")
    let sheet = AgentProviderTextSheet(id: "provider-credential", label: text("apiKey"), text: "", limit: 32000, options: options) { [weak self] value in
      guard let self else { return }
      self.credentialDraft = value
      self.render()
      self.changed?()
    }
    LodyShell.shared.presentNative(sheet, title: text("apiKey"), detents: [0.5, 1])
  }

  private func editEndpoint() {
    guard editable else { return }
    var options = AgentProviderTextSheet.Options()
    options.url = true
    let sheet = AgentProviderTextSheet(id: "provider-endpoint", label: text("endpointURL"), text: endpointText, limit: 2048, options: options) { [weak self] value in
      guard let self else { return }
      self.presetChanged = true
      self.endpointValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      self.render()
      self.changed?()
    }
    LodyShell.shared.presentNative(sheet, title: text("endpointURL"), detents: [0.5, 1])
  }

  private func editCodexEndpoint() {
    guard editable, detail == nil else { return }
    var options = AgentProviderTextSheet.Options()
    options.url = true
    let sheet = AgentProviderTextSheet(id: "provider-codex-endpoint", label: text("endpointURL"), text: codexURL, limit: 2048, options: options) { [weak self] value in
      guard let self else { return }
      self.codexURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
      self.render()
      self.changed?()
    }
    LodyShell.shared.presentNative(sheet, title: text("endpointURL"), detents: [0.5, 1])
  }
}
