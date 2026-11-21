import UIKit
import LodyCore

struct AgentProviderFields: Encodable, Sendable {
  var name: String
  var prompt: String
  var cliType: String
  var agentType: String
  var command: String
  var args: [String]
  var detailRevision: String?
  var description: String?
  var envPatch: [String: String?]?
  var runtimeOverrides: ProviderJSON?
  var titleGeneration: ProviderJSON?
  var codexAuth: ProviderJSON?
  var presetId: String?
  var presetModeId: String?
  var presetEndpoint: String?
}

/// The provider editor: a header card (with the quota line and operation status), then Basics, Command
/// (custom only), Account, Conversation defaults, Environment variables and Delete. Every value is a row
/// that opens a sheet or a menu; sheets edit the draft and only Save persists it. More (…) holds
/// Refresh capabilities, Save and test and Delete for saved providers.
@MainActor
final class AgentProviderEditorController: LodyFormController {
  var saved: ((AgentProviderSnapshot) -> Void)?
  /// The provisional row, shown in the list while the save is in flight.
  var willSave: ((AgentProviderItem) -> Void)?
  var saveFailed: (() -> Void)?
  var deleteRequested: ((AgentProviderItem) -> Void)?
  private let providerHeader = AgentProviderHeaderView()
  private let quotaLine = AgentProviderQuotaLine()
  private let quotaContainer = UIView()
  private lazy var deleteButton = LodyFormButton.make(id: "provider-delete", title: text("delete"), destructive: true) { [weak self] in
    self?.confirmDelete()
  }
  private let machine: AgentProviderMachine
  private var item: AgentProviderItem?
  private let catalog: [AgentProviderCatalogItem]
  private let scope: SettingsActor
  private let scopeKey: String
  private let service: AgentProviderService
  private let details: ProviderDetailService
  private let presets: [ProviderPreset]
  private let advanced = AgentProviderAdvanced()
  private let operationStatus = LodyFormGroup.caption()
  private let operationSpinner = UIActivityIndicatorView(style: .medium)
  private var statusContainer: UIView?
  private var refreshObserver: NSObjectProtocol?
  private var activeOperation: String?
  private var detailLoading = false
  private var detailFailed = false
  private let newID = UUID().uuidString.lowercased()
  private var selected: AgentProviderCatalogItem?
  private var busy = false
  private var invalid = false
  private var uncertain = false
  /// Sign-in state learned in this editor: completed here, or reported missing by a probe.
  private var signedIn = false
  private var signInRequired = false
  private let provider = UIButton.lodyFormPicker("provider-type")
  private var commandGroup: LodyFormGroup?
  private var accountGroup: LodyFormGroup?
  private var nameValue: String
  private var promptValue: String
  private var commandValue: String
  private var argsValue: String
  private let nameRow = LodyFormValueRow(id: "provider-name", title: AgentProviderSections.text("name"))
  private let commandRow = LodyFormValueRow(id: "provider-command", title: AgentProviderSections.text("command"))
  private let argsRow = LodyFormValueRow(id: "provider-args", title: AgentProviderSections.text("args"))
  private let promptRow = LodyFormValueRow(id: "provider-prompt", title: AgentProviderSections.text("systemPrompt"), stacked: true)
  private let signInRow = LodyFormValueRow(id: "provider-sign-in", title: AgentProviderSections.text("signInRow"))
  private lazy var cancelItem = Self.barButton(symbol: "xmark", label: String(localized: "common.cancel", bundle: .lody)) { [weak self] in self?.closeForm() }
  private lazy var saveItem = Self.barButton(symbol: "checkmark", label: RemoteSettingsSections.remote("save"), prominent: true) { [weak self] in self?.save() }
  private lazy var moreItem: UIBarButtonItem = {
    let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
    button.accessibilityLabel = AgentProviderSections.text("more")
    button.accessibilityIdentifier = "provider-more"
    return button
  }()

