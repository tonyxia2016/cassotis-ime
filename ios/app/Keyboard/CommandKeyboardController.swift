import UIKit

// What both POC keyboards share: the engine on its one thread, the document proxy,
// memory marks, and a command channel through the text field so runs need no one
// at the phone. A subclass only supplies the keys and draws the candidates:
//   Keyboard/KeyboardViewController.swift          plain UIKit, the floor
//   KeyboardSwiftUI/KeyboardViewController.swift   言泉, in the style of iOS's pinyin keyboard

/// One thread that outlives the engine, as cassotis_core.h demands. A serial
/// DispatchQueue would hop between pool threads.
///
/// Besides the jobs, one idle job: the poll that brings the character LM's
/// ranking for the last key (char_lm_deferred). It runs only when no job
/// waits, so keys typed quickly never wait for the model, and a newer one
/// replaces it.
final class EngineThread {
  private let condition = NSCondition()
  private var jobs: [() -> Void] = []
  private var idle: (() -> Void)?
  private var later: [() -> Void] = []
  private var idleRunning = false
  private var idleInterrupted = false
  private var thread: Thread?

  init() {
    let thread = Thread { [unowned self] in self.loop() }
    thread.stackSize = 4 << 20
    thread.qualityOfService = .userInteractive
    thread.name = "cassotis.engine"
    self.thread = thread
    thread.start()
  }

  /// interruptsPoll: a key that edits the composition cuts a running poll
  /// short (cassotis_core_interrupt), since it will rebuild the candidates
  /// anyway. Other work, a commit above all, waits for the poll, so that what
  /// it commits is what the model ranked.
  func run(interruptsPoll: Bool = false, _ job: @escaping () -> Void) {
    condition.lock()
    jobs.append(job)
    let interrupt = interruptsPoll && idleRunning && !idleInterrupted
    if interrupt { idleInterrupted = true }
    condition.signal()
    condition.unlock()
    if interrupt { EngineBridge.interrupt() }
  }

  func runWhenIdle(_ job: @escaping () -> Void) {
    condition.lock()
    idle = job
    condition.signal()
    condition.unlock()
  }

  /// Lowest priority, after the poll: reading more candidates for a list the user
  /// scrolls, so that neither keys nor the model's ranking wait for it.
  func runAfterIdle(_ job: @escaping () -> Void) {
    condition.lock()
    later.append(job)
    condition.signal()
    condition.unlock()
  }

  /// Forgets a poll that has not started; one that runs is interrupted instead.
  func dropIdle() {
    condition.lock()
    idle = nil
    condition.unlock()
  }

  /// On the engine thread, in the idle job: whether a key interrupted it.
  func idleWasInterrupted() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return idleInterrupted
  }

  private func loop() {
    while true {
      condition.lock()
      while jobs.isEmpty && idle == nil && later.isEmpty { condition.wait() }
      let job: () -> Void
      var isIdle = false
      if !jobs.isEmpty {
        job = jobs.removeFirst()
      } else if let poll = idle {
        job = poll
        idle = nil
        isIdle = true
        idleRunning = true
        idleInterrupted = false
      } else {
        job = later.removeFirst()
      }
      condition.unlock()
      autoreleasepool(invoking: job)
      if isIdle {
        condition.lock()
        idleRunning = false
        condition.unlock()
      }
    }
  }
}

private struct Mark {
  let name: String
  let footprint: UInt64
  let peak: UInt64
  let available: UInt64
}

class CommandKeyboardController: UIInputViewController {
  static let thread = EngineThread()
  static let engine = EngineBridge()
  private static var engineState = 0  // 0 closed, 1 opening, 2 open, 3 failed
  private static var engineError = ""
  private static var marks: [Mark] = []

  private var pollTimer: Timer?
  private var running = false
  private(set) var preedit = ""
  /// The last result drawn, for mode=type's report.
  private var lastResult = CassotisKeyResult()
  /// The list on screen: the result's candidates, then what scrolling read.
  private(set) var shownCandidates: [String] = []
  private var candidateGeneration = 0

  /// Where dict_sc.db, schema.sql and corpus.tsv live for this extension.
  var resourceDirectory: String { Bundle.main.resourcePath ?? "" }
  /// Whether the engine has opened (it opens with the first key).
  var engineIsOpen: Bool { Self.engineState == 2 }

