import UIKit

/// What the key area reports to the keyboard. Letters arrive in three steps so that the
/// engine can start at touch-down: down, then up (draw it) or cancelled (the finger slid
/// to another key, or another key took over first).
@MainActor
protocol KeysViewDelegate: AnyObject {
  func letterDown(_ text: String)
  func letterUp(_ text: String)
  func letterCancelled(_ text: String)
  func literal(_ text: String)
  func delete()
  func space()
  func returnKey()
  func showPage(_ page: KeyPage)
  func emoji()
  func settings()
  func moveCaret(_ steps: Int)
  /// The shift state changed (the controller keeps it for upper-case letters).
  func shiftChanged(_ shifted: Bool)
}

/// One key: a rounded rectangle with a label or a symbol, like the system's. Its views
/// are made when first needed: a letter key has only its label, the space bar only its
/// corner, and every view and drawn label is memory the keyboard extension is short of.
final class KeyCap: UIView {
  let spec: KeySpec
  private var label: UILabel?
  private var icon: UIImageView?
  private var corner: UILabel?  // the space bar's 拼 or 英

  init(_ spec: KeySpec) {
    self.spec = spec
    super.init(frame: .zero)
    layer.cornerRadius = KeyboardTheme.cornerRadius
    layer.cornerCurve = .continuous
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError() }

  func setText(_ text: String?, font: UIFont, color: UIColor) {
    if label == nil && text != nil {
      let new = UILabel()
      new.textAlignment = .center
      new.adjustsFontSizeToFitWidth = true
      new.minimumScaleFactor = 0.6
      addSubview(new)
      label = new
      setNeedsLayout()
    }
    label?.font = font
    label?.textColor = color
    label?.text = text
  }

  func setSymbol(_ image: UIImage?, color: UIColor) {
    if icon == nil && image != nil {
      let new = UIImageView()
      new.contentMode = .center
      addSubview(new)
      icon = new
      setNeedsLayout()
    }
    icon?.tintColor = color
    icon?.image = image
  }

  func setCorner(_ text: String, color: UIColor) {
    if corner == nil {
      let new = UILabel()
      new.font = .systemFont(ofSize: 11)
      new.textAlignment = .right
      addSubview(new)
      corner = new
      setNeedsLayout()
    }
    corner?.textColor = color
    corner?.text = text
  }

  /// What is on the key fades while the space bar is a trackpad.
  func setContentAlpha(_ alpha: CGFloat) {
    label?.alpha = alpha
    icon?.alpha = alpha
    corner?.alpha = alpha
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    label?.frame = bounds.insetBy(dx: 2, dy: 0)
    icon?.frame = bounds
    corner?.frame = CGRect(x: bounds.width - 30, y: bounds.height - 18, width: 24, height: 14)
  }
}

/// The four rows of keys and everything a finger does on them.
final class KeysView: UIView {
  weak var delegate: KeysViewDelegate?
  private(set) var page: KeyPage = .letters
  private var caps: [KeyCap] = []
  private var landscape = false

  // Shift: a tap shifts the next letter, a double tap locks.
  private(set) var shifted = false
  private var capsLock = false
  private var lastShiftTap: CFTimeInterval = 0

  /// Shown on the space bar's corner: 拼 or 英.
  var modeMark = "拼" { didSet { updateLabels() } }
  /// The return key's text for a field with a special return (搜索, 发送…); nil shows ↵.
  var returnTitle: String? { didSet { updateLabels() } }

  private let callout = CalloutView()
  private var haptics: UIImpactFeedbackGenerator?
  var hapticsEnabled = false {
    didSet {
      haptics = hapticsEnabled ? haptics ?? UIImpactFeedbackGenerator(style: .light) : nil
      haptics?.prepare()
    }
  }

  /// A finger on the keys: the key under it now, and what it is doing there.
  private final class Track {
    var cap: KeyCap
    var start: CGPoint
    var timer: Timer?
    var trackpad = false
    var trackX: CGFloat = 0
    var released = false  // a letter already sent because another key began
    init(cap: KeyCap, start: CGPoint) {
      self.cap = cap
      self.start = start
    }
  }
  private var tracks: [ObjectIdentifier: Track] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    callout.isHidden = true
    addSubview(callout)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

