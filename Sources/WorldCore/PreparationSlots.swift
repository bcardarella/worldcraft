import Foundation

/// Cancellation is cooperative. Invalidating work does not free its slot until
/// the worker actually returns, including across world changes. Executor-owned.
public struct PreparationSlots<Key: Hashable & Sendable>: Sendable {
  private let limit: Int
  private var running: [UUID: Key] = [:]
  private var current: [Key: UUID] = [:]
  public init(limit: Int) { precondition(limit > 0); self.limit = limit }
  public var count: Int { running.count }
  public var available: Int { max(0, limit - count) }
  public func contains(_ key: Key) -> Bool { current[key] != nil }
  public func isCurrent(_ token: UUID) -> Bool {
    running[token].map { current[$0] == token } ?? false
  }
  public mutating func reserve(_ key: Key) -> UUID? {
    guard available > 0, !contains(key) else { return nil }
    let token = UUID(); running[token] = key; current[key] = token
    return token
  }
  @discardableResult public mutating func invalidate(_ key: Key) -> UUID? {
    current.removeValue(forKey: key)
  }
  public mutating func invalidateAll() { current.removeAll() }
  public mutating func finish(_ token: UUID) {
    guard let key = running.removeValue(forKey: token) else { return }
    if current[key] == token { current[key] = nil }
  }
}
