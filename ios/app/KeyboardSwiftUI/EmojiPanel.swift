import UIKit

@MainActor
protocol EmojiPanelDelegate: AnyObject {
  func emojiPicked(_ emoji: String)
  func emojiDelete()
  func emojiClose()
}

/// A simple emoji keyboard in the style of the system's: a grid that scrolls sideways
/// through the categories, the category's name above it, and a bar with the way back,
/// the categories and delete. A keyboard extension cannot call up the system's own.
final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
  weak var delegate: EmojiPanelDelegate?

  private static let recentKey = "cassotis.recentEmoji"
  private var sections: [(name: String, symbol: String, emoji: [String])] = []
  private let title = UILabel()
  private let grid: UICollectionView
  private let bar = UIStackView()
  private var categoryButtons: [UIButton] = []
  private let back = UIButton(type: .system)
  private let delete = UIButton(type: .system)

  override init(frame: CGRect) {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 16)
    grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(frame: frame)
    grid.backgroundColor = .clear
    grid.showsHorizontalScrollIndicator = false
    grid.keyboardStyle()
    grid.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
    grid.dataSource = self
    grid.delegate = self
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    addSubview(title)
    addSubview(grid)
    back.setTitle("拼音", for: .normal)
    back.titleLabel?.font = .systemFont(ofSize: 16)
    back.addTarget(self, action: #selector(close), for: .touchUpInside)
    delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
    delete.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    bar.axis = .horizontal
    bar.distribution = .fillEqually
    addSubview(back)
    addSubview(bar)
    addSubview(delete)
    reload()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

  /// Recently used first, then the categories.
  func reload() {
    let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    sections = [(name: "常用", symbol: "clock", emoji: recent.isEmpty ? EmojiData.defaults : recent)]
      + EmojiData.categories.map { (name: $0.name, symbol: $0.symbol, emoji: $0.emoji.map(String.init)) }
    categoryButtons.forEach { $0.removeFromSuperview() }
    categoryButtons = sections.indices.map { index in
      let button = UIButton(type: .system)
      button.setImage(
        UIImage(systemName: sections[index].symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)),
        for: .normal)
      button.tag = index
      button.addTarget(self, action: #selector(jump(_:)), for: .touchUpInside)
      bar.addArrangedSubview(button)
      return button
    }
    grid.reloadData()
    title.text = sections.first?.name
    applyColors()
  }

  private func applyColors() {
    let label = KeyboardTheme.label(dark)
    title.textColor = KeyboardTheme.secondary(dark)
    back.tintColor = label
    delete.tintColor = label
    categoryButtons.forEach { $0.tintColor = KeyboardTheme.secondary(dark) }
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    applyColors()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let barHeight: CGFloat = 40
    title.frame = CGRect(x: 14, y: 0, width: bounds.width - 28, height: 22)
    grid.frame = CGRect(x: 6, y: 22, width: bounds.width - 6, height: bounds.height - 22 - barHeight)
    let side: CGFloat = 56
    back.frame = CGRect(x: 4, y: bounds.height - barHeight, width: side, height: barHeight)
    delete.frame = CGRect(x: bounds.width - side - 4, y: bounds.height - barHeight, width: side, height: barHeight)
    bar.frame = CGRect(x: side + 8, y: bounds.height - barHeight, width: bounds.width - 2 * side - 16, height: barHeight)
    if let layout = grid.collectionViewLayout as? UICollectionViewFlowLayout, grid.bounds.height > 0 {
      let rows: CGFloat = 5
      let side = floor(grid.bounds.height / rows)
      if layout.itemSize.height != side {
        layout.itemSize = CGSize(width: side, height: side)
        layout.invalidateLayout()  // the first pass used the default size
      }
    }
  }

  func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    sections[section].emoji.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "e", for: indexPath) as! EmojiCell
    cell.label.text = sections[indexPath.section].emoji[indexPath.item]
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let emoji = sections[indexPath.section].emoji[indexPath.item]
    UIDevice.current.playInputClick()
    var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    recent.removeAll { $0 == emoji }
    recent.insert(emoji, at: 0)
    UserDefaults.standard.set(Array(recent.prefix(30)), forKey: Self.recentKey)
    delegate?.emojiPicked(emoji)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let point = CGPoint(x: scrollView.contentOffset.x + 30, y: 10)
    if let path = grid.indexPathForItem(at: point) { title.text = sections[path.section].name }
  }

  @objc private func jump(_ sender: UIButton) {
    guard sections[sender.tag].emoji.count > 0 else { return }
    grid.scrollToItem(at: IndexPath(item: 0, section: sender.tag), at: .left, animated: false)
    title.text = sections[sender.tag].name
  }

  @objc private func close() { delegate?.emojiClose() }
  @objc private func deleteTapped() {
    UIDevice.current.playInputClick()
    delegate?.emojiDelete()
  }
}

final class EmojiCell: UICollectionViewCell {
  let label = UILabel()
  override init(frame: CGRect) {
    super.init(frame: frame)
    label.font = .systemFont(ofSize: 30)
    label.textAlignment = .center
    contentView.addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = contentView.bounds
  }
}