  func show(_ page: KeyPage) {
    guard page != self.page || caps.isEmpty else { return }
    self.page = page
    rebuild()
  }

  func setLandscape(_ landscape: Bool) {
    guard landscape != self.landscape else { return }
    self.landscape = landscape
    setNeedsLayout()
  }

  /// After a letter: a one-shot shift ends, a lock stays.
  func letterTyped() {
    if shifted && !capsLock { setShift(false) }
  }

  private func setShift(_ on: Bool, lock: Bool = false) {
    shifted = on
    capsLock = on && lock
    updateLabels()
    delegate?.shiftChanged(on)
  }

  private func rebuild() {
    caps.forEach { $0.removeFromSuperview() }
    caps = KeyLayout.rows(page).flatMap { $0 }.map { KeyCap($0) }
    caps.forEach { insertSubview($0, belowSubview: callout) }
    updateLabels()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if caps.isEmpty { rebuild() }
    let frames = KeyLayout.frames(page, width: bounds.width, landscape: landscape)
    for (cap, frame) in zip(caps, frames.map(\.1)) { cap.frame = frame }
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    updateLabels()
  }

  func updateLabels() {
    let dark = self.dark
    let ink = KeyboardTheme.label(dark)
    for cap in caps {
      cap.backgroundColor = KeyboardTheme.key(dark)
      let symbol = { (name: String, size: CGFloat) -> UIImage? in
        UIImage(
          systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
      }
      switch cap.spec.kind {
      case .letter(let text):
        cap.setText(shifted ? text.uppercased() : text, font: .systemFont(ofSize: 23), color: ink)
      case .literal(let text):
        cap.setText(text, font: .systemFont(ofSize: text.count > 1 ? 16 : 22), color: ink)
      case .shift:
        cap.setSymbol(symbol(capsLock ? "capslock.fill" : shifted ? "shift.fill" : "shift", 18), color: ink)
      case .delete: cap.setSymbol(symbol("delete.left", 18), color: ink)
      case .numbers: cap.setText("123", font: .systemFont(ofSize: 17), color: ink)
      case .symbols: cap.setText("#+=", font: .systemFont(ofSize: 17), color: ink)
      case .letters: cap.setText("拼音", font: .systemFont(ofSize: 16), color: ink)
      case .emoji:
        cap.setSymbol(
          UIImage(
            systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)),
          color: ink)
      case .space: cap.setCorner(modeMark, color: KeyboardTheme.secondary(dark))
      case .returnKey:
        if let title = returnTitle {
          cap.backgroundColor = KeyboardTheme.action
          cap.setSymbol(nil, color: ink)
          cap.setText(title, font: .systemFont(ofSize: 16, weight: .medium), color: .white)
        } else {
          cap.setText(nil, font: .systemFont(ofSize: 16), color: ink)
          cap.setSymbol(symbol("return.left", 18), color: ink)
        }
      }
    }
  }

  // MARK: - Touches