  func buildKeyboard() {}
  /// more: further pages follow, which loadCandidates reads when the list scrolls.
  /// selected: the highlighted one, which space takes (-1 for none).
  func showCandidates(_ candidates: [String], preedit: String, selected: Int, more: Bool) {}
  /// The next part of the list on screen; end: there is nothing after it.
  func appendCandidates(_ candidates: [String], end: Bool) {}
  /// The engine's one Tab completion for what is composed, or "" (acceptCompletion
  /// takes it). predicted: text the engine guessed, drawn in the accent colour.
  func showCompletion(_ text: String, predicted: Bool) {}
  /// The keyboard just changed the document (committed, deleted, inserted): the
  /// SwiftUI keyboard records it for undo.
  func documentDidChange() {}
  /// A cursor key the engine left alone: move in the document (ArrowLeft, ArrowRight,
  /// ArrowUp, ArrowDown, Home, End). The plain keyboard has no such keys.
  func moveCursor(_ code: String) {}
  /// mode=type's {…} tokens that only a subclass can carry out; true when handled.
  func typeCommand(_ token: String) -> Bool { false }
  /// What a subclass adds to mode=type's report.
  func typeReport() -> [String: Any] { [:] }

  static func mark(_ name: String) {
    marks.append(
      Mark(
        name: name, footprint: EngineBridge.footprint(), peak: EngineBridge.footprintPeak(),
        available: EngineBridge.available()))
  }

  private static var dataDirectory: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let folder = base.appendingPathComponent("Cassotis", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.path
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    Self.mark("viewDidLoad")
    buildKeyboard()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Self.mark("viewDidAppear")
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.pollCommand()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    pollTimer?.invalidate()
    pollTimer = nil
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    Self.mark("memoryWarning")
    Self.thread.run { Self.engine.trim(1) }
  }

  /// The engine opens with the first key, not with the view: selecting a keyboard
  /// starts the extension before the user types, and a run must set its policy first.
  /// Typing learns (user_dict.db in this extension's container, which needs no Full
  /// Access); a measurement run opens the engine first and decides for itself.
  func withEngine(options: [String: String] = [:], learning: Bool = true,
    interruptsPoll: Bool = false, _ work: @escaping () -> Void)
  {
    if Self.engineState == 2 {
      Self.thread.run(interruptsPoll: interruptsPoll, work)
      return
    }
    guard Self.engineState == 0 else {
      Self.thread.run { if Self.engineState == 2 { work() } }
      return
    }
    Self.engineState = 1
    EngineBridge.applyMemoryPolicy(options)
    let resources = resourceDirectory
    let data = Self.dataDirectory
    // Typing opens with no options and gets the mode it left; a run starts in
    // Chinese, whatever the phone was last used for.
    let mode = options.isEmpty ? Self.rememberedMode : 0
    Self.thread.run {
      let dictionary = resources + "/dict_sc.db"
      let user = learning ? data + "/user_dict.db" : ""
      if let error = Self.engine.openDictionary(
        dictionary, userDictionary: user, resources: resources, data: data)
      {
        Self.engineError = error
        Self.engineState = 3
        NSLog("engine open failed: %@", error)
        return
      }
      Self.engineState = 2
      if mode != 0 { Self.engine.setInputMode(Int32(mode)) }
      Self.mark("engineOpen")
      NSLog("cassotis engine open, footprint %.1f MB", Double(EngineBridge.footprint()) / 1_048_576)
      work()
    }
  }

  // MARK: - Typing

  /// The text before the caret as the engine wants it: the last 1024 UTF-16 units,
  /// as on macOS, without half a surrogate pair. Read only while nothing is marked,
  /// so the composition is not part of it; nil when the host reports nothing.
  private func leftContext() -> String? {
    guard let text = textDocumentProxy.documentContextBeforeInput else { return nil }
    let units = text as NSString
    guard units.length > 1024 else { return text }
    var start = units.length - 1024
    if CFStringIsSurrogateLowCharacter(units.character(at: start)) { start += 1 }
    return units.substring(from: start)
  }

  /// What a key sends before itself: the left context, when this key may start a
  /// composition. The engine thread checks again, since keys still queued there
  /// may have opened one that the main thread has not drawn yet.
  private func contextForKey() -> (sync: Bool, text: String?) {
    preedit.isEmpty ? (true, leftContext()) : (false, nil)
  }

  private static func syncContext(_ context: (sync: Bool, text: String?)) {
    if context.sync && !engine.composing { engine.setLeftContext(context.text) }
  }

