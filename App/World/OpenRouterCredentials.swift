import Foundation
import Security

enum OpenRouterCredentials {
  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.worldcraft.vision.openrouter",
      kSecAttrAccount as String: "player-api-key"]
  }
  static func load() -> String? {
    // BuildCredentials is generated inside the app from build-time environment
    // variables. No credential resource lives in the source tree.
    if let key = normalized(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]) { return key }
    return savedKey() ?? bundledKey
  }
  static var hasSavedKey: Bool { savedKey() != nil }

  private static func savedKey() -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data else { return nil }
    return normalized(String(data: data, encoding: .utf8))
  }

  private static let bundledKey: String? = {
    guard let url = Bundle.main.url(forResource: "BuildCredentials", withExtension: "plist"),
      let data = try? Data(contentsOf: url),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
    else { return nil }
    return normalized(values["OPENROUTER_API_KEY"])
  }()

  private static func normalized(_ key: String?) -> String? {
    guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
    return key
  }
  static func save(_ key: String) throws {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
    let data = Data(key.utf8)
    let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
  static func remove() { SecItemDelete(query as CFDictionary) }
}