  /// The key under a point: the nearest in the nearest row, so the gaps between keys
  /// belong to a key too.
  private func cap(at point: CGPoint) -> KeyCap? {
    guard !caps.isEmpty else { return nil }
    let rowCaps = Dictionary(grouping: caps) { $0.frame.minY }
    guard let rowY = rowCaps.keys.min(by: { abs($0 + 21 - point.y) < abs($1 + 21 - point.y) }) else {
      return nil
    }
    return rowCaps[rowY]?.min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }
  }

  private func isLetterLike(_ cap: KeyCap) -> Bool {
    switch cap.spec.kind {
    case .letter, .literal: return true
    default: return false
    }
  }

  private func text(of cap: KeyCap) -> String {
    switch cap.spec.kind {
    case .letter(let text): return shifted ? text.uppercased() : text
    case .literal(let text): return text
    default: return ""
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      guard let cap = cap(at: touch.location(in: self)) else { continue }
      // A new key sends a letter still held, so letters arrive in the order typed.
      for other in tracks.values where !other.released && isLetterLike(other.cap) {
        other.released = true
        hideCallout()
        send(other.cap)
      }
      let track = Track(cap: cap, start: touch.location(in: self))
      tracks[ObjectIdentifier(touch)] = track
      feedback()
      press(track)
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      guard let track = tracks[ObjectIdentifier(touch)], !track.released else { continue }
      let point = touch.location(in: self)
      if track.trackpad {
        let steps = Int((point.x - track.trackX) / 9)
        if steps != 0 {
          track.trackX += CGFloat(steps) * 9
          delegate?.moveCaret(steps)
        }
        continue
      }
      // Slide to correct: the letter is the one under the finger when it lifts.
      guard isLetterLike(track.cap), let now = cap(at: point), now !== track.cap, isLetterLike(now)
      else { continue }
      if case .letter(let text) = track.cap.spec.kind { delegate?.letterCancelled(shifted ? text.uppercased() : text) }
      track.cap = now
      press(track)
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      guard let track = tracks.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
      track.timer?.invalidate()
      unhighlight(track.cap)
      if track.released || track.trackpad {
        if track.trackpad { setTrackpad(false) }
        continue
      }
      hideCallout()
      send(track.cap)
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      guard let track = tracks.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
      track.timer?.invalidate()
      unhighlight(track.cap)
      hideCallout()
      if track.trackpad { setTrackpad(false) }
      if !track.released, case .letter(let text) = track.cap.spec.kind {
        delegate?.letterCancelled(shifted ? text.uppercased() : text)
      }
    }
  }

  /// Touch-down on a key: what happens at once (a letter goes to the engine, delete
  /// deletes, shift shifts) and what a hold does.
  private func press(_ track: Track) {
    let cap = track.cap
    switch cap.spec.kind {
    case .letter:
      showCallout(cap)
      delegate?.letterDown(text(of: cap))
    case .literal:
      showCallout(cap)
    case .delete:
      highlight(cap)
      delegate?.delete()
      var count = 0
      track.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
        // Held: repeat, faster after a while, as the system does.
        func repeatDelete(_ interval: TimeInterval) {
          track.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
              self?.delegate?.delete()
              count += 1
              if count == 20 && interval > 0.05 {
                timer.invalidate()
                repeatDelete(0.05)
              }
            }
          }
        }
        MainActor.assumeIsolated { repeatDelete(0.1) }
      }
    case .shift:
      let now = CACurrentMediaTime()
      if now - lastShiftTap < 0.3 {
        setShift(true, lock: true)
      } else {
        setShift(!shifted)
      }
      lastShiftTap = now
    case .space:
      highlight(cap)
      track.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.tracks.values.contains(where: { $0 === track }) else { return }
          track.trackpad = true
          track.trackX = track.start.x
          self.setTrackpad(true)
        }
      }
    case .numbers:
      highlight(cap)
      if page == .letters {
        track.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.tracks.values.contains(where: { $0 === track }) else { return }
            track.released = true  // held: the settings instead of the number page
            self.unhighlight(cap)
            self.delegate?.settings()
          }
        }
      }
    default:
      highlight(cap)
    }
  }

  /// Touch-up on a key: what a tap does.
  private func send(_ cap: KeyCap) {
    switch cap.spec.kind {
    case .letter:
      delegate?.letterUp(text(of: cap))
      letterTyped()
    case .literal(let text):
      delegate?.literal(text)
    case .space: delegate?.space()
    case .returnKey: delegate?.returnKey()
    case .numbers: delegate?.showPage(.numbers)
    case .symbols: delegate?.showPage(.symbols)
    case .letters: delegate?.showPage(.letters)
    case .emoji: delegate?.emoji()
    case .shift, .delete: break
    }
  }

  private func feedback() {
    UIDevice.current.playInputClick()  // follows the system's keyboard-click setting
    haptics?.impactOccurred(intensity: 0.7)
  }

  private func highlight(_ cap: KeyCap) {
    if case .returnKey = cap.spec.kind, returnTitle != nil {
      cap.alpha = 0.7
    } else {
      cap.backgroundColor = KeyboardTheme.keyPressed(dark)
    }
  }

  private func unhighlight(_ cap: KeyCap) {
    cap.alpha = 1
    if case .returnKey = cap.spec.kind, returnTitle != nil { return }
    cap.backgroundColor = KeyboardTheme.key(dark)
  }

  private func setTrackpad(_ on: Bool) {
    UIView.animate(withDuration: 0.15) {
      for cap in self.caps { cap.setContentAlpha(on ? 0 : 1) }
    }
  }

  // MARK: - Callout

  private func showCallout(_ cap: KeyCap) {
    callout.show(text: text(of: cap), over: cap.frame, in: bounds, dark: dark)
  }

  private func hideCallout() { callout.isHidden = true }
}

