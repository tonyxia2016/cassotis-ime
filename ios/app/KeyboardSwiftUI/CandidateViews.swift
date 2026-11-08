import UIKit

@MainActor
protocol CandidateViewsDelegate: AnyObject {
  /// index counts the whole list, scrolled parts included.
  func pickCandidate(_ index: Int)
  /// The list was scrolled near its end: read the next pages.
  func loadMoreCandidates()
  func candidatesExpanded(_ expanded: Bool)
  /// The completion row was tapped: take its completion.
  func completionTapped()
}

/// The row above the candidates for the one Tab completion the engine offers: a longer
/// word, the rest of a sentence, a poem's next line. Empty when there is none; a tap
/// takes it. Text the engine guessed is in the accent colour, as macOS draws it.
final class CompletionRowView: UIView {
  weak var delegate: CandidateViewsDelegate?
  private let label = UILabel()
  private var predicted = false

  static let font = UIFont.systemFont(ofSize: 17)

  override init(frame: CGRect) {
    super.init(frame: frame)
    label.font = Self.font
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    isAccessibilityElement = true
    accessibilityTraits = .button
    set("", predicted: false)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }
  var text: String { label.text ?? "" }

  func set(_ text: String, predicted: Bool) {
    label.text = text
    self.predicted = predicted
    isUserInteractionEnabled = !text.isEmpty
    accessibilityLabel = text.isEmpty ? "暂无补全" : "补全，" + text
    updateColor()
  }

  private func updateColor() {
    label.textColor = predicted ? KeyboardTheme.action : KeyboardTheme.label(dark)
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    updateColor()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds.insetBy(dx: 12, dy: 0)  // lined up with the first candidate
  }

  @objc private func tapped() {
    guard !text.isEmpty else { return }
    UIDevice.current.playInputClick()
    delegate?.completionTapped()
  }
}

/// The strip above the keys: empty while nothing is typed, the candidates in one row
/// that scrolls while something is, and a chevron that opens them as a grid.
final class CandidateBarView: UIView, UIScrollViewDelegate {
  weak var delegate: CandidateViewsDelegate?
  private let scroll = UIScrollView()
  private let chevron = UIButton(type: .system)
  private var items: [UILabel] = []
  private(set) var candidates: [String] = []
  private var selected = 0
  private var more = false
  private(set) var expanded = false

  static let font = UIFont.systemFont(ofSize: 19)
  static let selectedFont = UIFont.systemFont(ofSize: 19, weight: .medium)

  override init(frame: CGRect) {
    super.init(frame: frame)
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = true
    scroll.keyboardStyle()
    scroll.delegate = self
    addSubview(scroll)
    chevron.addTarget(self, action: #selector(toggle), for: .touchUpInside)
    addSubview(chevron)
    let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    scroll.addGestureRecognizer(tap)
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

  func set(_ candidates: [String], selected: Int, more: Bool) {
    self.candidates = candidates
    self.selected = selected
    self.more = more
    if candidates.isEmpty { expanded = false }
    rebuild()
    scroll.contentOffset = .zero
  }

  func append(_ candidates: [String], more: Bool) {
    self.candidates += candidates
    self.more = more
    rebuild()
  }

  func setExpanded(_ on: Bool) {
    expanded = on && !candidates.isEmpty
    update()
  }

  @objc private func toggle() {
    setExpanded(!expanded)
    delegate?.candidatesExpanded(expanded)
  }

  private func rebuild() {
    items.forEach { $0.removeFromSuperview() }
    items = candidates.enumerated().map { index, text in
      let label = UILabel()
      label.text = text
      label.font = index == selected ? Self.selectedFont : Self.font
      label.textColor = KeyboardTheme.label(dark)
      scroll.addSubview(label)
      return label
    }
    update()
    setNeedsLayout()
  }

  private func update() {
    let symbol = expanded ? "chevron.up" : "chevron.down"
    chevron.setImage(
      UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
      for: .normal)
    chevron.tintColor = KeyboardTheme.label(dark)
    chevron.isHidden = candidates.isEmpty
    scroll.isHidden = expanded
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    items.forEach { $0.textColor = KeyboardTheme.label(dark) }
    update()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let chevronWidth: CGFloat = 44
    chevron.frame = CGRect(x: bounds.width - chevronWidth, y: 0, width: chevronWidth, height: bounds.height)
    scroll.frame = CGRect(x: 0, y: 0, width: bounds.width - chevronWidth, height: bounds.height)
    var x: CGFloat = 12
    for label in items {
      let width = ceil(label.intrinsicContentSize.width)
      label.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
      x += width + 22
    }
    scroll.contentSize = CGSize(width: x, height: bounds.height)
    // A row too short to scroll never reaches its end: read on now.
    if more && !items.isEmpty && x <= scroll.bounds.width {
      more = false
      delegate?.loadMoreCandidates()
    }
  }

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: scroll)
    // The nearest item: the gaps between candidates belong to one too.
    guard let index = items.indices.min(by: {
      abs(items[$0].frame.midX - point.x) < abs(items[$1].frame.midX - point.x)
    }) else { return }
    UIDevice.current.playInputClick()
    delegate?.pickCandidate(index)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if more && scrollView.contentOffset.x + scrollView.bounds.width > scrollView.contentSize.width - 120 {
      more = false  // until the next pages arrive
      delegate?.loadMoreCandidates()
    }
  }
}

