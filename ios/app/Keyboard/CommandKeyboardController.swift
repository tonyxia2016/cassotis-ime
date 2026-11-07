import CoreML
import UIKit

// What both POC keyboards share: the engine on its one thread, the document proxy,
// memory marks, and a command channel through the text field so runs need no one
// at the phone. A subclass only supplies the keys and draws the candidates:
//   Keyboard/KeyboardViewController.swift          plain UIKit, the floor
//   KeyboardSwiftUI/KeyboardViewController.swift   the fcitx5-ios SwiftUI panel

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

  /// On the engine thread, in the idle job: whether a key interrupted it.
  func idleWasInterrupted() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return idleInterrupted
  }

  private func loop() {
    while true {
      condition.lock()
      while jobs.isEmpty && idle == nil { condition.wait() }
      let job: () -> Void
      let isIdle = jobs.isEmpty
      if isIdle {
        job = idle!
        idle = nil
        idleRunning = true
        idleInterrupted = false
      } else {
        job = jobs.removeFirst()
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

  /// Where dict_sc.db, schema.sql and corpus.tsv live for this extension.
  var resourceDirectory: String { Bundle.main.resourcePath ?? "" }

  func buildKeyboard() {}
  func showCandidates(_ candidates: [String], preedit: String) {}

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
  func withEngine(options: [String: String] = [:], learning: Bool = false,
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
      Self.mark("engineOpen")
      NSLog("cassotis engine open, footprint %.1f MB", Double(EngineBridge.footprint()) / 1_048_576)
      work()
    }
  }

  // MARK: - Typing

  func pressText(_ text: String) {
    // A pinyin letter edits the composition; punctuation commits.
    let edits = text.count == 1 && text.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || $0 == "'"
    }
    withEngine(interruptsPoll: edits) {
      let result = Self.engine.pressText(text)
      DispatchQueue.main.async { self.apply(result) }
      if result.pending { self.pollWhenIdle() }
    }
  }

  func pressSpecial(_ code: UInt16, fallback: String?) {
    let composing = !preedit.isEmpty
    withEngine(interruptsPoll: code == 1) {  // 1: backspace
      let result = Self.engine.pressSpecial(code)
      DispatchQueue.main.async {
        if !composing, let fallback { self.textDocumentProxy.insertText(fallback) }
        self.apply(result)
      }
      if result.pending { self.pollWhenIdle() }
    }
  }

  /// The model's ranking for the last key, once the engine thread is free.
  /// A poll a key interrupted is dropped: that key's own result follows.
  private func pollWhenIdle() {
    Self.thread.runWhenIdle { [weak self] in
      let result = Self.engine.poll()
      guard result.handled, !Self.thread.idleWasInterrupted() else { return }
      DispatchQueue.main.async { self?.apply(result) }
    }
  }

  func pressDelete() {
    if preedit.isEmpty {
      textDocumentProxy.deleteBackward()
    } else {
      pressSpecial(1, fallback: nil)
    }
  }

  func pickCandidate(_ index: Int) {
    withEngine {
      let result = Self.engine.select(Int32(index))
      DispatchQueue.main.async { self.apply(result) }
      if result.pending { self.pollWhenIdle() }
    }
  }

  func resetComposition() {
    withEngine {
      Self.engine.resetComposition()
      DispatchQueue.main.async { self.apply(CassotisKeyResult()) }
    }
  }

  func apply(_ result: CassotisKeyResult) {
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
    showCandidates(result.candidates, preedit: preedit)
  }

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

  private static var heldModels: [MLModel] = []

  /// Loads the Core ML character LM one function (sequence length) at a time and
  /// reports what each costs this process: load time, footprint, prediction time.
  /// The checksum is the sum of the log-probabilities of a fixed synthetic chain;
  /// scripts/char_lm_coreml.py prints the Mac's value for the same input.
  private func mlTest(lengths: [Int], units: String, label: String) {
    let url = URL(fileURLWithPath: resourceDirectory).appendingPathComponent("char_lm/char_lm.mlmodelc")
    Self.thread.run {
      var rows: [String] = []
      let before = EngineBridge.footprint()
      for length in lengths {
        guard #available(iOS 18.0, *) else { break }
        let configuration = MLModelConfiguration()
        switch units {
        case "gpu": configuration.computeUnits = .cpuAndGPU
        case "cpu": configuration.computeUnits = .cpuOnly
        case "all": configuration.computeUnits = .all
        default: configuration.computeUnits = .cpuAndNeuralEngine
        }
        configuration.functionName = "len\(length)"
        do {
          let started = CFAbsoluteTimeGetCurrent()
          let model = try MLModel(contentsOf: url, configuration: configuration)
          let load = CFAbsoluteTimeGetCurrent() - started
          let loaded = EngineBridge.footprint()
          let count = NSNumber(value: length)
          let ids = try MLMultiArray(shape: [1, count], dataType: .int32)
          let positions = try MLMultiArray(shape: [1, count], dataType: .int32)
          let mask = try MLMultiArray(shape: [1, 1, count, count], dataType: .float16)
          let idValues = ids.dataPointer.bindMemory(to: Int32.self, capacity: length)
          let placeValues = positions.dataPointer.bindMemory(to: Int32.self, capacity: length)
          for i in 0..<length {
            idValues[i] = Int32(2 + (i * 37) % 12000)
            placeValues[i] = Int32(min(i, 255))
          }
          idValues[0] = 0
          let maskValues = mask.dataPointer.bindMemory(to: UInt16.self, capacity: length * length)
          let open = Float16(0).bitPattern
          let closed = Float16(-30000).bitPattern
          let rowStride = mask.strides[2].intValue
          for r in 0..<length {
            for c in 0..<length { maskValues[r * rowStride + c] = c <= r ? open : closed }
          }
          let input = try MLDictionaryFeatureProvider(dictionary: [
            "ids": ids, "positions": positions, "mask": mask,
          ])
          var output = try model.prediction(from: input)
          var times: [Double] = []
          for _ in 0..<7 {
            let start = CFAbsoluteTimeGetCurrent()
            output = try model.prediction(from: input)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
          }
          times.sort()
          var checksum = 0.0
          if let logp = output.featureValue(for: "logp_all")?.multiArrayValue {
            for i in 0..<(min(length, 64) - 1) {
              let next = NSNumber(value: Int(idValues[i + 1]))
              checksum += logp[[0, NSNumber(value: i), next]].doubleValue
            }
          }
          Self.heldModels.append(model)
          rows.append(
            "{\"length\":\(length),\"load_s\":\(String(format: "%.2f", load)),"
              + "\"after_load_mb\":\(Self.megabytes(loaded)),"
              + "\"after_predict_mb\":\(Self.megabytes(EngineBridge.footprint())),"
              + "\"median_ms\":\(String(format: "%.1f", times[times.count / 2])),"
              + "\"best_ms\":\(String(format: "%.1f", times[0])),"
              + "\"checksum\":\(String(format: "%.3f", checksum))}")
        } catch {
          rows.append("{\"length\":\(length),\"error\":\"\(error.localizedDescription)\"}")
        }
      }
      let json =
        "{\"label\":\"\(label)\",\"units\":\"\(units)\","
        + "\"before_mb\":\(Self.megabytes(before)),\"end_mb\":\(Self.megabytes(EngineBridge.footprint())),"
        + "\"peak_mb\":\(Self.megabytes(EngineBridge.footprintPeak())),"
        + "\"available_mb\":\(Self.megabytes(EngineBridge.available())),\"functions\":[\(rows.joined(separator: ","))]}"
      DispatchQueue.main.async {
        self.report(self.envelope(json))
        self.running = false
      }
    }
  }

  /// docs/memory.md of fcitx5-ios: the visible keyboard, left alone, must not grow.
  private func idle(seconds: Int, label: String, options: [String: String]) {
    withEngine(options: options) {
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
