import UIKit

// The look and the key layout of iOS's own Simplified Chinese Pinyin keyboard (iOS 27),
// measured on an iPhone 17 simulator (402 pt wide): keys 33.5 × 43 pt, 6 pt apart,
// rows 54 pt apart, 6.5 pt margins. The system's own strip above the keys is 53 pt;
// a third-party keyboard's frame already has about 19 pt above the view, so the
// candidate strip is 40 pt and the keyboard ends up as tall as the system's.
// Widths scale with the screen; heights stay, except in landscape.
enum KeyboardTheme {
  static func background(_ dark: Bool) -> UIColor {
    dark ? UIColor(white: 0x20 / 255.0, alpha: 1) : UIColor(red: 0xE2 / 255.0, green: 0xE3 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
  }
  /// Every key, letters and function keys alike.
  static func key(_ dark: Bool) -> UIColor { dark ? UIColor(white: 0x44 / 255.0, alpha: 1) : .white }
  /// A function key held down, and the special return key's text.
  static func keyPressed(_ dark: Bool) -> UIColor {
    dark ? UIColor(white: 0x6C / 255.0, alpha: 1) : UIColor(red: 0xB4 / 255.0, green: 0xB8 / 255.0, blue: 0xC1 / 255.0, alpha: 1)
  }
  static func label(_ dark: Bool) -> UIColor { dark ? .white : .black }
  static func secondary(_ dark: Bool) -> UIColor { dark ? UIColor(white: 0.6, alpha: 1) : UIColor(white: 0.55, alpha: 1) }
  /// A return key that does something (search, send, go): tinted, as the system's.
  static let action = UIColor.systemBlue

  static let cornerRadius: CGFloat = 8.5
  static let topStrip: CGFloat = 40
  static let margin: CGFloat = 6.5
  static let gap: CGFloat = 6
  static func keyHeight(_ landscape: Bool) -> CGFloat { landscape ? 32 : 43 }
  static func rowGap(_ landscape: Bool) -> CGFloat { landscape ? 6 : 11 }
  static let bottomInset: CGFloat = 2
  static func height(_ landscape: Bool) -> CGFloat {
    completionRow(landscape) + strip(landscape) + 4 * keyHeight(landscape) + 3 * rowGap(landscape)
      + bottomInset
  }
  /// The Tab completion's own row above the candidates (macOS keeps one under its
  /// candidates): a whole sentence's continuation would crowd them out of the strip.
  static func completionRow(_ landscape: Bool) -> CGFloat { landscape ? 24 : 30 }
  static func strip(_ landscape: Bool) -> CGFloat { landscape ? 36 : topStrip
  }
}

/// What a key does.
enum KeyKind: Equatable {
  case letter(String)  // a–z, shown upper case while shifted
  case literal(String)  // a digit or symbol from the number and symbol pages, typed as shown
  case shift
  case delete
  case numbers  // 123: the number page; held, the settings
  case symbols  // #+=
  case letters  // back to the letters (拼音)
  case emoji
  case space
  case returnKey
}

struct KeySpec {
  let kind: KeyKind
  /// Width in letter-key units (1 = a letter key); a nil width shares what is left.
  let width: CGFloat?
}

enum KeyPage { case letters, numbers, symbols }

enum KeyLayout {
  private static func letters(_ s: String) -> [KeySpec] {
    s.map { KeySpec(kind: .letter(String($0)), width: 1) }
  }
  private static func literals(_ list: [String]) -> [KeySpec] {
    list.map { KeySpec(kind: .literal($0), width: 1) }
  }