/// The candidates opened as a grid over the keys, as the system keyboard does: rows of
/// cells that scroll, reading more pages near the end.
final class CandidateGridView: UIView, UIScrollViewDelegate {
  weak var delegate: CandidateViewsDelegate?
  private let scroll = UIScrollView()
  private var cells: [UILabel] = []
  private var lines: [CALayer] = []
  private var candidates: [String] = []
  private var more = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    scroll.alwaysBounceVertical = true
    scroll.keyboardStyle()
    scroll.delegate = self
    addSubview(scroll)
    scroll.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
  }

  required init?(coder: NSCoder) { fatalError() }

  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

  func set(_ candidates: [String], more: Bool) {
    self.candidates = candidates
    self.more = more
    cells.forEach { $0.removeFromSuperview() }
    cells = candidates.map { text in
      let label = UILabel()
      label.text = text
      label.font = CandidateBarView.font
      label.textAlignment = .center
      label.textColor = KeyboardTheme.label(dark)
      scroll.addSubview(label)
      return label
    }
    scroll.contentOffset = .zero
    setNeedsLayout()
  }

  func append(_ candidates: [String], more: Bool) {
    self.more = more
    self.candidates += candidates
    for text in candidates {
      let label = UILabel()
      label.text = text
      label.font = CandidateBarView.font
      label.textAlignment = .center
      label.textColor = KeyboardTheme.label(dark)
      scroll.addSubview(label)
      cells.append(label)
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scroll.frame = bounds
    lines.forEach { $0.removeFromSuperlayer() }
    lines = []
    let columns: CGFloat = 6
    let unit = floor(bounds.width / columns)
    let rowHeight: CGFloat = 48
    var x: CGFloat = 0
    var y: CGFloat = 0
    for cell in cells {
      let natural = ceil(cell.intrinsicContentSize.width) + 20
      let span = max(1, ceil(natural / unit))
      let width = min(span * unit, bounds.width)
      if x + width > bounds.width + 0.5 {
        x = 0
        y += rowHeight
      }
      cell.frame = CGRect(x: x, y: y, width: width, height: rowHeight)
      x += width
    }
    let height = cells.isEmpty ? 0 : y + rowHeight
    scroll.contentSize = CGSize(width: bounds.width, height: height)
    let color = (dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.1)).cgColor
    var lineY = rowHeight
    while lineY < height {
      let line = CALayer()
      line.backgroundColor = color
      line.frame = CGRect(x: 12, y: lineY, width: bounds.width - 24, height: 1 / UIScreen.main.scale)
      scroll.layer.addSublayer(line)
      lines.append(line)
      lineY += rowHeight
    }
    // A grid that fits without scrolling never reaches its end: read on now.
    if more && !cells.isEmpty && height <= bounds.height {
      more = false
      delegate?.loadMoreCandidates()
    }
  }

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: scroll)
    guard let index = cells.firstIndex(where: { $0.frame.contains(point) }) else { return }
    UIDevice.current.playInputClick()
    delegate?.pickCandidate(index)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if more && scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 150 {
      more = false
      delegate?.loadMoreCandidates()
    }
  }
}
