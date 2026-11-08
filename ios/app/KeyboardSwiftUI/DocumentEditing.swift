import UIKit

// Editing the document around the composition: cursor keys the engine leaves alone,
// the backspace slide, undo and redo, cut, copy and paste, and noticing that another
// field took focus. Adapted from fcitx5-ios keyboard/KeyboardViewController.swift
// (GPL-3.0, as this project is). UndoRedoManager, UndoRedoDocumentState, firstLine
// and lastLine are upstream's own files, which scripts/import_fcitx_ui.sh brings in
// with the panel.
extension KeyboardViewController {
  private static let pollInterval: TimeInterval = 0.2
  nonisolated(unsafe) private static var clipboard = ""

  // MARK: - Document state

  /// UITextDocumentProxy's documentIdentifier, read through Objective-C: Swift imports
  /// it as a non-optional UUID and traps while a field is going away (fcitx5-ios).
  func currentDocumentIdentifier() -> String {
    let selector = NSSelectorFromString("documentIdentifier")
    guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: selector),
      let identifier = proxy.perform(selector)?.takeUnretainedValue() as? NSUUID
    else { return "" }
    return identifier.uuidString
  }

  func currentDocumentState() -> UndoRedoDocumentState {
    UndoRedoDocumentState(
      identifier: currentDocumentIdentifier(),
      contextBeforeInput: textDocumentProxy.documentContextBeforeInput,
      selectedText: textDocumentProxy.selectedText,
      contextAfterInput: textDocumentProxy.documentContextAfterInput)
  }

  private func showUndoRedo() { vm.setUndoRedo(undoRedo.canUndo, undoRedo.canRedo) }

  /// Records the document as it is now; a change since the last record becomes an undo
  /// step. Marked text is ours and not an edit yet, so it is only noted.
  func observeDocument() {
    let state = currentDocumentState()
    if preedit.isEmpty { undoRedo.update(to: state) }
    documentState = state
    showUndoRedo()
  }

  func resetUndoRedo() {
    let state = currentDocumentState()
    undoRedo.reset(to: state)
    documentState = state
    showUndoRedo()
  }

  /// Clears what is composed from this document and from the engine.
  func clearComposition() {
    guard !preedit.isEmpty else { return }
    textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
    textDocumentProxy.unmarkText()
    forgetComposition()
  }

  /// Polls while the keyboard shows, as fcitx5-ios does: a third-party keyboard never
  /// gets selectionDidChange. Another field drops the composition, which belongs to
  /// the old one; edits the host makes (its own menu, say) become undo steps.
  func startDocumentPolling() {
    resetUndoRedo()
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
    documentState = nil
    undoRedo.reset()
    cancelVerticalMoves()
    slidingBackspace = false
    showUndoRedo()
  }

  private func pollDocument() {
    let state = currentDocumentState()
    if state.identifier != documentState?.identifier {
      cancelVerticalMoves()
      slidingBackspace = false
      forgetComposition()
      undoRedo.reset(to: state)
      documentState = state
      showUndoRedo()
      vm.clearInputPanel()
      return
    }
    if changingLines {
      undoRedo.reset(to: state)
      documentState = state
      showUndoRedo()
      return
    }
    if slidingBackspace || !preedit.isEmpty {
      documentState = state
      return
    }
    guard state != documentState else { return }
    observeDocument()
  }

  /// Runs action later only if the same field still has focus.
  private func onCurrentDocument(
    after delay: TimeInterval = 0, _ action: @escaping @MainActor () -> Void
  ) {
    let identifier = currentDocumentIdentifier()
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard self.currentDocumentIdentifier() == identifier else {
          self.cancelVerticalMoves()
          self.resetUndoRedo()
          return
        }
        action()
      }
    }
  }

  // MARK: - Cursor

  private func atStartOfLaterLine() -> Bool {
    textDocumentProxy.documentContextBeforeInput?.last?.isNewline ?? false
  }

  private func cancelVerticalMoves() {
    verticalMove &+= 1
    movingVertically = false
    changingLines = false
  }

  /// The proxy reports only part of the document and moves the caret by UTF-16
  /// offsets; it updates its context a moment after each move, hence the delays.
  func moveCursorInDocument(_ code: String) {
    let proxy = textDocumentProxy
    switch code {
    case "ArrowLeft":
      let before = proxy.documentContextBeforeInput ?? ""
      let changesLine = atStartOfLaterLine()
      proxy.adjustTextPosition(byCharacterOffset: -max(1, before.suffix(1).utf16.count))
      if changesLine { resetUndoRedo() }
    case "ArrowRight":
      let after = proxy.documentContextAfterInput ?? ""
      proxy.adjustTextPosition(byCharacterOffset: max(1, after.prefix(1).utf16.count))
      onCurrentDocument(after: 0.1) {
        if self.atStartOfLaterLine() { self.resetUndoRedo() }
      }
    case "Home":
      let before = proxy.documentContextBeforeInput ?? ""
      proxy.adjustTextPosition(byCharacterOffset: -lastLine(before).utf16.count)
    case "End":
      let after = proxy.documentContextAfterInput ?? ""
      proxy.adjustTextPosition(byCharacterOffset: firstLine(after).utf16.count)
    case "ArrowUp": moveUp()
    case "ArrowDown": moveDown()
    default: break
    }
  }

  /// To the same column of the previous line: the start of this line, past the newline,
  /// then forward again once the previous line can be read.
  private func moveUp() {
    guard !movingVertically else { return }
    cancelVerticalMoves()
    movingVertically = true
    let generation = verticalMove
    let line = lastLine(textDocumentProxy.documentContextBeforeInput ?? "")
    let column = line.count
    textDocumentProxy.adjustTextPosition(byCharacterOffset: -line.utf16.count)
    onCurrentDocument(after: 0.1) {
      guard self.verticalMove == generation else { return }
      self.changingLines = self.atStartOfLaterLine()
      self.textDocumentProxy.adjustTextPosition(byCharacterOffset: -1)
      guard self.changingLines else {
        self.movingVertically = false
        return
      }
      self.onCurrentDocument(after: 0.1) {
        guard self.verticalMove == generation else { return }
        let previous = lastLine(self.textDocumentProxy.documentContextBeforeInput ?? "")
        if previous.count > column {
          self.textDocumentProxy.adjustTextPosition(
            byCharacterOffset: -previous.suffix(previous.count - column).utf16.count)
        }
        self.changingLines = false
        self.movingVertically = false
        self.resetUndoRedo()
      }
    }
  }

  /// To the same column of the next line: the end of this line, over the newline, then
  /// along the next line once it can be read.
  private func moveDown() {
    guard !movingVertically else { return }
    cancelVerticalMoves()
    movingVertically = true
    let generation = verticalMove
    let column = lastLine(textDocumentProxy.documentContextBeforeInput ?? "").count
    let rest = firstLine(textDocumentProxy.documentContextAfterInput ?? "")
    textDocumentProxy.adjustTextPosition(byCharacterOffset: rest.utf16.count)
    onCurrentDocument {
      guard self.verticalMove == generation else { return }
      self.textDocumentProxy.adjustTextPosition(byCharacterOffset: 1)
      self.onCurrentDocument(after: 0.1) {
        guard self.verticalMove == generation else { return }
        self.changingLines = self.atStartOfLaterLine()
        guard self.changingLines else {
          self.movingVertically = false
          return
        }
        let next = firstLine(self.textDocumentProxy.documentContextAfterInput ?? "")
        self.textDocumentProxy.adjustTextPosition(
          byCharacterOffset: next.prefix(min(column, next.count)).utf16.count)
        self.changingLines = false
        self.movingVertically = false
        self.resetUndoRedo()
      }
    }
  }

  // MARK: - Backspace slide

  /// Sliding left on backspace deletes a character per step, sliding back restores
  /// them, and letting go (step 0) keeps what is deleted.
  func slideBackspaceInDocument(_ step: Int) {
    if step == 0 {
      removedBySlide = ""
      if slidingBackspace {
        slidingBackspace = false
        observeDocument()
      }
      return
    }
    if !slidingBackspace {
      observeDocument()
      slidingBackspace = true
    }
    if step < 0 {
      let removal = String((textDocumentProxy.documentContextBeforeInput ?? "").suffix(-step))
      removedBySlide = removal + removedBySlide
      for _ in 0..<removal.count { textDocumentProxy.deleteBackward() }
    } else {
      let refill = String(removedBySlide.prefix(step))
      removedBySlide = String(removedBySlide.dropFirst(refill.count))
      textDocumentProxy.insertText(refill)
    }
    documentState = currentDocumentState()
  }

  // MARK: - Undo and redo

  func undo() {
    clearComposition()
    undoRedo.undo(from: currentDocumentState()) { self.applyReplacement($0) }
    documentState = currentDocumentState()
    showUndoRedo()
  }

  func redo() {
    clearComposition()
    undoRedo.redo(from: currentDocumentState()) { self.applyReplacement($0) }
    documentState = currentDocumentState()
    showUndoRedo()
  }

  /// Puts back a recorded line-relative edit through the proxy: move to its end,
  /// delete it, insert the other text, then place the caret where it was.
  private func applyReplacement(_ replacement: UndoRedoReplacement) -> UndoRedoDocumentState? {
    let proxy = textDocumentProxy
    guard let line = currentDocumentState().lineForUndoRedo,
      replacement.range.lowerBound >= 0, replacement.range.upperBound <= line.text.count,
      replacement.finalCaret >= 0, replacement.finalCaret <= replacement.expectedText.count
    else { return nil }
    if !line.selectedText.isEmpty {
      if line.selectionStart..<line.selectionEnd == replacement.range {
        if replacement.text.isEmpty { proxy.deleteBackward() } else { proxy.insertText(replacement.text) }
      } else {
        // Collapse an unrelated selection at its end, then edit at the recorded range.
        proxy.insertText(line.selectedText)
        proxy.adjustTextPosition(
          byCharacterOffset: utf16Offset(
            in: line.text, from: line.selectionEnd, to: replacement.range.upperBound))
        for _ in replacement.range { proxy.deleteBackward() }
        if !replacement.text.isEmpty { proxy.insertText(replacement.text) }
      }
    } else {
      proxy.adjustTextPosition(
        byCharacterOffset: utf16Offset(
          in: line.text, from: line.selectionStart, to: replacement.range.upperBound))
      for _ in replacement.range { proxy.deleteBackward() }
      if !replacement.text.isEmpty { proxy.insertText(replacement.text) }
    }
    let naturalCaret = replacement.range.lowerBound + replacement.text.count
    proxy.adjustTextPosition(
      byCharacterOffset: utf16Offset(
        in: replacement.expectedText, from: naturalCaret, to: replacement.finalCaret))
    return currentDocumentState()
  }

  private func utf16Offset(in text: String, from start: Int, to end: Int) -> Int {
    let startIndex = text.index(text.startIndex, offsetBy: start)
    let endIndex = text.index(text.startIndex, offsetBy: end)
    return start <= end
      ? text[startIndex..<endIndex].utf16.count : -text[endIndex..<startIndex].utf16.count
  }

  // MARK: - Clipboard

  /// Without Full Access the system pasteboard is out of reach, so copy and paste work
  /// within the keyboard only (fcitx5-ios does the same).
  func copy() { copySelection() }

  /// copy() alone is ambiguous next to NSObject's copy() -> Any.
  func copySelection() {
    guard let text = textDocumentProxy.selectedText, !text.isEmpty else { return }
    Self.clipboard = text
    if hasFullAccess { UIPasteboard.general.string = text }
  }

  func cut() {
    guard let text = textDocumentProxy.selectedText, !text.isEmpty else { return }
    copySelection()
    textDocumentProxy.deleteBackward()
    observeDocument()
  }

  func paste() {
    let text = (hasFullAccess ? UIPasteboard.general.string : nil) ?? Self.clipboard
    guard !text.isEmpty else { return }
    commitString(text)
  }
}
