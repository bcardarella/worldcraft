import SwiftUI
import UIKit
import WorldCore

struct InventoryView: View {
  let game: GameSession
  private let columns = Array(repeating: GridItem(.fixed(58), spacing: 6), count: 9)
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Your backpack").font(.system(size: 28, weight: .bold, design: .serif))
          Text("\(game.inventory.occupiedSlots) of 36 slots · Stacks of 64")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
        Button { game.setInventoryOpen(false) } label: { Image(systemName: "xmark") }
          .accessibilityLabel("Close inventory")
      }
      Text("HOTBAR · Paddles / LB RB select the equipped slot")
        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
      LazyVGrid(columns: columns, spacing: 7) {
        ForEach(0..<Inventory.slotCount, id: \.self) { index in
          Button { game.inventorySelect(index) } label: {
            InventorySlotView(stack: game.inventory[index], slot: index, suffix: game.inventorySuffix,
              equipped: index == game.selectedSlot, focused: index == game.inventoryCursor,
              moving: index == game.inventorySource, size: 58)
          }.buttonStyle(.plain)
            .padding(.bottom, index < 9 ? 8 : 0)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        if let stack = game.inventory[game.inventoryCursor] {
          Text("\(stack.item.name) × \(stack.count)").font(.system(size: 17, weight: .semibold))
          Text(itemDescription(stack.item)).font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
          Text("Empty slot").font(.system(size: 17, weight: .semibold))
          Text("Hold RT / left-click to harvest. Walk near drops to collect them.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Text(game.inventorySource == nil ? "Select an item, then select its destination to move or merge it."
          : "Choose a destination · Select the same slot to cancel")
          .font(.system(size: 12)).foregroundStyle(game.inventorySource == nil ? .white.opacity(0.65) : .yellow)
      }.frame(minHeight: 66, alignment: .topLeading)
      if !game.gatheringNotice.isEmpty {
        Text(game.gatheringNotice).font(.system(size: 12)).foregroundStyle(.mint)
      }
      HStack(spacing: 12) {
        Button("Equip to slot \(game.selectedSlot + 1) · R / X (□)") { game.inventoryEquip() }
          .disabled(game.inventory[game.inventoryCursor] == nil)
        Button("Drop one · Delete / Y (△)") { game.inventoryDropOne() }
          .disabled(game.inventory[game.inventoryCursor] == nil)
      }.font(.system(size: 12))
      Text("D-pad / left stick / WASD: navigate · A (×) / Enter: select\nI / B (○) / Esc: close · The world waits while you organize.")
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(4)
    }.padding(24).frame(width: 620).gamePanelBackground()
  }
  private func itemDescription(_ item: InventoryItem) -> String {
    if let food = item.food {
      let eaters = AnimalKind.allCases.filter { $0.foods.contains(food) }.map(\.name)
      if !eaters.isEmpty { return "Food for \(eaters.joined(separator: ", ")). LT / right-click to feed." }
    }
    if item == .baseball {return "Hold RT / left-click to charge, release to throw. The accuracy meter rewards a controlled release."}
    if case .plant(let kind) = item { return kind.aquatic ? "Replant on a seabed beneath water." : "Replant on open soil with Square / X / right-click." }
    return "Place with Square / X / right-click. Breaking effort: \(String(format: "%.1f", item.breakingEffort)) seconds."
  }
}

struct InventorySlotView: View {
  let stack: ItemStack?
  let slot: Int
  let suffix: String
  let equipped: Bool
  var focused = false
  var moving = false
  var size: CGFloat = 44
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      RoundedRectangle(cornerRadius: 6).fill(equipped ? Color.orange.opacity(0.22) : .black.opacity(0.3))
      if let stack {
        Image(uiImage: InventoryIcons.image(for: stack.item, suffix: suffix))
          .resizable().interpolation(.none).padding(5)
        Text("\(stack.count)").font(.system(size: 12, weight: .bold, design: .monospaced))
          .shadow(color: .black, radius: 2).padding(4)
      }
      if slot < 9 {
        Text("\(slot + 1)").font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.65)).padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      RoundedRectangle(cornerRadius: 6).stroke(moving ? .mint : focused ? .white : equipped ? .yellow : .white.opacity(0.12),
        lineWidth: moving || focused || equipped ? 2 : 1)
    }.frame(width: size, height: size)
      .accessibilityLabel("\(stack.map { "\($0.item.name), \($0.count)" } ?? "Empty"), slot \(slot + 1)\(equipped ? ", equipped" : "")")
  }
}

