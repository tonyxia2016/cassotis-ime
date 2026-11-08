import SwiftUI
import UIKit

// The fcitx5-ios SwiftUI panel in front of the Cassotis engine. FcitxProtocol is
// the panel's view of its host: keyPressed is the one busy method, the place where
// fcitx5-ios calls Fcitx.processKey and this calls the engine. Editing the document
// around the composition (cursor keys, undo, the backspace slide, the clipboard,
// another field taking focus) is in DocumentEditing.swift.
final class KeyboardViewController: CommandKeyboardController, FcitxProtocol {
  nonisolated(unsafe) static weak var current: KeyboardViewController?
  private let program = UUID().uuidString
  private let inputContext = "cassotis"
  private var hostingController: UIHostingController<AnyView>?

  // DocumentEditing.swift
  let undoRedo = UndoRedoManager()
  var documentState: UndoRedoDocumentState?
  var documentTimer: Timer?
  var removedBySlide = ""
  var slidingBackspace = false
  var verticalMove = 0
  var movingVertically = false
  var changingLines = false
  /// resetInput waits for the rest of the panel's event to know what it means.
  var resetPending = false

  /// The dictionary stays in the other extension's bundle; a keyboard may read
  /// anything inside the app that contains it, with or without Full Access.
  override var resourceDirectory: String {
    Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("CassotisKeyboard.appex").path
  }

  override func viewDidLoad() {
    Self.current = self
    super.viewDidLoad()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    vm.setReturnKeyType(textDocumentProxy.returnKeyType)
    vm.setDisplayMode(.initial)
    showInputMode(Self.rememberedMode)
    startDocumentPolling()
  }

  override func viewWillDisappear(_ animated: Bool) {
    // Another keyboard, or dismissed: commit as macOS does on deactivation.
    commitCompositionNow()
    stopDocumentPolling()
    super.viewWillDisappear(animated)
  }

  /// Long-pressing the globe key lists these (getInputMethods); the space bar
  /// shows the current one's name.
  nonisolated static let inputMethods: [(name: String, display: String, language: String)] = [
    ("cassotis-pinyin", "拼音", "zh_CN"), ("cassotis-english", "英文", "en"),
  ]

  override func showInputMode(_ mode: Int) {
    let index = mode == 1 ? 1 : 0
    setCurrentInputMethodAsync(program, inputContext, Self.inputMethods[index].name)
  }