  init(machine: AgentProviderMachine, item: AgentProviderItem?, catalog: [AgentProviderCatalogItem], scope: SettingsActor,
       service: @escaping AgentProviderService, details: ProviderDetailService = .cloud, presets: [ProviderPreset] = []) {
    self.machine = machine
    self.item = item
    self.catalog = catalog
    self.scope = scope
    scopeKey = scope.key
    self.service = service
    self.details = details
    self.presets = presets
    nameValue = item?.name ?? ""
    promptValue = item?.prompt ?? ""
    commandValue = item?.command ?? ""
    argsValue = (item?.args ?? []).joined(separator: "\n")
    super.init(nibName: nil, bundle: nil)
    if let item {
      selected = catalog.first { $0.cliType == item.cliType && $0.agentType == item.agentType }
        ?? AgentProviderCatalogItem(id: item.agentType, name: RemoteSettingsSections.agentName(item.agentType), cliType: item.cliType, agentType: item.agentType)
    } else {
      selected = catalog.first
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    scope.watch(self) { [weak self] in
      guard let self else { return }
      self.invalid = self.scope.key != self.scopeKey
      self.render()
    }
    stack.addArrangedSubview(makeHeader())
    if item == nil {
      let hint = LodyFormGroup.caption()
      hint.text = text("setupHint")
      hint.numberOfLines = 0
      stack.addArrangedSubview(LodyFormGroup.inset(hint))
    }
    stack.addArrangedSubview(LodyFormGroup(header: text("basics"), LodyFormRow(label: text("type"), content: provider, picker: true), nameRow))
    let custom = LodyFormGroup(header: text("custom"), footer: text("argsHint"), commandRow, argsRow)
    commandGroup = custom
    stack.addArrangedSubview(custom)
    let account = LodyFormGroup(header: text("account"), rows: [
      signInRow, advanced.credentialModeRow, advanced.credentialRow, advanced.endpointChoiceRow, advanced.endpointRow,
      advanced.codexModeRow, advanced.codexEndpointRow,
    ])
    accountGroup = account
    stack.addArrangedSubview(account)
    stack.addArrangedSubview(LodyFormGroup.inset(advanced.unavailable))
    stack.addArrangedSubview(LodyFormGroup(header: text("conversationDefaults"), footer: RemoteSettingsSections.remote("agentHint"),
                                           promptRow, advanced.titleRows))
    stack.addArrangedSubview(LodyFormGroup.inset(advanced.extensions))
    stack.addArrangedSubview(advanced.environment)
    if item != nil, !isReadOnly { stack.addArrangedSubview(LodyFormGroup(deleteButton)) }

    nameRow.addAction(UIAction { [weak self] _ in self?.editName() }, for: .touchUpInside)
    commandRow.addAction(UIAction { [weak self] _ in self?.editCommand() }, for: .touchUpInside)
    argsRow.addAction(UIAction { [weak self] _ in self?.editArgs() }, for: .touchUpInside)
    promptRow.addAction(UIAction { [weak self] _ in self?.editPrompt() }, for: .touchUpInside)
    signInRow.addAction(UIAction { [weak self] _ in self?.authenticate() }, for: .touchUpInside)
    quotaLine.addAction(UIAction { [weak self] _ in self?.showUsage() }, for: .touchUpInside)

    advanced.configure(machine: machine)
    advanced.select(selected, presets: presets)
    advanced.changed = { [weak self] in self?.render() }
    refreshObserver = NotificationCenter.default.addObserver(forName: .lodyProviderRefreshProgress, object: nil, queue: .main) { [weak self] notification in
      guard let progress = notification.object as? RuntimeContract.AgentProviderRefreshProgress else { return }
      let eventScope = notification.userInfo?["scopeKey"] as? String
      MainActor.assumeIsolated {
        guard let self, self.scope.key == self.scopeKey, eventScope == self.scopeKey,
              self.activeOperation == "refresh-models", self.item?.id == progress.id,
              self.machine.id == progress.machineId else { return }
        self.operationStatus.text = String.localizedStringWithFormat(
          self.text("readingModelOptions"), progress.modelName, progress.index, progress.total)
        self.render()
      }
    }
    render()
    if item != nil { loadDetail() }
  }

  /// The card, the quota line under it and the operation status line.
  private func makeHeader() -> UIView {
    quotaLine.translatesAutoresizingMaskIntoConstraints = false
    quotaContainer.addSubview(quotaLine)
    NSLayoutConstraint.activate([
      // Under the name, past the 56 pt mark and its 14 pt gap.
      quotaLine.leadingAnchor.constraint(equalTo: quotaContainer.leadingAnchor, constant: LodyFormGroup.margin + 70),
      quotaLine.trailingAnchor.constraint(lessThanOrEqualTo: quotaContainer.trailingAnchor, constant: -LodyFormGroup.margin),
      quotaLine.topAnchor.constraint(equalTo: quotaContainer.topAnchor),
      quotaLine.bottomAnchor.constraint(equalTo: quotaContainer.bottomAnchor),
    ])
    operationSpinner.hidesWhenStopped = true
    operationStatus.accessibilityIdentifier = "provider-operation-status"
    let status = UIStackView(arrangedSubviews: [operationSpinner, operationStatus])
    status.spacing = 8
    status.alignment = .center
    let statusContainer = LodyFormGroup.inset(status)
    self.statusContainer = statusContainer
    let card = UIStackView(arrangedSubviews: [providerHeader, quotaContainer, statusContainer])
    card.axis = .vertical
    card.spacing = 6
    return card
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    header?.leftBarButtonItems = [cancelItem]
    render()
  }

  private var isReadOnly: Bool { machine.readOnly || item?.readOnly == true }
  private var editable: Bool { !busy && !detailLoading && !detailFailed && !invalid && !uncertain && !isReadOnly }
  private var name: String { nameValue.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var command: String { commandValue.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canRefreshModels: Bool { editable && machine.online && item != nil }

  private func render() {
    guard isViewLoaded else { return }
    let canEdit = editable
    provider.isEnabled = canEdit && item == nil
    provider.configuration?.title = selected?.name ?? text("type")
    provider.menu = UIMenu(children: catalog.map { option in
      UIAction(title: option.name, state: option.id == selected?.id ? .on : .off) { [weak self] _ in
        guard let self else { return }
        let prior = self.selected?.name
        self.selected = option
        self.advanced.select(option, presets: self.presets)
        if self.name.isEmpty || self.name == prior { self.nameValue = option.name }
        self.render()
      }
    })
    display(nameRow, value: name)
    display(commandRow, value: command)
    display(argsRow, value: argsValue.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " "))
    display(promptRow, value: promptValue.trimmingCharacters(in: .whitespacesAndNewlines))
    for row in [nameRow, commandRow, argsRow, promptRow] { row.isEnabled = canEdit }
    commandGroup?.isHidden = selected?.cliType != "custom"

    providerHeader.update(
      name: name.isEmpty ? (selected?.name ?? text("provider")) : name,
      detail: [selected?.name ?? "", machine.name.isEmpty ? machine.id : machine.name].filter { !$0.isEmpty }.joined(separator: " · "),
      asset: LodyAgentIcon.asset(cliType: selected?.cliType ?? "builtin", agentType: selected?.agentType ?? "") ?? "",
      custom: selected?.cliType == "custom", online: machine.online
    )
    quotaLine.update(usageWindows())
    quotaContainer.isHidden = quotaLine.isHidden
    if activeOperation != nil { operationSpinner.startAnimating() } else { operationSpinner.stopAnimating() }
    statusContainer?.isHidden = activeOperation == nil && (operationStatus.text ?? "").isEmpty

    renderSignIn(editable: canEdit)
    advanced.setEditable(canEdit)
    accountGroup?.footer = advanced.accountFooter
    accountGroup?.isHidden = signInRow.isHidden && !advanced.hasCredentials && !advanced.showsCodex
    LodyFormGroup.setRow(advanced.titleRows, hidden: !advanced.showsTitle)

    saveItem.isEnabled = canEdit && advanced.isValid && selected != nil && !name.isEmpty
      && (selected?.cliType != "custom" || !command.isEmpty)
    cancelItem.isEnabled = !busy
    deleteButton.isEnabled = !busy && !invalid && !uncertain
    moreItem.menu = UIMenu(children: moreActions())
    var items: [UIBarButtonItem] = []
    if !isReadOnly { items = item == nil ? [saveItem] : [saveItem, moreItem] }
    if header?.rightBarButtonItems?.count ?? 0 != items.count { header?.rightBarButtonItems = items }
    isModalInPresentation = busy
    if invalid { advanced.clearSecrets() }
    if invalid || uncertain || detailFailed {
      let notice = LodyFormGroup.caption(color: .systemRed, size: 15)
      notice.numberOfLines = 0
      var message = "scopeChanged"
      if uncertain { message = "writeFailed" }
      if detailFailed { message = "detailFailed" }
      notice.text = text(message)
      let container = LodyFormGroup.inset(notice)
      container.accessibilityIdentifier = "provider-editor-notice"
      // Under the header, where it is seen before any field it disables.
      if !stack.arrangedSubviews.contains(where: { $0.accessibilityIdentifier == "provider-editor-notice" }) {
        stack.insertArrangedSubview(container, at: min(1, stack.arrangedSubviews.count))
      }
    }
  }

  private func display(_ row: LodyFormValueRow, value: String) {
    if value.isEmpty { row.update(value: text("notSet"), placeholder: true) } else { row.update(value: value) }
  }

  /// Signed in, Sign in, or not supported; a draft provider cannot sign in until it is saved.
  private func renderSignIn(editable: Bool) {
    LodyFormGroup.setRow(signInRow, hidden: item == nil || advanced.detail == nil)
    guard advanced.detail?.supportsAuthentication == true else {
      signInRow.update(value: text("signInUnsupported"), placeholder: true, chevron: false)
      signInRow.isEnabled = false
      return
    }
    var state = "signIn"
    if signInRequired { state = "setup.auth_required" }
    if signedIn { state = "auth.authenticated" }
    signInRow.update(value: text(state))
    signInRow.isEnabled = editable
  }

  private func moreActions() -> [UIMenuElement] {
    guard !isReadOnly, item != nil else { return [] }
    let refresh = UIAction(title: text("refresh"), image: UIImage(systemName: "arrow.clockwise"),
                           attributes: canRefreshModels ? [] : .disabled) { [weak self] _ in self?.refreshModels() }
    let test = UIAction(title: text("saveAndTest"), image: UIImage(systemName: "checkmark.seal"),
                        attributes: saveItem.isEnabled ? [] : .disabled) { [weak self] _ in self?.save(probe: true) }
    let delete = UIAction(title: text("delete"), image: UIImage(systemName: "trash"),
                          attributes: deleteButton.isEnabled ? .destructive : [.destructive, .disabled]) { [weak self] _ in self?.confirmDelete() }
    return [UIMenu(options: .displayInline, children: [refresh, test]), delete]
  }

  // MARK: Draft sheets

  private func editText(_ id: String, title key: String, value: String, limit: Int,
                        options: AgentProviderTextSheet.Options = AgentProviderTextSheet.Options(), detents: [Double] = [0.5, 1],
                        apply: @escaping @MainActor (AgentProviderEditorController, String) -> Void) {
    guard editable else { return }
    let sheet = AgentProviderTextSheet(id: id, label: text(key), text: value, limit: limit, options: options) { [weak self] next in
      guard let self, self.scope.key == self.scopeKey else { return }
      apply(self, next)
      self.render()
    }
    LodyShell.shared.presentNative(sheet, title: text(key), detents: detents)
  }

  private func editName() {
    editText("provider-name", title: "name", value: nameValue, limit: 200) { $0.nameValue = $1 }
  }

  private func editCommand() {
    var options = AgentProviderTextSheet.Options()
    options.footer = text("commandHint")
    editText("provider-command", title: "command", value: commandValue, limit: 4096, options: options) { $0.commandValue = $1 }
  }

  private func editArgs() {
    var options = AgentProviderTextSheet.Options()
    options.multiline = true
    options.minHeight = 200
    options.footer = text("argsHint")
    editText("provider-args", title: "args", value: argsValue, limit: 32000, options: options, detents: [1]) { $0.argsValue = $1 }
  }

  private func editPrompt() {
    var options = AgentProviderTextSheet.Options()
    options.multiline = true
    options.minHeight = 360
    options.footer = RemoteSettingsSections.remote("agentHint")
    editText("provider-prompt", title: "systemPrompt", value: promptValue, limit: 32000, options: options, detents: [1]) { $0.promptValue = $1 }
  }

  private func showUsage() {
    guard let item else { return }
    let supported = advanced.detail.map { detail in
      detail.supportsRateLimitsRefresh != false && !detail.unavailableActions.contains { $0.action == "rate-limits-refresh" }
    }
    let controller = AgentProviderUsageController(machine: machine, item: item, scope: scope, details: details,
                                                  canRefresh: !isReadOnly && machine.online && !invalid, supported: supported)
    LodyShell.shared.presentNative(controller, title: AgentProviderUsageController.sheetTitle(item), detents: [0.6, 1])
  }

  // MARK: Save and operations

  private func save(probe: Bool = false) {
    guard saveItem.isEnabled, scope.key == scopeKey, let selected else { return }
    busy = true
    render()
    let customArgs = argsValue == (item?.args ?? []).joined(separator: "\n") ? item?.args ?? [] :
      (argsValue.isEmpty ? [] : argsValue.components(separatedBy: .newlines))
    var fields = AgentProviderFields(name: name, prompt: promptValue, cliType: selected.cliType,
                                     agentType: selected.agentType, command: selected.cliType == "custom" ? command : "",
                                     args: selected.cliType == "custom" ? customArgs : [])
    advanced.apply(to: &fields)
    let request = AgentProviderRequest(workspaceId: scope.workspaceId, action: "save", machineId: machine.id,
                                       id: item?.id ?? newID, base: item, fields: fields)
    if !probe {
      willSave?(AgentProviderItem(id: request.id ?? newID, machineId: machine.id, name: fields.name, cliType: fields.cliType,
                                  agentType: fields.agentType, prompt: fields.prompt, readOnly: false,
                                  command: fields.command, args: fields.args))
    }
    Task { [weak self, service] in
      do {
        let next = try await service(request)
        guard let self, self.scope.key == self.scopeKey else { return }
        self.busy = false
        self.saved?(next)
        self.advanced.clearSecrets()
        if probe, let item = next.providers.first(where: { $0.id == request.id }) {
          self.item = item
          await self.runProbe()
        } else {
          self.closeForm()
        }
      } catch {
        guard let self else { return }
        self.busy = false
        // A lost reply may have saved or scheduled the provider. Reopen after a fresh list instead of replaying.
        self.uncertain = true
        self.saveFailed?()
        LodyToastOverlay.shared.show(message: self.text("writeFailed"), kind: .error)
        self.render()
      }
    }
  }

  private var target: ProviderTarget {
    ProviderTarget(workspaceId: scope.workspaceId, machineId: machine.id, id: item?.id ?? newID)
  }

  private func loadDetail() {
    detailLoading = true
    render()
    Task { [weak self, details, target] in
      do {
        let detail = try await details.detail(target)
        guard let self, self.scope.key == self.scopeKey else { return }
        self.detailLoading = false
        if let preset = self.presets.first(where: { $0.id == detail.presetId }) {
          self.selected = AgentProviderCatalogItem(id: preset.id, name: preset.name, cliType: preset.cliType, agentType: preset.agentType, presetId: preset.id)
          self.advanced.select(self.selected, presets: self.presets)
        }
        self.advanced.load(detail)
        self.render()
      } catch {
        guard let self, self.scope.key == self.scopeKey else { return }
        self.detailLoading = false
        self.detailFailed = true
        self.render()
      }
    }
  }

  private func runProbe() async {
    busy = true
    render()
    do {
      let result = try await details.probe(target)
      guard scope.key == scopeKey else { return }
      advanced.updateCapabilities(result.capabilities)
      busy = false
      signInRequired = result.authRequired
      var message = result.success ? "testPassed" : "testFailed"
      if result.authRequired { message = "authRequired" }
      LodyToastOverlay.shared.show(message: text(message), kind: result.success ? .success : .warning)
      loadDetail()
    } catch {
      guard scope.key == scopeKey else { return }
      busy = false
      LodyToastOverlay.shared.show(message: text("testFailed"), kind: .error)
      loadDetail()
    }
  }

  /// Starts the agent again and switches it through every model, naming each one as its
  /// options are read. Without the machine capability this is an ordinary refresh.
  private func refreshModels() {
    guard canRefreshModels, scope.key == scopeKey else { return }
    busy = true
    activeOperation = "refresh-models"
    operationStatus.text = text("refreshing")
    render()
    var request = target
    request.readModelOptions = true
    Task { [weak self, details] in
      do {
        let result = try await details.probe(request)
        guard let self, self.scope.key == self.scopeKey else { return }
        self.advanced.updateCapabilities(result.capabilities)
        self.signInRequired = result.authRequired
        var message = result.success ? "refreshDone" : "operationFailed"
        if result.authRequired { message = "authRequired" }
        self.finishRefresh(self.text(message))
      } catch {
        guard let self, self.scope.key == self.scopeKey else { return }
        self.finishRefresh(self.text("operationUnknown"))
      }
    }
  }

  private func finishRefresh(_ message: String) {
    busy = false
    activeOperation = nil
    operationStatus.text = message
    render()
    loadDetail()
  }

  isolated deinit {
    if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
  }

  private func authenticate() {
    guard editable, let detail = advanced.detail, detail.supportsAuthentication, let item, scope.key == scopeKey else { return }
    let controller = AgentProviderAuthController(target: target, methods: detail.supportsMethodSelection ? detail.capabilities.authMethods : [], scope: scope, service: details)
    controller.authenticated = { [weak self] in
      guard let self else { return }
      self.signedIn = true
      self.signInRequired = false
      self.operationStatus.text = self.text("auth.authenticated")
      self.render()
    }
    LodyShell.shared.presentNative(controller, title: item.name, detents: [1])
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true { advanced.clearSecrets() }
  }

  private func usageWindows() -> [LodyListVisualItem] {
    guard let item, let reported = RemoteSettingsContext.current().agentUsage[machine.id] else { return [] }
    let setting = RemoteSetting(kind: "agent", id: item.id, name: item.name, machineId: machine.id, detail: item.agentType)
    return RemoteSettingsSections.rings(setting, reported, now: LodyRelativeTime.now())
  }

  private func confirmDelete() {
    guard let item, !busy else { return }
    SettingsPage.confirm(from: self, title: text("delete"), message: String.localizedStringWithFormat(text("deleteConfirm"), item.name),
                         action: text("delete"), destructive: true) { [weak self] in
      guard let self, self.scope.key == self.scopeKey else { return }
      self.deleteRequested?(item)
      self.closeForm()
    }
  }

  private func text(_ key: String) -> String { AgentProviderSections.text(key) }
}

/// The editor's opening card: the provider's mark, its name and where it runs.
@MainActor
final class AgentProviderHeaderView: UIView {
  private let mark = UIImageView()
  private let markBackground = UIView()
  private let title = UILabel()
  private let detail = UILabel()
  private let dot = UIView()

  init() {
    super.init(frame: .zero)
    markBackground.backgroundColor = .lodyOpaqueCard
    markBackground.layer.cornerRadius = 16
    markBackground.layer.cornerCurve = .continuous
    mark.contentMode = .scaleAspectFit
    mark.tintColor = .label
    mark.translatesAutoresizingMaskIntoConstraints = false
    markBackground.addSubview(mark)
    title.font = .preferredFont(forTextStyle: .title3).withWeight(.semibold)
    title.adjustsFontForContentSizeCategory = true
    title.numberOfLines = 2
    detail.font = .preferredFont(forTextStyle: .subheadline)
    detail.textColor = .secondaryLabel
    detail.adjustsFontForContentSizeCategory = true
    detail.numberOfLines = 2
    dot.layer.cornerRadius = 4
    let detailRow = UIStackView(arrangedSubviews: [dot, detail])
    detailRow.spacing = 6
    detailRow.alignment = .center
    let text = UIStackView(arrangedSubviews: [title, detailRow])
    text.axis = .vertical
    text.spacing = 3
    let row = UIStackView(arrangedSubviews: [markBackground, text])
    row.spacing = 14
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      markBackground.widthAnchor.constraint(equalToConstant: 56),
      markBackground.heightAnchor.constraint(equalToConstant: 56),
      mark.centerXAnchor.constraint(equalTo: markBackground.centerXAnchor),
      mark.centerYAnchor.constraint(equalTo: markBackground.centerYAnchor),
      mark.widthAnchor.constraint(equalToConstant: 30),
      mark.heightAnchor.constraint(equalToConstant: 30),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LodyFormGroup.margin),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -LodyFormGroup.margin),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .header
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  func update(name: String, detail: String, asset: String, custom: Bool, online: Bool) {
    title.text = name
    self.detail.text = detail
    let image = asset.isEmpty ? nil : UIImage(named: asset, in: .main, compatibleWith: nil)
    mark.image = (image ?? UIImage(systemName: custom ? "terminal" : "sparkles"))?.withRenderingMode(.alwaysTemplate)
    dot.backgroundColor = online ? .systemGreen : .tertiaryLabel
    accessibilityLabel = [name, detail].joined(separator: ", ")
  }
}
