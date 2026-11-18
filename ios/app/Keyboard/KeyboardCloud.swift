import UIKit

/// The extension keeps the engine and its dictionary in its own sandbox, including
/// when Full Access is off. A signed App Group carries compressed batches for the host.
enum KeyboardCloud {
  static let group = "group.com.hustmobile.cassotis"

  static let usedGroup = "CassotisConfiguredBackgroundSync"

  static var relay: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
      .appendingPathComponent("KeyboardSync.sqlite")
  }

  static func make(path: String) -> CassotisCloudSync {
    CassotisCloudSync(databasePath: path, deviceToken: UIDevice.current.identifierForVendor?.uuidString ?? "",
      platform: "iOS", label: "iOS", zone: CassotisSyncZone)
  }

  static func configure(_ sync: CassotisCloudSync, fullAccess: Bool) {
    guard fullAccess, let relay, let shared = UserDefaults(suiteName: group) else {
      sync.relayPath = nil
      if UserDefaults.standard.bool(forKey: usedGroup), let shared = UserDefaults(suiteName: group) {
        sync.preferences = shared
      } else { sync.preferences = .standard }
      return
    }
    // Preserve a choice made on a build signed without the App Group.
    let key = "CassotisCloudSyncDisabled"
    if let pending = UserDefaults.standard.object(forKey: key) {
      shared.set(pending, forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
    UserDefaults.standard.set(true, forKey: usedGroup)
    sync.preferences = shared
    sync.relayPath = relay.path
  }
}
