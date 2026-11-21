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
  /// Title generation pickers, hairline-separated, for the Conversation defaults group.
  let titleRows = UIStackView()
  let environment = AgentProviderEnvironment()
  /// "N extensions enabled" for Pi; the list itself is kept as saved.
  let extensions = LodyFormGroup.caption()
  let unavailable = LodyFormGroup.caption()

  init() {
    titleRows.axis = .vertical
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
  var accountFooter: String? {
    if hasCredentials { return text("credentialWriteOnly") }
    if showsCodex { return text("codexCredentials") }
    return nil
  }
  /// Title generation applies only without a preset and when the agent does not title sessions itself.
  var showsTitle: Bool { preset == nil && !capabilities.sessionTitle && titleRows.arrangedSubviews.contains { $0 is LodyFormRow } }

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
    titleRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    var options = capabilities.options
    if !capabilities.models.isEmpty && !options.contains(where: { $0.id == "model" }) {
      options.insert(.init(id: "model", name: text("titleModel"), type: "select", choices: capabilities.models), at: 0)
    }
    if !capabilities.modes.isEmpty && !options.contains(where: { $0.id == "mode" }) {
      options.append(.init(id: "mode", name: text("titleMode"), type: "select", choices: capabilities.modes))
    }
    guard preset == nil, !capabilities.sessionTitle else { return }
    for option in options {
      let button = UIButton.lodyFormPicker("provider-title:\(option.id)")
      let value = titleValues[option.id] ?? option.value
      var choices = option.choices.map { ($0.id, $0.name, ProviderJSON.string($0.id)) }
      if option.type == "boolean" { choices = [("true", text("enabled"), .bool(true)), ("false", text("disabled"), .bool(false))] }
      let label = choices.first { $0.2 == value }?.1 ?? text("default")
      button.configuration?.title = label
      let reset = UIAction(title: text("default"), state: titleValues[option.id] == nil ? .on : .off) { [weak self] _ in
        self?.titleValues.removeValue(forKey: option.id)
        self?.titleChanged = true
        self?.renderTitle()
        self?.changed?()
      }
      button.menu = UIMenu(children: [reset] + choices.map { choice in
        UIAction(title: choice.1, state: choice.2 == titleValues[option.id] ? .on : .off) { [weak self] _ in
          self?.titleValues[option.id] = choice.2
          self?.titleChanged = true
          self?.renderTitle()
          self?.changed?()
        }
      })
      button.isEnabled = editable
      if !titleRows.arrangedSubviews.isEmpty { titleRows.addArrangedSubview(LodyFormGroup.hairline()) }
      titleRows.addArrangedSubview(LodyFormRow(label: option.name, content: button, picker: true))
    }
  }

  var isValid: Bool {
    if detail == nil, preset != nil || isDeepSeek, credentialDraft.isEmpty { return false }
    if let prefix = mode?.tokenPrefix, !credentialDraft.isEmpty { return credentialDraft.hasPrefix(prefix) }
    return true
  }

  func setEditable(_ editable: Bool) {
    self.editable = editable
    for row in [credentialRow, endpointRow] { row.isEnabled = editable }
    for button in [credentialMode, endpointChoice] { button.isEnabled = editable }
    for case let row as LodyFormRow in titleRows.arrangedSubviews { row.isUserInteractionEnabled = editable }
    for case let row as LodyFormRow in titleRows.arrangedSubviews {
      for case let button as UIButton in row.subviews { button.isEnabled = editable }
    }
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