/// The enlarged key that pops up over a letter while it is held: a balloon joined to
/// the key, kept inside the keyboard at the edges.
final class CalloutView: UIView {
  private let shape = CAShapeLayer()
  private let text = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.addSublayer(shape)
    shape.shadowColor = UIColor.black.cgColor
    shape.shadowOpacity = 0.28
    shape.shadowRadius = 1.5
    shape.shadowOffset = CGSize(width: 0, height: 1)
    text.textAlignment = .center
    text.font = .systemFont(ofSize: 36)
    addSubview(text)
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(text value: String, over key: CGRect, in area: CGRect, dark: Bool) {
    // The balloon fits in the candidate strip above the top row, which a keyboard
    // cannot draw beyond.
    let grow: CGFloat = 10
    let height: CGFloat = KeyboardTheme.topStrip + 4
    var top = CGRect(
      x: key.minX - grow, y: key.minY - height + 4, width: key.width + 2 * grow, height: height)
    top.origin.x = min(max(top.minX, area.minX + 1), area.maxX - top.width - 1)
    frame = top.union(key).insetBy(dx: -4, dy: -4)
    let local = { (rect: CGRect) in rect.offsetBy(dx: -self.frame.minX, dy: -self.frame.minY) }
    let bubble = local(top)
    let base = local(key)
    let path = UIBezierPath()
    let r: CGFloat = 10
    let kr = KeyboardTheme.cornerRadius
    let neck = bubble.maxY + 10
    path.move(to: CGPoint(x: bubble.minX + r, y: bubble.minY))
    path.addLine(to: CGPoint(x: bubble.maxX - r, y: bubble.minY))
    path.addArc(withCenter: CGPoint(x: bubble.maxX - r, y: bubble.minY + r), radius: r,
      startAngle: -.pi / 2, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: bubble.maxX, y: bubble.maxY - 6))
    path.addQuadCurve(to: CGPoint(x: base.maxX, y: neck), controlPoint: CGPoint(x: base.maxX, y: bubble.maxY))
    path.addLine(to: CGPoint(x: base.maxX, y: base.maxY - kr))
    path.addArc(withCenter: CGPoint(x: base.maxX - kr, y: base.maxY - kr), radius: kr,
      startAngle: 0, endAngle: .pi / 2, clockwise: true)
    path.addLine(to: CGPoint(x: base.minX + kr, y: base.maxY))
    path.addArc(withCenter: CGPoint(x: base.minX + kr, y: base.maxY - kr), radius: kr,
      startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: base.minX, y: neck))
    path.addQuadCurve(to: CGPoint(x: bubble.minX, y: bubble.maxY - 6), controlPoint: CGPoint(x: base.minX, y: bubble.maxY))
    path.addLine(to: CGPoint(x: bubble.minX, y: bubble.minY + r))
    path.addArc(withCenter: CGPoint(x: bubble.minX + r, y: bubble.minY + r), radius: r,
      startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
    path.close()
    shape.path = path.cgPath
    shape.fillColor = KeyboardTheme.key(dark).cgColor
    text.textColor = KeyboardTheme.label(dark)
    text.text = value
    text.frame = bubble.offsetBy(dx: 0, dy: -2)
    isHidden = false
  }
}
