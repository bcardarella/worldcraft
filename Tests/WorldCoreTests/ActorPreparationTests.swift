import XCTest
@testable import WorldCore

final class ActorPreparationTests: XCTestCase {
  @MainActor func testAsyncPreparationPreservesArticulationPaletteAndDistantGeometry() async {
    let worker = ActorMeshPreparation()
    let recipes: [ActorRecipe] = [.animal(.init(kind: .dog, id: 45, juvenile: false)),
      .dinosaur(.init(kind: .trex, color: .purple, id: 9, juvenile: true)),
      .resident(.init(id: 77, role: .builder, habitat: .surface))]
    for recipe in recipes + recipes {
      let prepared = await worker.prepare(recipe), source = recipe.sculpture()
      XCTAssertEqual(prepared.sculpture.colors, source.colors)
      XCTAssertEqual(prepared.parts.count, source.parts.count)
      for (i, part) in source.parts.enumerated() {
        let expected = PackedTerrainMesh(source.mesh(for: part)), actual = prepared.parts[i]
        assertSameMesh(actual, expected)
      }
      assertSameMesh(prepared.combined, PackedTerrainMesh(source.combinedMesh()))
    }
  }
  private func assertSameMesh(_ actual: PackedTerrainMesh, _ expected: PackedTerrainMesh, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.indices, expected.indices, file: file, line: line)
    XCTAssertEqual(actual.vertices.count, expected.vertices.count, file: file, line: line)
    for (a, b) in zip(actual.vertices, expected.vertices) {
      XCTAssertEqual([a.px, a.py, a.pz], [b.px, b.py, b.pz], file: file, line: line)
      XCTAssertEqual([a.u, a.v], [b.u, b.v], file: file, line: line)
      XCTAssertEqual(a.normal, b.normal, file: file, line: line)
      XCTAssertEqual(a.tangent, b.tangent, file: file, line: line)
      XCTAssertEqual(a.bitangent, b.bitangent, file: file, line: line)
    }
  }
}
