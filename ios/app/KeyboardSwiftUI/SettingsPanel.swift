import UIKit

@MainActor
protocol SettingsPanelDelegate: AnyObject {
  /// A status action id (KeyboardSettings.swift): a switch, a scheme, a fuzzy rule, or
  /// clearing what was learned.
  func settingChosen(_ id: Int32)
  func settingsClose()
}

/// The keyboard's settings, opened by holding 123: a short list in the keyboard's own
/// look, with two sub-lists (scheme, fuzzy rules) and a second tap to confirm clearing
/// what was learned. Plain views rather than menus, which a keyboard may not present.
final class SettingsPanel: UIView {
  weak var delegate: SettingsPanelDelegate?
  private enum Page { case main, scheme, fuzzy }
  private var page = Page.main
  private var settings = CassotisSettings()
  private var confirmClear = false
  private let header = UILabel()
  private let left = UIButton(type: .system)
  private let done = UIButton(type: .system)
  private let scroll = UIScrollView()
  private var rows: [UIView] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    header.font = .systemFont(ofSize: 15, weight: .semibold)
    header.textAlignment = .center
    left.titleLabel?.font = .systemFont(ofSize: 15)
    left.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    done.setTitle("完成", for: .normal)
    done.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
    addSubview(header)
    addSubview(left)
    addSubview(done)
    scroll.keyboardStyle()
    addSubview(scroll)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

  func show(_ settings: CassotisSettings) {
    self.settings = settings
    rebuild()
  }

  func reset() {
    page = .main
    confirmClear = false
    rebuild()
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    rebuild()
  }

  private func rebuild() {
    rows.forEach { $0.removeFromSuperview() }
    rows = []
    actions.removeAll()
    let label = KeyboardTheme.label(dark)
    header.textColor = label
    done.tintColor = label
    left.tintColor = label
    switch page {
    case .main:
      header.text = "言泉设置"
      left.isHidden = true
      rows.append(switchRow("全角", settings.fullWidth, id: 2))
      rows.append(switchRow("中文标点", settings.chinesePunctuation, id: 3))
      rows.append(switchRow("大写字母开始英文", settings.autoEnglish, id: 4))
      rows.append(switchRow("英文输入", settings.inputMode == 1, id: 5))
      let scheme = Int(settings.scheme)
      let schemeName = KeyboardViewController.schemeNames.indices.contains(scheme)
        ? KeyboardViewController.schemeNames[scheme] : "全拼"
      rows.append(linkRow("输入方案", schemeName) { [weak self] in self?.go(.scheme) })
      let count = (0..<KeyboardViewController.fuzzyRuleNames.count).filter {
        settings.fuzzyRules & (1 << UInt32($0)) != 0
      }.count
      rows.append(linkRow("模糊拼音", count == 0 ? "关" : "\(count) 项") { [weak self] in self?.go(.fuzzy) })
      rows.append(
        actionRow(confirmClear ? "确认清除全部学习记录" : "清除学习记录…", destructive: true) { [weak self] in
          guard let self else { return }
          if self.confirmClear {
            self.confirmClear = false
            self.delegate?.settingChosen(200)
          } else {
            self.confirmClear = true
          }
          self.rebuild()
        })
    case .scheme:
      header.text = "输入方案"
      left.isHidden = false
      left.setTitle("‹ 返回", for: .normal)
      for (index, name) in KeyboardViewController.schemeNames.enumerated() {
        rows.append(
          checkRow(name, Int(settings.scheme) == index) { [weak self] in
            self?.delegate?.settingChosen(100 + Int32(index))
          })
      }
    case .fuzzy:
      header.text = "模糊拼音"
      left.isHidden = false
      left.setTitle("‹ 返回", for: .normal)
      for (index, name) in KeyboardViewController.fuzzyRuleNames.enumerated() {
        rows.append(
          checkRow(name, settings.fuzzyRules & (1 << UInt32(index)) != 0) { [weak self] in
            self?.delegate?.settingChosen(300 + Int32(index))
          })
      }
    }
    rows.forEach { scroll.addSubview($0) }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let top: CGFloat = 40
    header.frame = CGRect(x: 80, y: 0, width: bounds.width - 160, height: top)
    left.frame = CGRect(x: 6, y: 0, width: 80, height: top)
    done.frame = CGRect(x: bounds.width - 70, y: 0, width: 64, height: top)
    scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    let rowHeight: CGFloat = 44
    for (index, row) in rows.enumerated() {
      row.frame = CGRect(x: 10, y: CGFloat(index) * (rowHeight + 1), width: bounds.width - 20, height: rowHeight)
    }
    scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(rows.count) * (rowHeight + 1))
  }

  // MARK: - Rows

  private func base(_ title: String) -> (UIView, UILabel) {
    let row = UIView()
    row.backgroundColor = KeyboardTheme.key(dark)
    row.layer.cornerRadius = 10
    row.layer.cornerCurve = .continuous
    let text = UILabel()
    text.text = title
    text.font = .systemFont(ofSize: 16)
    text.textColor = KeyboardTheme.label(dark)
    row.addSubview(text)
    text.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
      text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    return (row, text)
  }

  private func switchRow(_ title: String, _ on: Bool, id: Int32) -> UIView {
    let (row, _) = base(title)
    let toggle = UISwitch()
    toggle.isOn = on
    toggle.tag = Int(id)
    toggle.addTarget(self, action: #selector(switched(_:)), for: .valueChanged)
    row.addSubview(toggle)
    toggle.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
      toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    return row
  }

  private func linkRow(_ title: String, _ value: String, action: @escaping () -> Void) -> UIView {
    let (row, _) = base(title)
    let detail = UILabel()
    detail.text = value + "  ›"
    detail.font = .systemFont(ofSize: 15)
    detail.textColor = KeyboardTheme.secondary(dark)
    row.addSubview(detail)
    detail.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      detail.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
      detail.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    addTap(row, action)
    return row
  }

  private func checkRow(_ title: String, _ on: Bool, action: @escaping () -> Void) -> UIView {
    let (row, _) = base(title)
    let mark = UIImageView(image: UIImage(systemName: "checkmark"))
    mark.tintColor = KeyboardTheme.action
    mark.isHidden = !on
    row.addSubview(mark)
    mark.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      mark.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
      mark.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    addTap(row, action)
    return row
  }

  private func actionRow(_ title: String, destructive: Bool, action: @escaping () -> Void) -> UIView {
    let (row, text) = base(title)
    if destructive { text.textColor = .systemRed }
    addTap(row, action)
    return row
  }

  private var actions: [ObjectIdentifier: () -> Void] = [:]

  private func addTap(_ row: UIView, _ action: @escaping () -> Void) {
    actions[ObjectIdentifier(row)] = action
    row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:))))
  }

  @objc private func rowTapped(_ gesture: UITapGestureRecognizer) {
    guard let row = gesture.view, let action = actions[ObjectIdentifier(row)] else { return }
    UIDevice.current.playInputClick()
    action()
  }

  @objc private func switched(_ sender: UISwitch) {
    delegate?.settingChosen(Int32(sender.tag))
  }

  private func go(_ page: Page) {
    self.page = page
    confirmClear = false
    rebuild()
  }

  @objc private func backTapped() { go(.main) }
  @objc private func doneTapped() {
    reset()
    delegate?.settingsClose()
  }
}
