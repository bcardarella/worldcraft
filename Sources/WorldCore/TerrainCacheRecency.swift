/// Executor-owned LRU order with constant-time touch/removal. Links contain
/// keys rather than owning one another, so clearing or copying cannot leak a
/// reference cycle. Payload/byte ownership remains in the surrounding cache.
struct TerrainCacheRecency<Key: Hashable & Sendable>: Sendable {
  private struct Link: Sendable { var previous: Key?; var next: Key? }
  private var links: [Key: Link] = [:]
  private(set) var oldest: Key?
  private var newest: Key?
  var count: Int { links.count }

  mutating func touch(_ key: Key) {
    guard newest != key else { return }
    remove(key)
    links[key] = .init(previous: newest, next: nil)
    if let newest { links[newest]?.next = key }
    else { oldest = key }
    newest = key
  }
  mutating func remove(_ key: Key) {
    guard let link = links.removeValue(forKey: key) else { return }
    if let previous = link.previous { links[previous]?.next = link.next }
    else { oldest = link.next }
    if let next = link.next { links[next]?.previous = link.previous }
    else { newest = link.previous }
  }
}
