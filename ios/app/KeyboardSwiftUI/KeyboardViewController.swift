import SwiftUI
import UIKit

// The fcitx5-ios SwiftUI panel in front of the Cassotis engine. FcitxProtocol is
// the panel's view of its host: keyPressed is the one busy method, the place where
// fcitx5-ios calls Fcitx.processKey and this calls the engine. Everything else is
// either plain UITextDocumentProxy work or a feature phase 0 leaves empty.
final class KeyboardViewController: CommandKeyboardController, FcitxProtocol {
  nonisolated(unsafe) static weak var current: KeyboardViewController?
  private let program = UUID().uuidString
  private let inputContext = "cassotis"
  private var hostingController: UIHostingController<AnyView>?

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

  override func showCandidates(_ candidates: [String], preedit: String) {
    setCandidatesAsync(
      program, inputContext, "", "", 0, candidates, 0, false, !preedit.isEmpty, "[]", false,
      false, true)
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
    default:
      if key == " " {
        pressSpecial(5, fallback: " ")
      } else if !key.isEmpty {
        pressText(key)
      }
    }
  }

  func forwardKey(_ key: String, _ code: String) { textDocumentProxy.insertText(key) }
  func carriageReturn() { textDocumentProxy.insertText("\n") }
  func resetInput() { resetComposition() }
  func triggerUnicode() {}
  func triggerQuickPhrase() {}
  func commitString(_ string: String) { textDocumentProxy.insertText(string) }
  func deleteSurroundingText(_ offset: Int, _ size: Int) {}
  func setPreedit(_ preedit: String, _ cursor: Int) {}
  func cut() {}
  func copy() {}
  func paste() {}
  func undo() {}
  func redo() {}
  func globe() { advanceToNextInputMode() }
  func setCurrentInputMethod(_ inputMethod: String) {}
  func terminateExtension() { exit(0) }
  func slideBackspace(_ step: Int) {}
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
