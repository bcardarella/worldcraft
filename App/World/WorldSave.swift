import Foundation
import WorldCore

actor SaveStore {
  private var file: URL {
    URL.applicationSupportDirectory.appending(path: "Worldcraft", directoryHint: .isDirectory)
      .appending(path: "world-v1.json")
  }

  func load() throws -> WorldSave? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let save = try JSONDecoder().decode(WorldSave.self, from: Data(contentsOf: file))
    guard save.isValid
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return save
  }

  func write(_ save: WorldSave) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(save)
    try data.write(to: file, options: .atomic)
  }
}
