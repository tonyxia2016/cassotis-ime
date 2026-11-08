import Foundation

// The settings behind a long press on 123 (SettingsPanel). Without an App Group the host
// app cannot reach the keyboard's files, so they are set here. The engine saves all of
// them but the mode in the user dictionary; the keyboard remembers the mode
// (rememberedMode) and keeps a copy of the rest to show before the engine has opened.
// Simplified Chinese only, by decision: there is no 繁體 setting.
extension KeyboardViewController {
  /// Setting ids, as the panel reports them: 100 + scheme, 300 + fuzzy rule, 200 clears
  /// what was learned. mode=type's {set:N} uses the same numbers.
  enum Setting {
    static let fullWidth: Int32 = 2
    static let chinesePunctuation: Int32 = 3
    static let autoEnglish: Int32 = 4
    static let english: Int32 = 5
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
  static var savedSettings: CassotisSettings {
    get {
      let s = CassotisSettings()
      let saved = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: Int] ?? [:]
      s.inputMode = Int32(rememberedMode)
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
          "fullWidth": newValue.fullWidth ? 1 : 0,
          "chinesePunctuation": newValue.chinesePunctuation ? 1 : 0,
          "autoEnglish": newValue.autoEnglish ? 1 : 0, "scheme": Int(newValue.scheme),
          "fuzzyRules": Int(newValue.fuzzyRules),
        ], forKey: settingsKey)
    }
  }

  /// Fills the settings panel: what the keyboard saw last at once, then the engine's.
  func refreshSettings() {
    settingsPanel?.show(Self.savedSettings)
    guard engineIsOpen else { return }
    Self.thread.run {
      guard let settings = Self.engine.settings() else { return }
      DispatchQueue.main.async {
        Self.savedSettings = settings
        self.settingsPanel?.show(settings)
      }
    }
  }

  /// One setting changed in the panel: commit what is composed (the engine drops it when
  /// the mode, scheme or fuzzy rules change), save, and show what the engine took.
  func activateSetting(_ id: Int32) {
    withEngine {
      guard let s = Self.engine.settings() else { return }
      let mode = s.inputMode
      if let committed = Self.engine.commitComposition() {
        DispatchQueue.main.async { self.apply(committed) }
      }
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
        _ = Self.engine.clearLearning()
        DispatchQueue.main.async { self.settingsPanel?.show(s) }
        return
      default: return
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
        self.settingsPanel?.show(applied)
      }
    }
  }
}