  /// The rows of a page. Row 2 of the letters is inset by half a key; row 3 puts shift and
  /// delete at the ends (1.33 keys each) with the letters centred between them.
  static func rows(_ page: KeyPage) -> [[KeySpec]] {
    let bottom: [KeySpec] = [
      KeySpec(kind: page == .letters ? .numbers : .letters, width: 1.28),
      KeySpec(kind: .emoji, width: 1.28),
      KeySpec(kind: .space, width: nil),
      KeySpec(kind: .returnKey, width: 2.76),
    ]
    switch page {
    case .letters:
      return [
        letters("qwertyuiop"), letters("asdfghjkl"),
        [KeySpec(kind: .shift, width: 1.33)] + letters("zxcvbnm") + [KeySpec(kind: .delete, width: 1.33)],
        bottom,
      ]
    case .numbers:
      return [
        literals(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]),
        literals(["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"]),
        [KeySpec(kind: .symbols, width: 1.33)] + literals(["。", "，", "、", "？", "！", "."])
          .map { KeySpec(kind: $0.kind, width: 1.2) } + [KeySpec(kind: .delete, width: 1.33)],
        bottom,
      ]
    case .symbols:
      return [
        literals(["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="]),
        literals(["_", "—", "\\", "|", "～", "《", "》", "$", "&", "·"]),
        [KeySpec(kind: .numbers, width: 1.33)] + literals(["…", "，", "^_^", "？", "！", "'"])
          .map { KeySpec(kind: $0.kind, width: 1.2) } + [KeySpec(kind: .delete, width: 1.33)],
        bottom,
      ]
    }
  }

  /// Key frames for a page in a view of this width, from the top of the key area.
  static func frames(_ page: KeyPage, width: CGFloat, landscape: Bool) -> [(KeySpec, CGRect)] {
    let rows = Self.rows(page)
    let margin = KeyboardTheme.margin * width / 402
    let gap = KeyboardTheme.gap * width / 402
    let unit = (width - 2 * margin - 9 * gap) / 10  // a letter key
    let height = KeyboardTheme.keyHeight(landscape)
    let pitch = height + KeyboardTheme.rowGap(landscape)
    var result: [(KeySpec, CGRect)] = []
    for (index, row) in rows.enumerated() {
      let y = CGFloat(index) * pitch
      let fixed = row.compactMap(\.width).reduce(0, +) * unit
      let flexible = row.filter { $0.width == nil }.count
      let gaps = CGFloat(row.count - 1) * gap
      let share = flexible > 0 ? max(unit, (width - 2 * margin - fixed - gaps) / CGFloat(flexible)) : 0
      var widths = row.map { $0.width.map { $0 * unit } ?? share }
      var x = margin
      let total = widths.reduce(0, +) + gaps
      if index == 2, case .shift = row.first!.kind {
        // The letters sit centred between shift and delete, not packed against them.
        let ends = widths.first! + widths.last!
        let letters = total - ends - 2 * gap
        let room = width - 2 * margin - ends
        var cx = margin
        result.append((row[0], CGRect(x: cx, y: y, width: widths[0], height: height)))
        cx = margin + widths[0] + (room - letters) / 2
        for k in 1..<(row.count - 1) {
          result.append((row[k], CGRect(x: cx, y: y, width: widths[k], height: height)))
          cx += widths[k] + gap
        }
        let last = row.count - 1
        result.append(
          (row[last], CGRect(x: width - margin - widths[last], y: y, width: widths[last], height: height)))
        continue
      }
      if total < width - 2 * margin - 0.5 {
        if flexible == 0 && index == 2 {
          // Number and symbol pages: stretch the middle keys to fill the row.
          let middle = row.count - 2
          let spare = (width - 2 * margin - total) / CGFloat(middle)
          for k in 1...middle { widths[k] += spare }
        } else {
          x = (width - total) / 2  // the inset second row
        }
      }
      for (k, spec) in row.enumerated() {
        result.append((spec, CGRect(x: x, y: y, width: widths[k], height: height)))
        x += widths[k] + gap
      }
    }
    return result
  }
}

extension UIScrollView {
  /// iOS 26 softens a scroll view's edges; in a keyboard's short strips that blurs a whole
  /// row. Safe-area insets do not apply inside a keyboard either.
  func keyboardStyle() {
    contentInsetAdjustmentBehavior = .never
    if #available(iOS 26.0, *) {
      topEdgeEffect.isHidden = true
      bottomEdgeEffect.isHidden = true
      leftEdgeEffect.isHidden = true
      rightEdgeEffect.isHidden = true
    }
  }
}
