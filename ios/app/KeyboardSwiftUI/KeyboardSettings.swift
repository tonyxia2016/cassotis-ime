import Foundation

// The settings in the panel's status area (the toolbar's … button). Without an App
// Group the host app cannot reach the keyboard's files, so they are set here. The
// engine saves all of them but the mode in its data directory, which is this
// extension's container; the keyboard remembers the mode (rememberedMode) and keeps
// a copy of the rest to show before the engine has opened.
extension KeyboardViewController {
  /// Status area action ids. Menus pick with their children's ids: 100 + scheme,
  /// 300 + fuzzy rule, 200 clears what was learned.
  private enum Setting {
    static let fullWidth: Int32 = 2
    static let chinesePunctuation: Int32 = 3
    static let autoEnglish: Int32 = 4
    static let english: Int32 = 5
    static let schemeMenu: Int32 = 10
    static let fuzzyMenu: Int32 = 11
    static let learningMenu: Int32 = 12
    static let firstScheme: Int32 = 100
    static let clearLearning: Int32 = 200
    static let firstFuzzyRule: Int32 = 300
  }

  /// TncPinyinInputScheme, named as in the macOS settings.
  static let schemeNames = ["全拼", "微软双拼", "小鹤双拼", "自然码双拼", "搜狗双拼", "紫光双拼", "拼音加加"]
  /// TncFuzzyPinyinRule, in bit order.
  static let fuzzyRuleNames = [
    "z = zh", "c = ch", "s = sh", "l = n", "f = h", "r = l", "an = ang", "en = eng", "in = ing",
    "ian = iang", "uan = uang",
  ]

  private static let settingsKey = "cassotis.settings"

  /// What the keyboard saw last; the engine's defaults before that.
  private static var savedSettings: CassotisSettings {
    get {
      let s = CassotisSettings()
      let saved = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: Int] ?? [:]
      s.inputMode = Int32(rememberedMode)
      s.traditional = saved["traditional"] == 1
      s.fullWidth = saved["fullWidth"] == 1
      s.chinesePunctuation = (saved["chinesePunctuation"] ?? 1) == 1
      s.autoEnglish = (saved["autoEnglish"] ?? 1) == 1
      s.scheme = Int32(saved["scheme"] ?? 0)
      s.fuzzyRules = UInt32(saved["fuzzyRules"] ?? 0)
      return s
    }
    set {
      UserDefaults.standard.set(
        [
          "traditional": newValue.traditional ? 1 : 0, "fullWidth": newValue.fullWidth ? 1 : 0,
          "chinesePunctuation": newValue.chinesePunctuation ? 1 : 0,
          "autoEnglish": newValue.autoEnglish ? 1 : 0, "scheme": Int(newValue.scheme),
          "fuzzyRules": Int(newValue.fuzzyRules),
        ], forKey: settingsKey)
    }
  }

  /// Puts the current settings in the status area: the engine's when it is open.
  func refreshSettings() {
    showSettings(Self.savedSettings)
    guard engineIsOpen else { return }
    Self.thread.run {
      guard let settings = Self.engine.settings() else { return }
      DispatchQueue.main.async {
        Self.savedSettings = settings
        self.showSettings(settings)
      }
    }
  }

  private func showSettings(_ s: CassotisSettings) {
    func toggle(_ id: Int32, _ desc: String, _ on: Bool, icon: String = "") -> StatusAreaAction {
      StatusAreaAction(id: id, desc: desc, icon: icon, checked: on, separator: false, children: [])
    }
    func item(_ id: Int32, _ desc: String, _ on: Bool = false) -> StatusAreaAction {
      toggle(id, (on ? "✓ " : "") + desc, false)
    }
    let scheme = Int(s.scheme)
    // No 繁體 switch: the embedded engine opens without the traditional dictionary
    // (cassotis_core_open takes one path), and dict_tc.db would add 293 MB.
    let actions = [
      toggle(
        Setting.fullWidth, "全角", s.fullWidth,
        icon: s.fullWidth ? "fcitx-fullwidth-active" : "fcitx-fullwidth-inactive"),
      toggle(Setting.chinesePunctuation, "中文标点", s.chinesePunctuation),
      toggle(Setting.autoEnglish, "自动英文", s.autoEnglish),
      toggle(Setting.english, "英文", s.inputMode == 1),
      StatusAreaAction(
        id: Setting.schemeMenu,
        desc: Self.schemeNames.indices.contains(scheme) ? Self.schemeNames[scheme] : "全拼",
        icon: "", checked: false, separator: false,
        children: Self.schemeNames.enumerated().map {
          item(Setting.firstScheme + Int32($0.offset), $0.element, $0.offset == scheme)
        }),
      StatusAreaAction(
        id: Setting.fuzzyMenu, desc: "模糊拼音", icon: "", checked: false, separator: false,
        children: Self.fuzzyRuleNames.enumerated().map {
          item(
            Setting.firstFuzzyRule + Int32($0.offset), $0.element,
            s.fuzzyRules & (1 << UInt32($0.offset)) != 0)
        }),
      StatusAreaAction(
        id: Setting.learningMenu, desc: "学习记录", icon: "", checked: false, separator: false,
        children: [item(Setting.clearLearning, "清除全部学习记录")]),
    ]
    setStatusAreaAsync(program, inputContext, actions)
  }

  /// A status area action: changes one setting (committing what is composed first,
  /// as the engine drops it), or clears what was learned.
  func activateSetting(_ id: Int32) {
    withEngine {
      guard let s = Self.engine.settings() else { return }
      let mode = s.inputMode
      switch id {
      case Setting.fullWidth: s.fullWidth.toggle()
      case Setting.chinesePunctuation: s.chinesePunctuation.toggle()
      case Setting.autoEnglish: s.autoEnglish.toggle()
      case Setting.english: s.inputMode = s.inputMode == 1 ? 0 : 1
      case Setting.firstScheme..<(Setting.firstScheme + Int32(Self.schemeNames.count)):
        s.scheme = id - Setting.firstScheme
      case Setting.firstFuzzyRule..<(Setting.firstFuzzyRule + Int32(Self.fuzzyRuleNames.count)):
        s.fuzzyRules ^= 1 << UInt32(id - Setting.firstFuzzyRule)
      case Setting.clearLearning:
        if let committed = Self.engine.commitComposition() {
          DispatchQueue.main.async { self.apply(committed) }
        }
        _ = Self.engine.clearLearning()
        return
      default: return
      }
      if let committed = Self.engine.commitComposition() {
        DispatchQueue.main.async { self.apply(committed) }
      }
      _ = Self.engine.applySettings(s)
      let applied = Self.engine.settings() ?? s
      DispatchQueue.main.async {
        Self.savedSettings = applied
        if applied.inputMode != mode {
          Self.rememberedMode = Int(applied.inputMode)
          self.showInputMode(Int(applied.inputMode))
        }
        self.apply(CassotisKeyResult())
        self.showSettings(applied)
      }
    }
  }
}