  override func buildKeyboard() {
    setClient(self)
    // On iOS 26+ a scroll view gets a soft edge effect, and the candidate strip is
    // one row high, so the effect covers all of it and blurs the candidates.
    let root: AnyView
    if #available(iOS 26.0, *) {
      root = AnyView(VirtualKeyboardView().scrollEdgeEffectHidden(true, for: .all))
    } else {
      root = AnyView(VirtualKeyboardView())
    }
    let hosting = UIHostingController(rootView: root)
    hosting.sizingOptions = .intrinsicContentSize
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    hosting.view.backgroundColor = .clear
    addChild(hosting)
    view.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    hosting.didMove(toParent: self)
    hostingController = hosting
    vm.clearInputPanel()
  }

  /// Bulk mode: one list that scrolls, in the bar and in the expanded grid. Near its
  /// end the panel calls scroll() (FcitxBackend), which reads the engine's next pages.
  override func showCandidates(_ candidates: [String], preedit: String, selected: Int, more: Bool) {
    setCandidatesAsync(
      program, inputContext, "", "", 0, candidates, candidates.isEmpty ? -1 : Int32(selected), true,
      !preedit.isEmpty, "[]", false, false, !more)
  }

  override func appendCandidates(_ candidates: [String], end: Bool) {
    scrollAsync(program, inputContext, candidates, end)
  }

  // Overrides cannot live in an extension; the work is in DocumentEditing.swift.
  override func moveCursor(_ code: String) { moveCursorInDocument(code) }
  override func documentDidChange() { observeDocument() }

  /// mode=type's commands for what this keyboard adds: the panel's reset, its symbol
  /// grid and backspace slide (through the panel's own view model), undo, redo, and
  /// the clipboard.
  override func typeCommand(_ token: String) -> Bool {
    switch token {
    case "{reset}": resetInput()
    case "{undo}": undo()
    case "{redo}": redo()
    case "{cut}": cut()
    case "{copy}": copySelection()
    case "{paste}": paste()
    default:
      let argument = String(token.dropFirst().dropLast().split(separator: ":", maxSplits: 1).last ?? "")
      if token.hasPrefix("{slide:"), let step = Int(argument) {
        vm.slideBackspace(step)
      } else if token.hasPrefix("{sym:") {
        resetInput()
        commitString(argument)
      } else {
        return false
      }
    }
    return true
  }

  // MARK: FcitxProtocol

  func isCurrentDocument(_ program: String, _ documentIdentifier: String) -> Bool {
    program == self.program
  }
  func isCurrentProgram(_ program: String) -> Bool { program == self.program }

  func keyPressed(_ key: String, _ code: String, _ modifiers: UInt32) {
    switch code {
    case "Backspace": pressDelete()
    case "Enter": pressSpecial(3, fallback: "\n")
    case "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End": pressCursorKey(code)
    default:
      if key == " " {
        pressSpecial(5, fallback: " ")
      } else if !key.isEmpty {
        pressText(key)
      }
    }
  }

  /// The panel resets before a symbol from its grid, when it switches to the number
  /// pad, and when a slide on backspace ends over a composition. That last one means
  /// "clear it" (as in fcitx5); for the others committing first reads better than
  /// losing what was typed. What follows in the same event decides; alone, it commits.
  func resetInput() {
    guard !resetPending else { return }
    resetPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.resetPending else { return }
      self.resetPending = false
      self.commitComposition()
    }
  }

  /// The pending reset, settled by the call that followed it.
  private func settleReset(commit: Bool) {
    guard resetPending else { return }
    resetPending = false
    if commit { commitComposition() } else { clearComposition() }
  }

  func forwardKey(_ key: String, _ code: String) {
    settleReset(commit: true)
    insertAfterKeys(key)
  }
  func carriageReturn() {
    settleReset(commit: true)
    insertAfterKeys("\n")
  }
  func commitString(_ string: String) {
    settleReset(commit: true)
    insertAfterKeys(string)
  }
  func triggerUnicode() {}
  func triggerQuickPhrase() {}
  // The engine composes through marked text and never asks for these.
  func deleteSurroundingText(_ offset: Int, _ size: Int) {}
  func setPreedit(_ preedit: String, _ cursor: Int) {}
  func globe() { advanceToNextInputMode() }
  func setCurrentInputMethod(_ inputMethod: String) {
    setInputMode(inputMethod == Self.inputMethods[1].name ? 1 : 0)
  }
  func terminateExtension() { exit(0) }
  func slideBackspace(_ step: Int) {
    if step == 0 && resetPending {
      settleReset(commit: false)  // the slide ended over a composition: clear it
      return
    }
    slideBackspaceInDocument(step)
  }
  func syncConfig() {}
  func clipboardMonitoringEnabled() -> Bool { false }
  func setClipboardMonitoring(_ enabled: Bool) {}
  func hasKeyboardFullAccess() -> Bool { hasFullAccess }
  func currentDocumentInfo() -> DocumentInfo {
    DocumentInfo(
      processStartTime: nil, capturedAt: Date(), processIdentifier: getpid(),
      memoryFootprint: EngineBridge.footprint(), availableMemory: EngineBridge.available(),
      currentDocumentIdentifier: nil, keyboardType: "default",
      documentContextBeforeInput: textDocumentProxy.documentContextBeforeInput,
      selectedText: textDocumentProxy.selectedText,
      documentContextAfterInput: textDocumentProxy.documentContextAfterInput)
  }
}