/// Common emoji by category (Unicode 13 or earlier, so iOS 18 draws them all).
enum EmojiData {
  static let defaults = Array("😂👍❤️😊🙏😭😍🤔👌🎉😁🔥😅🥰😘💪😄🌹😉😢").map(String.init)
  static let categories: [(name: String, symbol: String, emoji: String)] = [
    (
      "表情与人物", "face.smiling",
      "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗😚😙😋😛😜🤪😝🤑🤗🤭🤫🤔🤐🤨😐😑😶😏😒🙄😬🤥😌😔😪🤤😴😷🤒🤕🤢🤮🤧🥵🥶🥴😵🤯🤠🥳😎🤓🧐😕😟🙁☹️😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬😈👿💀💩🤡👻👽🤖😺😸😹😻😼😽🙀😿😾👋🤚🖐️✋🖖👌🤏✌️🤞🤟🤘🤙👈👉👆👇☝️👍👎✊👊🤛🤜👏🙌👐🤲🤝🙏✍️💪👀👶🧒👦👧🧑👱👨🧔👩🧓👴👵"
    ),
    (
      "动物与自然", "pawprint",
      "🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🙈🙉🙊🐔🐧🐦🐤🦆🦅🦉🐺🐴🦄🐝🐛🦋🐌🐞🐢🐍🐙🦀🐠🐟🐬🐳🦈🐘🦒🐄🐑🐕🐈🐇🐿️🌵🎄🌲🌳🌴🌱🌿🍀🍃🍂🍁🍄🌾💐🌷🌹🥀🌺🌸🌼🌻🌞🌝🌙⭐️🌟✨⚡️🔥🌈☀️⛅️☁️🌧️❄️☃️💨💧💦☔️🌊"
    ),
    (
      "食物与饮料", "fork.knife",
      "🍏🍎🍐🍊🍋🍌🍉🍇🍓🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥬🥒🌶️🌽🥕🧄🧅🥔🍠🥐🍞🥖🧀🥚🍳🥞🥓🥩🍗🍖🌭🍔🍟🍕🥪🌮🌯🥗🍝🍜🍲🍛🍣🍱🥟🍤🍙🍚🍘🍥🥮🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰🥜🍯🥛☕️🍵🧃🥤🧋🍶🍺🍻🥂🍷🥃🍸🍹🍾🥢🍴"
    ),
    (
      "活动", "soccerball",
      "⚽️🏀🏈⚾️🎾🏐🏉🎱🏓🏸🏒⛳️🏹🎣🥊🥋🛹⛸️🎿🏂🏋️🤸🏊🚴🧘🏆🥇🥈🥉🏅🎖️🎫🎪🎭🎨🎬🎤🎧🎼🎹🥁🎷🎺🎸🎻🎲♟️🎯🎳🎮🧩"
    ),
    (
      "旅行与地点", "car",
      "🚗🚕🚙🚌🏎️🚓🚑🚒🚐🚚🚜🛵🏍️🚲🛴🚨🚃🚄🚅🚇✈️🛫🛬🚀🛸🚁⛵️🚤🚢⚓️⛽️🚧🚦🗺️🗽🗼🏰🏯🎡🎢🎠⛲️🏖️🏝️🌋⛰️🏔️🗻🏕️🏠🏡🏢🏬🏥🏦🏨🏪🏫💒⛪️🌅🌄🌠🎇🎆🌇🌆🏙️🌃🌌🌉"
    ),
    (
      "物品", "lightbulb",
      "⌚️📱💻⌨️🖥️🖨️🖱️💾💿📷📸📹🎥📞☎️📺📻⏰⏱️⌛️⏳🔋🔌💡🔦🕯️💸💵💴💰💳💎⚖️🔧🔨🛠️⚙️🧲💣🔪🛡️🔮💈🔭🔬💊💉🧬🧪🌡️🧹🧺🧻🚿🛁🧼🧽🔑🗝️🚪🪑🛋️🛏️🧸🖼️🛍️🛒🎁🎈🎀🎊🎉🏮🧧✉️📧💌📦🏷️📮📜📃📄📊📈📉🗓️📅🗑️📋📁📂📰📓📕📗📘📙📚📖🔖🔗📎📐📏📌📍✂️🖊️✒️🖌️🖍️📝✏️🔍🔎🔒🔓"
    ),
    (
      "符号", "heart",
      "❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💟☮️☯️✅☑️✔️❌❎➕➖➗➰➿〽️✳️✴️❇️‼️⁉️❓❔❕❗️〰️©️®️™️🔟🔠🔡🔢🔣🔤🆔🆗🆕🆓🆒🆙🆘🈶🈚️🈸🈺🈷️🉐㊗️㊙️🔴🟠🟡🟢🔵🟣🟤⚫️⚪️🟥🟧🟨🟩🟦🟪🟫⬛️⬜️🔶🔷🔸🔹🔺🔻💠🔘"
    ),
    (
      "旗帜", "flag",
      "🏳️🏴🏁🚩🇨🇳🇭🇰🇲🇴🇺🇸🇬🇧🇯🇵🇰🇷🇫🇷🇩🇪🇮🇹🇪🇸🇷🇺🇨🇦🇦🇺🇸🇬🇲🇾🇹🇭🇻🇳🇮🇳🇧🇷🇲🇽🇳🇿"
    ),
  ]
}
