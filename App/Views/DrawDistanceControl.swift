import SwiftUI
import WorldCore

struct DrawDistanceControl: View {
  @Bindable var game: GameSession

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Draw distance").fontWeight(.semibold)
        Spacer()
        Text("\(game.renderDistance) chunks · ~\(game.renderDistance * 8) m")
          .monospacedDigit().foregroundStyle(.secondary)
      }.font(.system(size: 12))
      Slider(
        value: Binding(
          get: { Double(game.renderDistance) },
          set: { game.renderDistance = Int($0.rounded()) }),
        in: Double(DrawDistance.range.lowerBound)...Double(DrawDistance.range.upperBound), step: 1
      )
      .accessibilityLabel("Draw distance")
      .accessibilityValue(
        "\(game.renderDistance) chunks, approximately \(game.renderDistance * 8) metres")
      HStack {
        Text("32 m")
        Spacer()
        Text("1,024 m")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      HStack {
        Text("Detail distance").fontWeight(.semibold)
        Spacer()
        Text("~\(min(game.renderDistance, game.detailDistance) * 8) m")
          .monospacedDigit().foregroundStyle(.secondary)
      }.font(.system(size: 12)).padding(.top, 6)
      Slider(value: Binding(get: { Double(game.detailDistance) },
        set: { game.detailDistance = Int($0.rounded()) }),
        in: Double(DrawDistance.detailRange.lowerBound)...Double(DrawDistance.detailRange.upperBound), step: 1)
        .accessibilityLabel("Detail distance")
        .accessibilityValue("Approximately \(min(game.renderDistance, game.detailDistance) * 8) metres")
      Text("Choose 48–128 m of full blocks and buildings, capped by draw distance. Stepped terrain and individual trees continue beyond it. Higher detail uses more memory.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Toggle("Show performance", isOn: $game.showPerformance).font(.system(size: 11))
      if game.showPerformance {
        Text("Also logs a timing sample to the Xcode console every 5 seconds.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        Toggle("Fire particles", isOn: $game.fireParticlesEnabled).font(.system(size: 11))
        Text("Compare performance in the same spot with flames and smoke on or off. Torch lighting stays on.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }
}
