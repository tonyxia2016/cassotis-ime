import SwiftUI
import UIKit

// Everything the fcitx5-ios panel (uipanel/*.swift, GPL-3.0) wants from outside.
// scripts/import_fcitx_ui.sh copies those files into one Swift module and drops
// their imports of Fcitx, UIPanel, FcitxIpc and SwiftUtil; this file answers for
// those four modules. Thirty-odd names is the whole seam:
//   UIPanel (C++ addon) - candidates and status area, routed to the Cassotis engine
//   Fcitx   (C++ runtime) - input method list, clipboard preferences
//   SwiftUtil, FcitxIpc  - paths and JSON helpers
//   Clipboard history   - stubbed; GRDB and a store are not part of phase 0

let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let appBundleUrl = Bundle.main.bundleURL

func removeFile(_ file: URL) -> Bool { (try? FileManager.default.removeItem(at: file)) != nil }

func readJSON(_ file: URL) -> Any? {
  guard let stream = InputStream(url: file) else { return nil }
  stream.open()
  defer { stream.close() }
  return try? JSONSerialization.jsonObject(with: stream)
}

public struct InputMethod: Codable {
  public let name: String
  public let displayName: String
  public let languageCode: String
}

func deserialize<T: Codable>(_ type: T.Type, _ s: String) -> T {
  try! JSONDecoder().decode(type, from: s.data(using: .utf8)!)
}

func getLocale() -> String { "zh_CN" }
func setOpenURLPermissionCheck(_ check: @escaping () -> Bool) {}

// UIPanel
func inputContextIsFocused(_ inputContext: String) -> Bool { true }
func selectCandidate(_ inputContext: String, _ index: Int32) {
  KeyboardViewController.current?.pickCandidate(Int(index))
}
func getCandidateActions(_ inputContext: String, _ index: Int32) -> String { "[]" }
func activateCandidateAction(_ inputContext: String, _ index: Int32, _ id: Int32) {}
func activateCandidateTabAction(_ inputContext: String, _ id: Int32) {}
func activateStatusAreaAction(_ inputContext: String, _ id: Int32) {}
func scroll(_ inputContext: String, _ start: Int32, _ count: Int32) {
  KeyboardViewController.current?.loadCandidates(Int(start), Int(count))
}
func page(_ inputContext: String, _ next: Bool) {}

// Fcitx
func getInputMethods() -> String {
  let list = KeyboardViewController.inputMethods.map {
    ["name": $0.name, "displayName": $0.display, "languageCode": $0.language]
  }
  let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
  return String(decoding: data, as: UTF8.self)
}
func isClipboardSuggestionEnabled() -> Bool { false }
func isClipboardMaskSensitiveEnabled() -> Bool { false }
func getClipboardSuggestionTimeout() -> Int32 { 0 }

// Clipboard history
public struct ClipboardEntry: Equatable, Sendable {
  struct Record: Equatable, Sendable { var deleted = false }
  var record = Record()
}
final class ClipboardStoreStub: Sendable {
  func capture(_ text: String, sensitive: Bool) throws {}
  func togglePin(_ id: UUID) throws {}
  func delete(_ id: UUID) throws -> [ClipboardEntry] { [] }
  func clear(includePinned: Bool) throws -> [ClipboardEntry] { [] }
  func restore(_ entries: [ClipboardEntry]) throws {}
  func reset() throws {}
  func entries() throws -> [ClipboardEntry] { [] }
}
let clipboardStore = ClipboardStoreStub()
struct ClipboardView: View {
  let width: CGFloat
  var body: some View { EmptyView() }
}
