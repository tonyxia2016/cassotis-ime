import UIKit

// The settings behind a long press on 123 (SettingsPanel). Without an App Group the host
// app cannot reach the keyboard's files, so they are set here. The engine saves all of
// them but the mode in the user dictionary; the keyboard remembers the mode
// (rememberedMode) and keeps a copy of the rest to show before the engine has opened.
// Custom phrases come from the clipboard: the JSON the macOS settings export.
// Simplified Chinese only, by decision: there is no 繁體 setting.
extension KeyboardViewController {
  /// Setting ids, as the panel reports them: 100 + scheme, 300 + fuzzy rule, 200 clears
  /// what was learned, 400 imports custom phrases from the clipboard, 401 removes them.
  /// mode=type's {set:N} uses the same numbers.
  enum Setting {
    static let fullWidth: Int32 = 2
    static let chinesePunctuation: Int32 = 3
    static let autoEnglish: Int32 = 4
    static let english: Int32 = 5
    static let firstScheme: Int32 = 100
    static let clearLearning: Int32 = 200
    static let firstFuzzyRule: Int32 = 300
    static let importPhrases: Int32 = 400
    static let clearPhrases: Int32 = 401
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

  /// How many custom phrases the engine had when the keyboard last asked.
  static var savedPhraseCount: Int {
    get { UserDefaults.standard.integer(forKey: "cassotis.phraseCount") }
    set { UserDefaults.standard.set(newValue, forKey: "cassotis.phraseCount") }
  }

  /// Fills the settings panel: what the keyboard saw last at once, then the engine's.
  func refreshSettings() {
    settingsPanel?.show(Self.savedSettings, phrases: Self.savedPhraseCount, note: phraseNote)
    guard engineIsOpen else { return }
    Self.thread.run {
      guard let settings = Self.engine.settings() else { return }
      let phrases = Self.engine.phraseCount()
      DispatchQueue.main.async {
        Self.savedSettings = settings
        if phrases >= 0 { Self.savedPhraseCount = Int(phrases) }
        self.settingsPanel?.show(settings, phrases: Self.savedPhraseCount, note: self.phraseNote)
      }
    }
  }

  /// One setting changed in the panel: commit what is composed (the engine drops it when
  /// the mode, scheme or fuzzy rules change), save, and show what the engine took.
  func activateSetting(_ id: Int32) {
    switch id {
    case Setting.importPhrases: return importPhrases()
    case Setting.clearPhrases: return changePhrases { Self.engine.clearPhrases() ? nil : "没能清空短语。" }
    default: break
    }
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
        DispatchQueue.main.async {
          self.settingsPanel?.show(s, phrases: Self.savedPhraseCount, note: self.phraseNote)
        }
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
        self.settingsPanel?.show(applied, phrases: Self.savedPhraseCount, note: self.phraseNote)
      }
    }
  }

  /// The panel's “从剪贴板导入短语”: the JSON the macOS settings export (自定义短语 →
  /// 导出), added after the phrases the engine has, all or none (EngineBridge). A keyboard
  /// may read the clipboard only with Full Access, so without it nothing is read.
  func importPhrases() {
    guard hasFullAccess else {
      showPhraseNote("读剪贴板要先打开完全访问：设置 → 通用 → 键盘 → 键盘 → 言泉 → 允许完全访问。", error: true)
      return
    }
    let board = UIPasteboard.general
    guard board.hasStrings, let json = board.string else {
      showPhraseNote("剪贴板里没有文字。先在 Mac 上打开导出的短语文件，全部拷贝。", error: true)
      return
    }
    var added: Int32 = 0
    changePhrases(
      { Self.engine.importPhrases(json, added: &added) },
      done: { added > 0 ? "导入了 \(added) 条。" : "剪贴板里的短语都已经有了。" })
  }

  /// Changes the custom phrases on the engine thread, as a setting: what is composed is
  /// committed first, since its candidates may be phrases. change returns why it failed.
  private func changePhrases(_ change: @escaping () -> String?, done: @escaping () -> String = { "短语已清空。" }) {
    withEngine {
      if let committed = Self.engine.commitComposition() {
        DispatchQueue.main.async { self.apply(committed) }
      }
      let error = change()
      let count = Self.engine.phraseCount()
      DispatchQueue.main.async {
        if count >= 0 { Self.savedPhraseCount = Int(count) }
        self.apply(CassotisKeyResult())
        self.showPhraseNote(error ?? done(), error: error != nil)
      }
    }
  }

  /// What the last import or clearing did, under the panel's import row; mode=type
  /// reports it too.
  func showPhraseNote(_ text: String, error: Bool) {
    phraseNote = (text, error)
    settingsPanel?.show(Self.savedSettings, phrases: Self.savedPhraseCount, note: phraseNote)
  }
}
