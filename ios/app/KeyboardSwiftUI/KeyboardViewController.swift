import UIKit

/// The keyboard's root view. Adopting UIInputViewAudioFeedback is what lets
/// playInputClick() sound, following the system's keyboard-click setting.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
  var enableInputClicksWhenVisible: Bool { true }
}

// The keyboard in the style of iOS's own Simplified Chinese Pinyin keyboard: a strip for
// candidates above four rows of keys, nothing else. Holding 123 opens the settings, the
// smiley opens emoji. Letters start in the engine at touch-down (keyDown) and show at
// touch-up; everything about the engine is in CommandKeyboardController.
final class KeyboardViewController: CommandKeyboardController, KeysViewDelegate,
  CandidateViewsDelegate, EmojiPanelDelegate, SettingsPanelDelegate
{
  let candidateBar = CandidateBarView()
  let candidateGrid = CandidateGridView()
  let keysView = KeysView()
  let emojiPanel = EmojiPanel()
  let settingsPanel = SettingsPanel()
  // DocumentEditing.swift
  var documentTimer: Timer?
  var documentIdentifier = ""
  private var heightConstraint: NSLayoutConstraint?
  private var candidatesMore = false

  /// The dictionary stays in the other extension's bundle; a keyboard may read anything
  /// inside the app that contains it, with or without Full Access.
  override var resourceDirectory: String {
    Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("CassotisKeyboard.appex").path
  }

  override func loadView() {
    view = KeyboardInputView(frame: .zero, inputViewStyle: .default)
  }

  private var landscape: Bool { traitCollection.verticalSizeClass == .compact }
  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

  override func buildKeyboard() {
    view.backgroundColor = KeyboardTheme.background(dark)
    keysView.delegate = self
    candidateBar.delegate = self
    candidateGrid.delegate = self
    emojiPanel.delegate = self
    settingsPanel.delegate = self
    view.addSubview(candidateBar)
    // Above the strip, so a letter's callout in the top row is not covered by it.
    view.addSubview(keysView)
    for overlay in [candidateGrid, emojiPanel, settingsPanel] as [UIView] {
      overlay.isHidden = true
      overlay.backgroundColor = KeyboardTheme.background(dark)
      view.addSubview(overlay)
    }
    let height = view.heightAnchor.constraint(equalToConstant: KeyboardTheme.height(landscape))
    height.priority = UILayoutPriority(999)
    height.isActive = true
    heightConstraint = height
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let bounds = view.bounds
    let strip = KeyboardTheme.strip(landscape)
    candidateBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: strip)
    keysView.setLandscape(landscape)
    let keys = CGRect(x: 0, y: strip, width: bounds.width, height: bounds.height - strip)
    keysView.frame = keys
    candidateGrid.frame = keys
    emojiPanel.frame = CGRect(x: 0, y: 6, width: bounds.width, height: bounds.height - 6)
    settingsPanel.frame = CGRect(x: 0, y: 6, width: bounds.width, height: bounds.height - 6)
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    heightConstraint?.constant = KeyboardTheme.height(landscape)
    view.backgroundColor = KeyboardTheme.background(dark)
    for overlay in [candidateGrid, emojiPanel, settingsPanel] as [UIView] {
      overlay.backgroundColor = KeyboardTheme.background(dark)
    }
    view.setNeedsLayout()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    closeOverlays()
    keysView.show(.letters)
    keysView.hapticsEnabled = hasFullAccess  // a keyboard may vibrate only with Full Access
    updateReturnKey()
    showInputMode(Self.rememberedMode)
    startDocumentPolling()
  }

  override func viewWillDisappear(_ animated: Bool) {
    // Another keyboard, or dismissed: commit as macOS does on deactivation.
    commitCompositionNow()
    stopDocumentPolling()
    super.viewWillDisappear(animated)
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    updateReturnKey()
  }

  /// The return key says what the field's return does, as the system's does.
  func updateReturnKey() {
    let titles: [UIReturnKeyType: String] = [
      .go: "前往", .google: "搜索", .join: "加入", .next: "下一项", .route: "路线",
      .search: "搜索", .send: "发送", .yahoo: "搜索", .done: "完成", .emergencyCall: "紧急",
      .continue: "继续",
    ]
    keysView.returnTitle = textDocumentProxy.returnKeyType.flatMap { titles[$0] }
  }

  func closeOverlays() {
    candidateGrid.isHidden = true
    candidateBar.setExpanded(false)
    emojiPanel.isHidden = true
    settingsPanel.isHidden = true
    keysView.isHidden = false
  }

  // MARK: - What the engine shows

  override func showCandidates(_ candidates: [String], preedit: String, selected: Int, more: Bool) {
    candidatesMore = more
    candidateBar.set(candidates, selected: max(selected, 0), more: more)
    if candidates.isEmpty {
      candidateGrid.isHidden = true
      keysView.isHidden = false
    } else if !candidateGrid.isHidden {
      candidateGrid.set(candidates, more: more)
    }
  }

  override func appendCandidates(_ candidates: [String], end: Bool) {
    candidatesMore = !end
    candidateBar.append(candidates, more: !end)
    if !candidateGrid.isHidden { candidateGrid.append(candidates, more: !end) }
  }

  override func showInputMode(_ mode: Int) {
    keysView.modeMark = mode == 1 ? "英" : "拼"
  }

  override func moveCursor(_ code: String) { moveCursorInDocument(code) }

  // MARK: - Keys

  func letterDown(_ text: String) { keyDown(text, forward: false) }
  func letterUp(_ text: String) { letterReleased(text) }
  func letterCancelled(_ text: String) { keyCancelled() }

  /// A digit or symbol from the number pages: typed as shown, after what is composed.
  func literal(_ text: String) {
    commitComposition()
    insertAfterKeys(text)
  }

  func delete() { pressDelete() }

  func space() {
    pressSpecial(5, fallback: " ")
    if keysView.page != .letters { keysView.show(.letters) }  // as the system does
  }

  func returnKey() { pressSpecial(3, fallback: "\n") }
  func showPage(_ page: KeyPage) { keysView.show(page) }

  func emoji() {
    commitComposition()
    emojiPanel.reload()
    emojiPanel.isHidden = false
  }

  func settings() {
    refreshSettings()
    settingsPanel.reset()
    settingsPanel.isHidden = false
  }

  func moveCaret(_ steps: Int) {
    guard preedit.isEmpty else { return }  // the trackpad moves the caret, not the candidates
    for _ in 0..<abs(steps) { moveCursorInDocument(steps < 0 ? "ArrowLeft" : "ArrowRight") }
  }

  func shiftChanged(_ shifted: Bool) {}

  // MARK: - Candidates

  override func pickCandidate(_ index: Int) {
    candidateGrid.isHidden = true
    candidateBar.setExpanded(false)
    keysView.isHidden = false
    super.pickCandidate(index)
  }

  func loadMoreCandidates() { loadCandidates(shownCandidates.count, 27) }

  func candidatesExpanded(_ expanded: Bool) {
    if expanded {
      candidateGrid.set(shownCandidates, more: candidatesMore)
      candidateGrid.isHidden = false
      keysView.isHidden = true
    } else {
      candidateGrid.isHidden = true
      keysView.isHidden = false
    }
  }

  // MARK: - Emoji and settings

  func emojiPicked(_ emoji: String) { insertAfterKeys(emoji) }
  func emojiDelete() { pressDelete() }
  func emojiClose() { emojiPanel.isHidden = true }

  func settingChosen(_ id: Int32) { activateSetting(id) }
  func settingsClose() { settingsPanel.isHidden = true }

  // MARK: - Test commands

  /// mode=type's commands for this keyboard: open its pages and panels for a screenshot,
  /// change a setting, type a symbol from a number page.
  override func typeCommand(_ token: String) -> Bool {
    let argument = String(token.dropFirst().dropLast().split(separator: ":", maxSplits: 1).last ?? "")
    switch token {
    case "{settings}", "{status}": settings()
    case "{emoji}": emoji()
    case "{expand}":
      candidateBar.setExpanded(true)
      candidatesExpanded(true)
    case "{reset}": commitComposition()
    default:
      if token.hasPrefix("{page:") {
        keysView.show(argument == "numbers" ? .numbers : argument == "symbols" ? .symbols : .letters)
      } else if token.hasPrefix("{set:"), let id = Int32(argument) {
        activateSetting(id)
      } else if token.hasPrefix("{sym:") {
        literal(argument)
      } else {
        return false
      }
    }
    return true
  }
}
