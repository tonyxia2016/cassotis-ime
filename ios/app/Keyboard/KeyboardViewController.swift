import UIKit

// Plain UIKit keys: this is the floor a real UI adds to, so the difference between
// it and the SwiftUI keyboard is a number of its own.
final class KeyboardViewController: CommandKeyboardController {
  private let candidateBar = UIStackView()
  private var candidateButtons: [UIButton] = []
  private var candidates: [String] = []

  // MARK: - Layout

  override func buildKeyboard() {
    let root = UIStackView()
    root.axis = .vertical
    root.spacing = 6
    root.translatesAutoresizingMaskIntoConstraints = false
    guard let host = inputView else { return }
    host.addSubview(root)
    let height = host.heightAnchor.constraint(equalToConstant: 262)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([
      height,
      root.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
      root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 3),
      root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -3),
      root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -4),
    ])

    candidateBar.axis = .horizontal
    candidateBar.distribution = .fillProportionally
    candidateBar.spacing = 4
    candidateBar.heightAnchor.constraint(equalToConstant: 38).isActive = true
    for index in 0..<5 {
      let button = UIButton(type: .system)
      button.tag = index
      button.titleLabel?.font = .systemFont(ofSize: 19)
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
      button.isHidden = true
      candidateButtons.append(button)
      candidateBar.addArrangedSubview(button)
    }
    root.addArrangedSubview(candidateBar)

    for row in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
      let line = UIStackView()
      line.axis = .horizontal
      line.distribution = .fillEqually
      line.spacing = 5
      for letter in row {
        line.addArrangedSubview(key(String(letter), action: #selector(letterTapped(_:))))
      }
      if row.first == "z" {
        line.addArrangedSubview(key("⌫", action: #selector(deleteTapped)))
      }
      root.addArrangedSubview(line)
    }
    let bottom = UIStackView()
    bottom.axis = .horizontal
    bottom.spacing = 5
    bottom.distribution = .fill
    let globe = key("🌐", action: #selector(UIInputViewController.handleInputModeList(from:with:)))
    globe.removeTarget(nil, action: nil, for: .allEvents)
    globe.addTarget(
      self, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
      for: .allTouchEvents)
    globe.widthAnchor.constraint(equalToConstant: 44).isActive = true
    let space = key("空格", action: #selector(spaceTapped))
    let enter = key("换行", action: #selector(returnTapped))
    enter.widthAnchor.constraint(equalToConstant: 70).isActive = true
    bottom.addArrangedSubview(globe)
    bottom.addArrangedSubview(space)
    bottom.addArrangedSubview(enter)
    root.addArrangedSubview(bottom)
  }

  private func key(_ title: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 20)
    button.backgroundColor = .secondarySystemBackground
    button.layer.cornerRadius = 5
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  // MARK: - Typing

  @objc private func letterTapped(_ sender: UIButton) {
    if let letter = sender.title(for: .normal) { pressText(letter) }
  }
  @objc private func spaceTapped() { pressSpecial(5, fallback: " ") }
  @objc private func returnTapped() { pressSpecial(3, fallback: "\n") }
  @objc private func deleteTapped() { pressDelete() }
  @objc private func candidateTapped(_ sender: UIButton) {
    if sender.tag < candidates.count { pickCandidate(sender.tag) }
  }

  // Five buttons, no scrolling: the measurement floor needs no more.
  override func showCandidates(_ candidates: [String], preedit: String, more: Bool) {
    self.candidates = candidates
    for (index, button) in candidateButtons.enumerated() {
      if index < candidates.count {
        button.setTitle(candidates[index], for: .normal)
        button.isHidden = false
      } else if !button.isHidden {
        button.isHidden = true
      }
    }
  }
}