/// Project the same voxel mesh and atlas used in the world into a cached icon.
/// This covers every species/material without a second set of mismatched skins.
@MainActor private enum InventoryIcons {
  private static var images: [String: [InventoryItem: UIImage]] = [:]
  private static var atlases: [String: CGImage] = [:]
  private static var tiles: [String: [Int: UIImage]] = [:]
  static func image(for item: InventoryItem, suffix: String) -> UIImage {
    if let cached = images[suffix]?[item] { return cached }
    let mesh = InventoryGeometry.mesh(for: item)
    if atlases[suffix] == nil { atlases[suffix] = UIImage(named: "BlockAtlas\(suffix).png")?.cgImage }
    let projected = mesh.positions.map { p in
      CGPoint(x: Double((p.x - p.z) * 0.7071), y: Double((p.x + p.z) * 0.3536 - p.y * 0.866))
    }
    let minX = projected.map(\.x).min() ?? 0, maxX = projected.map(\.x).max() ?? 1
    let minY = projected.map(\.y).min() ?? 0, maxY = projected.map(\.y).max() ?? 1
    let scale = 68 / max(maxX - minX, maxY - minY, 0.01)
    let points = projected.map { CGPoint(x: ($0.x - (minX + maxX) / 2) * scale + 40,
      y: ($0.y - (minY + maxY) / 2) * scale + 40) }
    let faces = stride(from: 0, to: mesh.positions.count, by: 4).filter {
      mesh.normals[$0].x + mesh.normals[$0].y + mesh.normals[$0].z > 0
    }.sorted {
      let a = (mesh.positions[$0] + mesh.positions[$0 + 2]) / 2
      let b = (mesh.positions[$1] + mesh.positions[$1 + 2]) / 2
      return a.x + a.y + a.z < b.x + b.y + b.z
    }
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: .init(width: 80, height: 80), format: format).image { context in
      let cg = context.cgContext
      cg.interpolationQuality = .none
      for index in faces {
        let uv = mesh.textureCoordinates[index + 1]
        let column = min(15, max(0, Int(uv.x * 16))), row = min(7, max(0, Int((1 - uv.y) * 8)))
        let tile = row * 16 + column
        if tiles[suffix]?[tile] == nil, let atlas = atlases[suffix],
          let crop = atlas.cropping(to: CGRect(x: column * 64 + 4, y: row * 64 + 4, width: 56, height: 56)) {
          tiles[suffix, default: [:]][tile] = UIImage(cgImage: crop)
        }
        let p0 = points[index], p1 = points[index + 1], p2 = points[index + 2]
        cg.saveGState()
        cg.move(to: p0)
        for offset in 1...3 { cg.addLine(to: points[index + offset]) }
        cg.closePath(); cg.clip()
        cg.concatenate(.init(a: (p2.x - p1.x) / 56, b: (p2.y - p1.y) / 56,
          c: (p0.x - p1.x) / 56, d: (p0.y - p1.y) / 56, tx: p1.x, ty: p1.y))
        if let texture = tiles[suffix]?[tile] { texture.draw(in: .init(x: 0, y: 0, width: 56, height: 56)) }
        else { UIColor.systemGreen.setFill(); cg.fill(.init(x: 0, y: 0, width: 56, height: 56)) }
        cg.restoreGState()
      }
    }
    images[suffix, default: [:]][item] = image
    return image
  }
}