  func pressText(_ text: String) {
    // A pinyin letter edits the composition; punctuation commits.
    let edits = text.count == 1 && text.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || $0 == "'"
    }
    let digit = text.count == 1 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    let context = contextForKey()
    let preceding = text == "." && preedit.isEmpty ? precedingDigit() : 0
    let sentAt = CFAbsoluteTimeGetCurrent()  // the key's release, for mode=type's measure
    let measure = measuring && Self.isPinyinLetter(text)
    withEngine(interruptsPoll: edits) {
      Self.syncContext(context)
      // A digit typed on screen is a digit: the composition is committed first
      // instead of the digit picking a candidate as on a hardware keyboard.
      if digit && Self.engine.digitsSelect, let committed = Self.engine.commitComposition() {
        DispatchQueue.main.async { self.apply(committed) }
      }
      var result = Self.engine.pressText(text, precedingDigit: preceding)
      // What the engine passes on (English mode, say) the keyboard types itself,
      // as macOS leaves it to the application; anything composed goes first.
      let passThrough = !result.handled && result.commit.isEmpty
      if passThrough && Self.engine.composing, let committed = Self.engine.commitComposition() {
        result = committed
      }
      DispatchQueue.main.async {
        self.apply(result)
        if passThrough {
          self.textDocumentProxy.insertText(text)
          self.documentDidChange()
        }
        if measure { self.releaseTimes.append((CFAbsoluteTimeGetCurrent() - sentAt) * 1000) }
      }
      if result.pending { self.pollWhenIdle() }
    }
  }

  /// The ASCII digit right before the caret, for '.' after a number; full-width
  /// digits count as theirs. 0 when there is none.
  private func precedingDigit() -> UInt16 {
    guard let last = textDocumentProxy.documentContextBeforeInput?.unicodeScalars.last else {
      return 0
    }
    if ("0"..."9").contains(last) { return UInt16(last.value) }
    if (0xFF10...0xFF19).contains(last.value) { return UInt16(last.value - 0xFF10 + 0x30) }
    return 0
  }

  /// otherwise: what to do on the main thread when the engine passes the key on and
  /// there is no fallback text (backspace deletes from the field).
  func pressSpecial(_ code: UInt16, fallback: String?, otherwise: (() -> Void)? = nil) {
    let context = contextForKey()
    withEngine(interruptsPoll: code == 1) {  // 1: backspace
      Self.syncContext(context)
      let result = Self.engine.pressSpecial(code)
      // Space or return with nothing composed: the engine leaves it to the field.
      let passThrough = !result.handled && result.commit.isEmpty && result.preedit.isEmpty
      DispatchQueue.main.async {
        self.apply(result)
        if passThrough {
          if let fallback {
            self.textDocumentProxy.insertText(fallback)
            self.documentDidChange()
          } else {
            otherwise?()
          }
        }
      }
      if result.pending { self.pollWhenIdle() }
    }
  }

  /// A cursor key (special 7–12): it moves within the composition while there is
  /// one and the engine takes it; otherwise it moves the caret in the document.
  func pressCursorKey(_ code: String) {
    let specials: [String: UInt16] = [
      "ArrowLeft": 7, "ArrowRight": 8, "ArrowUp": 9, "ArrowDown": 10, "Home": 11, "End": 12,
    ]
    guard let special = specials[code], !preedit.isEmpty, Self.engineState == 2 else {
      moveCursor(code)
      return
    }
    withEngine {
      let result = Self.engine.pressSpecial(special)
      DispatchQueue.main.async {
        if result.handled { self.apply(result) } else { self.moveCursor(code) }
      }
    }
  }

  /// Forgets the composition without touching the document, which may no longer be
  /// the one it was typed in (another field has focus).
  func forgetComposition() {
    if !preedit.isEmpty {
      preedit = ""
      lastResult = CassotisKeyResult()
      candidateGeneration &+= 1
      shownCandidates = []
      showCandidates([], preedit: "", selected: -1, more: false)
      showCompletion("", predicted: false)
    }
    guard Self.engineState == 2 else { return }
    Self.thread.run { Self.engine.resetComposition() }
  }

  /// Commits the composition before the keyboard goes away (another keyboard, or
  /// dismissed), as macOS commits on deactivation. Waits a moment for the engine;
  /// if it is busy, UIKit keeps the marked text as it is.
  func commitCompositionNow() {
    guard !preedit.isEmpty, Self.engineState == 2 else { return }
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox()
    Self.thread.run {
      box.result = Self.engine.commitComposition()
      done.signal()
    }
    if done.wait(timeout: .now() + 0.3) == .success, let result = box.result {
      apply(result)
    }
  }

  private final class ResultBox: @unchecked Sendable { var result: CassotisKeyResult? }

  /// Commits what is composed with its first candidates, as macOS does when focus
  /// moves: before a symbol from the panel, a switch of mode, and the like.
  func commitComposition() {
    guard Self.engineState != 0 else { return }
    withEngine {
      guard let result = Self.engine.commitComposition() else { return }
      DispatchQueue.main.async { self.apply(result) }
    }
  }

  /// Text from outside the engine (a symbol, a forwarded key), after every key and
  /// commit already queued, so it lands in the order it was typed.
  func insertAfterKeys(_ text: String) {
    guard Self.engineState != 0 else {
      textDocumentProxy.insertText(text)
      documentDidChange()
      return
    }
    Self.thread.run {
      DispatchQueue.main.async {
        self.textDocumentProxy.insertText(text)
        self.documentDidChange()
      }
    }
  }

  // MARK: - Input mode

  /// 0 Chinese, 1 English. The engine does not save it (macOS remembers it per
  /// application), so the keyboard does, in its own defaults.
  static var rememberedMode: Int {
    get { UserDefaults.standard.integer(forKey: "cassotis.inputMode") }
    set { UserDefaults.standard.set(newValue, forKey: "cassotis.inputMode") }
  }

  /// The mode changed or is known: subclasses show it (the space bar's label).
  func showInputMode(_ mode: Int) {}

  func setInputMode(_ mode: Int) {
    Self.rememberedMode = mode
    showInputMode(mode)
    guard Self.engineState != 0 else { return }  // applied when the engine opens
    withEngine {
      if let committed = Self.engine.commitComposition() {
        DispatchQueue.main.async { self.apply(committed) }
      }
      Self.engine.setInputMode(Int32(mode))
      DispatchQueue.main.async { self.apply(CassotisKeyResult()) }
    }
  }

  /// The model's ranking for the last key, once the engine thread is free, and
  /// after it the Tab completion's background work (char_lm_async), which the
  /// engine hands over only when polled: while what is drawn is still pending, poll
  /// again every 30 ms, for 3 s at most, as macOS does on its 25 ms timer.
  /// A poll a key interrupted is dropped: that key's own result follows. A poll
  /// answers for the engine's latest key, and a letter taken at touch-down may be
  /// ahead of the screen, so only a result for what is drawn (same query) applies.
  private func pollWhenIdle(attempt: Int = 0) {
    Self.thread.runWhenIdle { [weak self] in
      let result = Self.engine.poll()
      guard !Self.thread.idleWasInterrupted() else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        guard result.handled else {
          if self.lastResult.pending { self.pollAgain(attempt) }  // nothing new yet
          return
        }
        guard result.query == self.lastResult.query else {
          self.pollsDropped += 1
          return
        }
        self.pollsApplied += 1
        self.apply(result)
        if result.pending { self.pollAgain(attempt) }
      }
    }
  }

  /// The next poll of a chain, unless a newer result has been drawn (it polls for
  /// itself) or a letter is down: the engine already has that letter, and a poll
  /// would take its model ranking before the screen shows it, so it would be dropped.
  private func pollAgain(_ attempt: Int) {
    guard attempt < 100 else { return }
    let drawn = lastResult
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
      guard let self, self.lastResult === drawn, self.speculations.isEmpty else { return }
      self.pollWhenIdle(attempt: attempt + 1)
    }
  }

  /// The completion row was tapped: the engine takes its completion, as macOS does
  /// on Tab. Like space, it waits for a running poll.
  func acceptCompletion() {
    guard !shownCompletion.isEmpty else { return }
    withEngine {
      let result = Self.engine.acceptCompletion()
      DispatchQueue.main.async { self.apply(result) }
      if result.pending { self.pollWhenIdle() }
    }
  }

  /// Backspace goes through the engine whenever it is open, so that it lands after
  /// any key still on its way there (a letter taken at touch-down, a fast tap); with
  /// nothing composed the engine passes it on and the field loses a character.
  func pressDelete() {
    guard Self.engineState != 0 else {
      textDocumentProxy.deleteBackward()
      documentDidChange()
      return
    }
    pressSpecial(1, fallback: nil) {
      self.textDocumentProxy.deleteBackward()
      self.documentDidChange()
    }
  }

  // MARK: - Compute on key-down

  /// A pinyin letter the engine took at touch-down. The panel sends the key when the
  /// finger lifts, and then its result, already computed, is drawn. A long press or a
  /// swipe drops the press: backspace takes the letter back out of the engine, and
  /// nothing of it was ever drawn.
  private final class Speculation {
    let text: String
    var result: CassotisKeyResult?
    var passThrough = false
    var released = false
    var releasedAt: CFAbsoluteTime = 0
    init(text: String) { self.text = text }
  }
  private var speculations: [Speculation] = []
  /// Off for a run that measures the plain path (spec=0).
  static var speculates = true
  /// mode=type's measurements: release-to-drawn times of letters, and polls.
  private var measuring = false
  private var releaseTimes: [Double] = []
  private var pollsApplied = 0
  private var pollsDropped = 0

  private static func isPinyinLetter(_ text: String) -> Bool {
    text.count == 1 && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
  }

  /// The panel's touch-down for a key (keyDownHook). Only a lowercase letter in
  /// Chinese mode starts early: backspace undoes it exactly. Punctuation, space and
  /// the like can commit, so they wait for the finger to lift.
  func keyDown(_ text: String, forward: Bool) {
    guard Self.speculates, !forward, Self.engineState == 2, Self.rememberedMode == 0,
      Self.isPinyinLetter(text)
    else { return }
    let speculation = Speculation(text: text)
    speculations.append(speculation)
    let context = contextForKey()
    Self.thread.run(interruptsPoll: true) {
      Self.thread.dropIdle()  // a queued poll would answer for this letter before it shows
      Self.syncContext(context)
      var result = Self.engine.pressText(text)
      let passThrough = !result.handled && result.commit.isEmpty
      if passThrough && Self.engine.composing, let committed = Self.engine.commitComposition() {
        result = committed
      }
      DispatchQueue.main.async {
        speculation.result = result
        speculation.passThrough = passThrough
        if speculation.released { self.finishSpeculation(speculation) }
      }
    }
  }

  /// A letter's touch-up: draws what keyDown computed, or sends the key as usual
  /// when nothing started early.
  func letterReleased(_ text: String) {
    guard let speculation = speculations.first(where: { !$0.released }),
      speculation.text == text
    else {
      pressText(text)
      return
    }
    speculation.released = true
    speculation.releasedAt = CFAbsoluteTimeGetCurrent()
    if speculation.result != nil { finishSpeculation(speculation) }
  }

  private func finishSpeculation(_ speculation: Speculation) {
    guard let result = speculation.result else { return }
    speculations.removeAll { $0 === speculation }
    apply(result)
    if speculation.passThrough {
      textDocumentProxy.insertText(speculation.text)
      documentDidChange()
    }
    if measuring {
      releaseTimes.append((CFAbsoluteTimeGetCurrent() - speculation.releasedAt) * 1000)
    }
    if result.pending { pollWhenIdle() }
  }

  /// The panel dropped the press keyDown started (keyCancelHook): take the letter
  /// back out of the engine. A long press then sends the character it chose.
  func keyCancelled() {
    guard let index = speculations.lastIndex(where: { !$0.released }) else { return }
    speculations.remove(at: index)
    Self.thread.run(interruptsPoll: true) {
      let result = Self.engine.pressSpecial(1)  // backspace removes exactly that letter
      if result.pending { self.pollWhenIdle() }
    }
  }

  /// index counts the whole list on screen, scrolled pages included.
  func pickCandidate(_ index: Int) {
    withEngine {
      guard let result = Self.engine.selectCandidate(Int32(index)) else { return }
      DispatchQueue.main.async { self.apply(result) }
      if result.pending { self.pollWhenIdle() }
    }
  }

  /// The list on screen scrolled near its end: candidates from start on. Read when
  /// the engine thread has nothing else to do; dropped if the list changed.
  func loadCandidates(_ start: Int, _ count: Int) {
    guard Self.engineState == 2 else { return }
    let generation = candidateGeneration
    Self.thread.runAfterIdle { [weak self] in
      var end = ObjCBool(false)
      let more = Self.engine.candidates(from: Int32(start), count: Int32(count), end: &end)
      DispatchQueue.main.async {
        guard let self, generation == self.candidateGeneration,
          start == self.shownCandidates.count
        else { return }
        self.shownCandidates.append(contentsOf: more)
        self.appendCandidates(more, end: end.boolValue || more.isEmpty)
      }
    }
  }

  func resetComposition() {
    withEngine {
      Self.engine.resetComposition()
      DispatchQueue.main.async { self.apply(CassotisKeyResult()) }
    }
  }

  func apply(_ result: CassotisKeyResult) {
    // A poll that brings only the Tab completion leaves the list as it is drawn,
    // scrolled pages and all.
    let sameList = result.commit.isEmpty && result.preedit == preedit
      && result.candidates == lastResult.candidates && result.page == lastResult.page
      && result.pages == lastResult.pages && result.selected == lastResult.selected
    lastResult = result
    if !result.commit.isEmpty {
      textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
      textDocumentProxy.unmarkText()
      textDocumentProxy.insertText(result.commit)
    }
    if result.preedit != preedit {
      preedit = result.preedit
      textDocumentProxy.setMarkedText(
        preedit, selectedRange: NSRange(location: (preedit as NSString).length, length: 0))
      if preedit.isEmpty { textDocumentProxy.unmarkText() }
    }
    if !sameList {
      candidateGeneration &+= 1
      shownCandidates = result.candidates
      showCandidates(
        result.candidates, preedit: preedit, selected: Int(result.selected),
        more: result.pages > result.page + 1)
    }
    showCompletion(shownCompletion, predicted: result.completionPredicted)
    if !result.commit.isEmpty { documentDidChange() }
  }

  /// The completion on screen: only while something is composed, as macOS hides its
  /// candidate window, completion row and all, once nothing is.
  var shownCompletion: String { preedit.isEmpty ? "" : lastResult.completion }

  // MARK: - Commands from the host

  private func pollCommand() {
    guard !running, let context = textDocumentProxy.documentContextBeforeInput,
      let start = context.range(of: "@@run "),
      let end = context.range(of: "@@", range: start.upperBound..<context.endIndex)
    else { return }
    let text = String(context[start.upperBound..<end.lowerBound])
    for _ in 0..<context.distance(from: start.lowerBound, to: context.endIndex) {
      textDocumentProxy.deleteBackward()
    }
    var options: [String: String] = [:]
    for pair in text.split(separator: " ") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { options[String(parts[0])] = String(parts[1]) }
    }
    run(options)
  }

  private func run(_ options: [String: String]) {
    running = true
    let number: (String, Int) -> Int = { name, fallback in
      options[name].flatMap(Int.init) ?? fallback
    }
    if options["mode"] == "exit" { exit(0) }
    if options["mode"] == "next" {
      running = false
      advanceToNextInputMode()
      return
    }
    if options["mode"] == "whoami" {
      report(
        "{\"bundle\":\"\(Bundle.main.bundleIdentifier ?? "")\",\"full_access\":\(hasFullAccess),"
          + "\"footprint_mb\":\(Self.megabytes(EngineBridge.footprint())),"
          + "\"available_mb\":\(Self.megabytes(EngineBridge.available()))}")
      running = false
      return
    }
    if options["mode"] == "probe" {
      report(probe())
      running = false
      return
    }
    if options["mode"] == "limit" {
      findLimit(step: number("step", 8), label: options["label"] ?? "limit")
      return
    }
    if options["mode"] == "mltest" {
      mlTest(
        lengths: (options["lengths"] ?? "64,128,256").split(separator: ",").compactMap {
          Int($0)
        }, units: options["units"] ?? "ne", label: options["label"] ?? "mltest")
      return
    }
    if options["mode"] == "idle" {
      idle(seconds: number("seconds", 600), label: options["label"] ?? "idle", options: options)
      return
    }
    if options["mode"] == "type" {
      typeKeys(options)
      return
    }
    let learning = number("learning", 0) == 1
    let label = options["label"] ?? "run"
    let keys = number("keys", 10000)
    let seconds = number("seconds", 0)
    let pace = number("pace", 0)
    let every = number("every", 500)
    let context = number("context", 0) == 1
    let loop = number("loop", 0) == 1
    let ui = number("ui", 1) == 1
    let corpus = resourceDirectory + "/corpus.tsv"
    let digest = Self.dataDirectory + "/digest-\(label).txt"
    let model = number("lm", 1) == 1
    let wait = number("wait", 180)
    withEngine(options: options, learning: learning) {
      if model {
        // The model loads on its own thread; a run measures it ready.
        let state = Self.engine.wait(forModel: UInt32(wait * 1000))
        Self.mark("model")
        NSLog(
          "cassotis model state %d, footprint %.1f MB %@", state,
          Double(EngineBridge.footprint()) / 1_048_576, Self.engine.modelError())
      }
      var firstKey = true
      var firstCommit = true
      let onKey: ((CassotisKeyResult) -> Void)? =
        ui
        ? { result in
          DispatchQueue.main.sync {
            self.apply(result)
            self.view.layoutIfNeeded()
          }
          if firstKey {
            firstKey = false
            Self.mark("firstKey")
          }
          if firstCommit, !result.commit.isEmpty {
            firstCommit = false
            Self.mark("firstCommit")
          }
        }
        : nil
      let json = Self.engine.replayCorpus(
        corpus, label: label, maxKeys: UInt32(keys), maxSeconds: UInt64(seconds),
        paceMicros: UInt32(pace), sampleEvery: UInt32(every), useContext: context, loop: loop,
        poll: model && number("defer", 1) == 1, digestPath: digest, onKey: onKey,
        onSample: { keys, seconds, footprint, available in
          NSLog(
            "replay keys=%u t=%.0f footprint=%.1fMB available=%.1fMB", keys, seconds,
            Double(footprint) / 1_048_576, Double(available) / 1_048_576)
          return true
        })
      DispatchQueue.main.async {
        self.apply(CassotisKeyResult())
        self.report(self.envelope(json))
        self.running = false
      }
    }
  }

  /// The limit os_proc_available_memory() implies, checked the hard way: dirty memory
  /// until the system kills this process. Each step is reported before the next, so
  /// the last line in the host is the largest footprint that survived.
  private func findLimit(step: Int, label: String) {
    Self.thread.run {
      var blocks: [UnsafeMutableRawPointer] = []
      var total = 0
      while true {
        let size = step << 20
        guard let block = malloc(size) else { break }
        memset(block, 0x5a, size)
        blocks.append(block)
        total += step
        let line =
          "{\"label\":\"\(label)\",\"dirtied_mb\":\(total),"
          + "\"footprint_mb\":\(Self.megabytes(EngineBridge.footprint())),"
          + "\"available_mb\":\(Self.megabytes(EngineBridge.available()))}"
        DispatchQueue.main.sync { self.report(line) }
        Thread.sleep(forTimeInterval: 0.4)
      }
    }
  }

  /// Loads the Core ML character LM one function (sequence length) at a time and
  /// reports what each costs this process (ModelProbe).
  private func mlTest(lengths: [Int], units: String, label: String) {
    let url = URL(fileURLWithPath: resourceDirectory).appendingPathComponent("char_lm/char_lm.mlmodelc")
    Self.thread.run {
      let json = ModelProbe.run(url: url, lengths: lengths, units: units, label: label)
      DispatchQueue.main.async {
        self.report(self.envelope(json))
        self.running = false
      }
    }
  }

  /// Types keys through the same calls as the keys on screen and reports what a user
  /// would see: the document, the composition and candidates left at the end, the
  /// user dictionary, how many custom phrases the engine has, and with debug=1 the left
  /// context the engine ranked with.
  ///   keys    a–z, digits, ' and punctuation as typed; _ space, < backspace,
  ///           ~ return, #N the Nth candidate of the list (scrolled part included),
  ///           + scroll the list to its end so that it reads the next page,
  ///           {en} {zh} switch the mode, {reset} the panel's resetInput,
  ///           {sym:X} X from the panel's symbol grid
  ///   prefix  text inserted first, as if typed earlier (no spaces)
  ///   pace    milliseconds between keys (default 300, enough for the model's poll)
  ///   learning=0 opens the engine without the user dictionary
  private func typeKeys(_ options: [String: String]) {
    let label = options["label"] ?? "type"
    let pace = Double(options["pace"].flatMap(Int.init) ?? 300) / 1000
    let savedMode = Self.rememberedMode
    // taps=1: each letter is a touch held for hold ms, as the panel sends it (down
    // computes early, up draws); spec=0 turns compute-on-key-down off to compare.
    let taps = options["taps"] == "1"
    let hold = Double(options["hold"].flatMap(Int.init) ?? 80) / 1000
    let savedSpeculates = Self.speculates
    Self.speculates = options["spec"] != "0"
    measuring = true
    releaseTimes = []
    pollsApplied = 0
    pollsDropped = 0
    let debug = options["debug"] == "1"
    var tokens: [String] = []
    let characters = Array(options["keys"] ?? "")
    var index = 0
    while index < characters.count {
      if characters[index] == "{", let close = characters[index...].firstIndex(of: "}") {
        tokens.append(String(characters[index...close]))
        index = close + 1
      } else if characters[index] == "#", index + 1 < characters.count, characters[index + 1].isNumber {
        var end = index + 1
        while end < characters.count, characters[end].isNumber { end += 1 }
        tokens.append("#" + String(characters[(index + 1)..<end]))
        index = end
      } else {
        tokens.append(String(characters[index]))
        index += 1
      }
    }
    func step(_ position: Int) {
      guard position < tokens.count else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
        return
      }
      let token = tokens[position]
      let cursorKeys = [
        "{left}": "ArrowLeft", "{right}": "ArrowRight", "{up}": "ArrowUp", "{down}": "ArrowDown",
        "{home}": "Home", "{end}": "End",
      ]
      if token.hasPrefix("{") && typeCommand(token) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pace) { step(position + 1) }
        return
      }
      if taps && Self.isPinyinLetter(token) {
        keyDown(token, forward: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
          self.letterReleased(token)
          DispatchQueue.main.asyncAfter(deadline: .now() + pace) { step(position + 1) }
        }
        return
      }
      if token.hasPrefix("{cancel:") {  // a press a long press or a swipe takes over
        let letter = String(token.dropFirst(8).dropLast())
        keyDown(letter, forward: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
          self.keyCancelled()
          DispatchQueue.main.asyncAfter(deadline: .now() + pace) { step(position + 1) }
        }
        return
      }
      switch token {
      case let key where cursorKeys[key] != nil: pressCursorKey(cursorKeys[key]!)
      case "_": pressSpecial(5, fallback: " ")
      case "<": pressDelete()
      case "~": pressSpecial(3, fallback: "\n")
      case "+": loadCandidates(shownCandidates.count, 9)  // the list scrolled to its end
      case "{tab}": acceptCompletion()  // a tap on the completion row
      case "{en}": setInputMode(1)
      case "{zh}": setInputMode(0)
      case "{reset}": commitComposition()  // what the panel's resetInput does
      case let symbol where symbol.hasPrefix("{sym:"):  // a symbol from the panel's grid
        commitComposition()
        insertAfterKeys(String(symbol.dropFirst(5).dropLast()))
      default:
        if token.hasPrefix("#"), let number = Int(token.dropFirst()), number > 0 {
          pickCandidate(number - 1)
        } else {
          pressText(token)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + pace) { step(position + 1) }
    }
    func finish() {
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: Self.dataDirectory + "/user_dict.db")
      let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
      let result = lastResult
      var report: [String: Any] = [
        "label": label, "keys": tokens.count,
        "document": (textDocumentProxy.documentContextBeforeInput ?? "")
          + (textDocumentProxy.documentContextAfterInput ?? ""),
        "preedit": preedit, "candidates": shownCandidates, "selected": result.selected,
        "pages": result.pages, "user_dict_bytes": size,
        "completion": shownCompletion, "completion_predicted": result.completionPredicted,
        "view_height": view.bounds.height,
        "footprint_mb": Double(EngineBridge.footprint()) / 1_048_576,
        "peak_mb": Double(EngineBridge.footprintPeak()) / 1_048_576,
      ]
      if debug {
        report["debug_context"] = result.debugContext
        report["debug_context_reported"] = result.debugContextReported
      }
      let times = releaseTimes.sorted()
      if !times.isEmpty {
        let at = { (q: Double) in times[min(times.count - 1, Int(Double(times.count) * q))] }
        report["release_ms"] = [
          "count": times.count, "p50": at(0.5), "p95": at(0.95), "max": times.last!,
        ]
      }
      report.merge(typeReport()) { _, added in added }
      report["speculates"] = Self.speculates
      report["polls_applied"] = pollsApplied
      report["polls_dropped"] = pollsDropped
      measuring = false
      Self.speculates = savedSpeculates
      Self.rememberedMode = savedMode  // {en} and {zh} must not change the phone's keyboard
      Self.thread.run {
        if debug { Self.engine.setDebugMode(false) }
        let state = Self.engine.wait(forModel: 0)
        report["model_state"] = state
        report["mode"] = Self.engine.inputMode()
        report["phrases"] = Self.engine.phraseCount()
        if let s = Self.engine.settings() {
          report["settings"] = [
            "full_width": s.fullWidth,
            "chinese_punctuation": s.chinesePunctuation, "auto_english": s.autoEnglish,
            "scheme": s.scheme, "fuzzy_rules": s.fuzzyRules,
          ]
        }
        DispatchQueue.main.async {
          let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data()
          self.report(self.envelope(String(data: data, encoding: .utf8) ?? "{}"))
          self.running = false
        }
      }
    }
    if let prefix = options["prefix"] { textDocumentProxy.insertText(prefix) }
    withEngine(options: options, learning: options["learning"] != "0") {
      if debug { Self.engine.setDebugMode(true) }
      if options["lm"] != "0" { _ = Self.engine.wait(forModel: 180_000) }
      DispatchQueue.main.async { step(0) }
    }
  }

  /// docs/memory.md of fcitx5-ios: the visible keyboard, left alone, must not grow.
  private func idle(seconds: Int, label: String, options: [String: String]) {
    withEngine(options: options, learning: false) {
      Self.mark("idleStart")
      let began = Date()
      var samples: [String] = []
      while Date().timeIntervalSince(began) < Double(seconds) {
        Thread.sleep(forTimeInterval: 30)
        samples.append(
          "[\(Int(Date().timeIntervalSince(began))),"
            + "\(Self.megabytes(EngineBridge.footprint())),"
            + "\(Self.megabytes(EngineBridge.available()))]")
      }
      Self.mark("idleEnd")
      let json = "{\"label\":\"\(label)\",\"idle_samples\":[\(samples.joined(separator: ","))]}"
      DispatchQueue.main.async {
        self.report(self.envelope(json))
        self.running = false
      }
    }
  }

  private func envelope(_ json: String) -> String {
    var marks = ""
    for mark in Self.marks {
      marks +=
        "{\"name\":\"\(mark.name)\",\"mb\":\(Self.megabytes(mark.footprint)),"
        + "\"peak_mb\":\(Self.megabytes(mark.peak)),"
        + "\"available_mb\":\(Self.megabytes(mark.available))},"
    }
    if !marks.isEmpty { marks.removeLast() }
    return "{\"device\":\"\(Self.deviceModel())\",\"os\":\"\(UIDevice.current.systemVersion)\","
      + "\"full_access\":\(hasFullAccess),\"marks\":[\(marks)],\"run\":\(json)}"
  }

  private static func megabytes(_ value: UInt64) -> String {
    String(format: "%.1f", Double(value) / 1_048_576)
  }

  private static func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { buffer in
      String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
    }
  }

  /// What this process may touch, with and without Full Access.
  private func probe() -> String {
    var lines: [String] = ["\"full_access\":\(hasFullAccess)"]
    let manager = FileManager.default
    let data = URL(fileURLWithPath: Self.dataDirectory).appendingPathComponent("probe.txt")
    let wrote = (try? "x".write(to: data, atomically: true, encoding: .utf8)) != nil
    lines.append("\"private_container_write\":\(wrote)")
    let group = "group.com.hustmobile.cassotis.poc"
    if let url = manager.containerURL(forSecurityApplicationGroupIdentifier: group) {
      lines.append("\"group_url\":\"\(url.path)\"")
      let marker = url.appendingPathComponent("host-marker.txt")
      lines.append("\"group_read\":\(manager.isReadableFile(atPath: marker.path))")
      let content = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
      lines.append("\"group_read_content\":\"\(content)\"")
      let write = url.appendingPathComponent("keyboard-marker.txt")
      let ok = (try? "from keyboard".write(to: write, atomically: true, encoding: .utf8)) != nil
      lines.append("\"group_write\":\(ok)")
    } else {
      lines.append("\"group_url\":null")
    }
    return "{" + lines.joined(separator: ",") + "}"
  }

  private func report(_ text: String) {
    textDocumentProxy.insertText("@@report \(text)@@end@@")
  }
}
