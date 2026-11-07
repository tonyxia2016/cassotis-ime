import ObjectiveC
import UIKit

// The host exists to contain the keyboard, feed it commands and collect what it
// prints. Both travel through the text view, so a run needs neither an App Group
// nor Full Access:
//   launch argument  --command "<options>"   typed into the text view
//   keyboard         reads "@@run <options>@@" from documentContextBeforeInput,
//                    runs inside the extension, inserts "@@report ...@@end@@"
//   host             saves the report to Documents/reports/
private let reportBegin = "@@report "
private let reportEnd = "@@end@@"

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

// iOS 27 traps a UIKit app built against its SDK if it has no scene lifecycle.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = HostViewController()
    window.makeKeyAndVisible()
    self.window = window
  }
}

/// UIKit remembers the keyboard last used for each context identifier, so each
/// field stays on its own keyboard once someone has picked it there.
final class KeyboardField: UITextView {
  var contextIdentifier = ""
  override var textInputContextIdentifier: String? { contextIdentifier }
}

final class HostViewController: UIViewController, UITextViewDelegate {
  private let textView = KeyboardField()
  private let swiftUIView = KeyboardField()
  private let status = UILabel()
  private var command: String?
  private var field = "uikit"
  private var saved = 0

  private var activeField: KeyboardField { field == "swiftui" ? swiftUIView : textView }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.text = "上框选“言泉 POC”，下框选“言泉 POC SwiftUI”。"
    status.font = .preferredFont(forTextStyle: .footnote)
    status.numberOfLines = 0
    status.translatesAutoresizingMaskIntoConstraints = false
    textView.contextIdentifier = "com.hustmobile.cassotis.poc.uikit"
    swiftUIView.contextIdentifier = "com.hustmobile.cassotis.poc.swiftui"
    for field in [textView, swiftUIView] {
      field.delegate = self
      field.font = .systemFont(ofSize: 15)
      field.layer.borderWidth = 1
      field.layer.borderColor = UIColor.separator.cgColor
      field.autocorrectionType = .no
      field.spellCheckingType = .no
      field.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(field)
    }
    view.addSubview(status)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      status.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
      status.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
      status.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
      textView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
      textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
      textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
      textView.heightAnchor.constraint(equalToConstant: 90),
      swiftUIView.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
      swiftUIView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
      swiftUIView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
      swiftUIView.heightAnchor.constraint(equalToConstant: 90),
    ])
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--command"), index + 1 < arguments.count {
      command = arguments[index + 1]
    }
    if let index = arguments.firstIndex(of: "--field"), index + 1 < arguments.count {
      field = arguments[index + 1]
    }
  }

  /// What the globe key does, for a run started from the Mac. The classes are private;
  /// this is a test host for one person's phone. Settings are not touched: a keyboard
  /// that was never added there is not in the list.
  private func selectKeyboard(_ bundle: String) {
    guard
      let mode = UITextInputMode.activeInputModes.first(where: {
        ($0.value(forKey: "identifier") as? String)?.hasSuffix(bundle) == true
      }),
      let identifier = mode.value(forKey: "identifier") as? String
    else {
      appendDiagnostic("no input mode for \(bundle)")
      return
    }
    if let controller = NSClassFromString("UIKeyboardInputModeController") as? NSObject.Type,
      let shared = controller.perform(NSSelectorFromString("sharedInputModeController"))?
        .takeUnretainedValue() as? NSObject
    {
      shared.perform(NSSelectorFromString("setCurrentInputMode:"), with: mode)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      self.appendDiagnostic("after controller: \(self.currentIdentifier())")
      if self.currentIdentifier() == identifier { return }
      if let impl = NSClassFromString("UIKeyboardImpl") as? NSObject.Type,
        let active = impl.perform(NSSelectorFromString("activeInstance"))?
          .takeUnretainedValue() as? NSObject
      {
        let setter = NSSelectorFromString("setInputMode:")
        if active.responds(to: setter) { active.perform(setter, with: identifier) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        self.appendDiagnostic("after impl: \(self.currentIdentifier())")
      }
    }
  }

  private func currentIdentifier() -> String {
    (activeField.textInputMode?.value(forKey: "identifier") as? String) ?? "?"
  }

  private func appendDiagnostic(_ line: String) {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = documents.appendingPathComponent("keyboard-diag.txt")
    let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try? (previous + line + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private func dumpInputModeMethods() {
    for name in ["UIKeyboardInputModeController", "UIKeyboardImpl"] {
      guard let cls = NSClassFromString(name) else { continue }
      var count: UInt32 = 0
      guard let methods = class_copyMethodList(cls, &count) else { continue }
      defer { free(methods) }
      var names: [String] = []
      for index in 0..<Int(count) {
        let selector = NSStringFromSelector(method_getName(methods[index]))
        if selector.lowercased().contains("inputmode") { names.append(selector) }
      }
      appendDiagnostic("\(name): \(names.sorted().joined(separator: " "))")
    }
  }

  private func writeKeyboardList() {
    let identifiers = UITextInputMode.activeInputModes.map {
      ($0.value(forKey: "identifier") as? String) ?? "?"
    }
    let current = (activeField.textInputMode?.value(forKey: "identifier") as? String) ?? "?"
    let text = "active: \(identifiers)\ncurrent: \(current)\n"
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? text.write(
      to: documents.appendingPathComponent("keyboards.txt"), atomically: true, encoding: .utf8)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    let arguments = ProcessInfo.processInfo.arguments
    writeKeyboardList()
    if let index = arguments.firstIndex(of: "--selftest"), index + 1 < arguments.count {
      selfTest(arguments[index + 1])
      return
    }
    // The proxy only learns of programmatic text when the field gains focus, so the
    // command has to be there first.
    if let command {
      self.command = nil
      status.text = "运行中：\(command)"
      UIApplication.shared.isIdleTimerDisabled = true  // a 30 minute run must not lock the phone
      activeField.text = "@@run \(command)@@"
    }
    activeField.becomeFirstResponder()
    if let index = arguments.firstIndex(of: "--keyboard"), index + 1 < arguments.count {
      let bundle = arguments[index + 1]
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.selectKeyboard(bundle) }
    }
    if arguments.contains("--dump-input-modes") { dumpInputModeMethods() }
  }

  /// Runs the engine inside this app: the same archive, corpus and replay as the
  /// keyboard, but no extension and no memory limit. It proves the runtime and the
  /// candidates on iOS; only the keyboard's numbers count against phase 0.
  private func selfTest(_ text: String) {
    var options: [String: String] = [:]
    for pair in text.split(separator: " ") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { options[String(parts[0])] = String(parts[1]) }
    }
    let number: (String, Int) -> Int = { name, fallback in
      options[name].flatMap(Int.init) ?? fallback
    }
    let plugin = (Bundle.main.builtInPlugInsPath ?? "") + "/CassotisKeyboard.appex"
    let dataBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let data = dataBase.appendingPathComponent("Cassotis", isDirectory: true)
    try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    status.text = "自测中：\(text)"
    EngineBridge.applyMemoryPolicy(options)
    let thread = Thread { [self] in
      let engine = EngineBridge()
      let user = number("learning", 0) == 1 ? data.path + "/user_dict.db" : ""
      if let error = engine.openDictionary(
        plugin + "/dict_sc.db", userDictionary: user, resources: plugin, data: data.path)
      {
        finishSelfTest("{\"error\":\"\(error)\"}")
        return
      }
      // As in the keyboard: wait for the character LM, poll for its ranking.
      let model = number("lm", 1) == 1
      if model { _ = engine.wait(forModel: UInt32(number("wait", 180) * 1000)) }
      let json = engine.replayCorpus(
        plugin + "/corpus.tsv", label: options["label"] ?? "selftest",
        maxKeys: UInt32(number("keys", 10000)), maxSeconds: UInt64(number("seconds", 0)),
        paceMicros: UInt32(number("pace", 0)), sampleEvery: UInt32(number("every", 500)),
        useContext: number("context", 0) == 1, loop: number("loop", 0) == 1,
        poll: model && number("defer", 1) == 1,
        digestPath: data.path + "/digest-selftest.txt", onKey: nil, onSample: nil)
      finishSelfTest(json)
    }
    thread.stackSize = 4 << 20
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  private func finishSelfTest(_ json: String) {
    DispatchQueue.main.async {
      self.save(json)
      self.status.text = "自测完成\n" + json.prefix(600)
      print(json)
    }
  }

  func textViewDidChange(_ textView: UITextView) {
    guard let end = textView.text.range(of: reportEnd),
      let begin = textView.text.range(of: reportBegin, options: .backwards)
    else { return }
    let report = String(textView.text[begin.upperBound..<end.lowerBound])
    saved += 1
    save(report)
    textView.text = ""
    status.text = "已保存第 \(saved) 份报告"
  }

  private func save(_ report: String) {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let folder = documents.appendingPathComponent("reports", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = "report-\(Int(Date().timeIntervalSince1970 * 1000)).json"
    try? report.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
}
