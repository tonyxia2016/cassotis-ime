import UIKit

// Watching the field and moving the caret. A third-party keyboard never gets
// selectionDidChange, so the field is polled while the keyboard shows, as fcitx5-ios
// does: another field taking focus drops the composition, which belongs to the old one.
// The caret moves for the space bar's trackpad and for cursor keys the engine leaves
// alone (it moves the candidate highlight while something is composed).
extension KeyboardViewController {
  private static let pollInterval: TimeInterval = 0.2

  /// UITextDocumentProxy's documentIdentifier, read through Objective-C: Swift imports
  /// it as a non-optional UUID and traps while a field is going away (fcitx5-ios).
  func currentDocumentIdentifier() -> String {
    let selector = NSSelectorFromString("documentIdentifier")
    guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: selector),
      let identifier = proxy.perform(selector)?.takeUnretainedValue() as? NSUUID
    else { return "" }
    return identifier.uuidString
  }

  func startDocumentPolling() {
    documentIdentifier = currentDocumentIdentifier()
    guard documentTimer == nil else { return }
    // Added to the main run loop, so it fires on the main actor.
    let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollDocument() }
    }
    RunLoop.main.add(timer, forMode: .common)
    documentTimer = timer
  }

  func stopDocumentPolling() {
    documentTimer?.invalidate()
    documentTimer = nil
  }

  private func pollDocument() {
    let identifier = currentDocumentIdentifier()
    guard identifier != documentIdentifier else { return }
    documentIdentifier = identifier
    forgetComposition()
    closeOverlays()
    updateReturnKey()
  }

  /// One character left or right, in UTF-16 units as the proxy counts them.
  func moveCursorInDocument(_ code: String) {
    let proxy = textDocumentProxy
    switch code {
    case "ArrowLeft":
      let before = proxy.documentContextBeforeInput ?? ""
      proxy.adjustTextPosition(byCharacterOffset: -max(1, before.suffix(1).utf16.count))
    case "ArrowRight":
      let after = proxy.documentContextAfterInput ?? ""
      proxy.adjustTextPosition(byCharacterOffset: max(1, after.prefix(1).utf16.count))
    case "Home":
      let before = proxy.documentContextBeforeInput ?? ""
      let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
      proxy.adjustTextPosition(byCharacterOffset: -line.utf16.count)
    case "End":
      let after = proxy.documentContextAfterInput ?? ""
      let line = after.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
      proxy.adjustTextPosition(byCharacterOffset: line.utf16.count)
    default: break
    }
  }
}
