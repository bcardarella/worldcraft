import SwiftUI
import WorldCore

private let parchment = Color(red: 0.94, green: 0.91, blue: 0.80)
private let gold = Color(red: 0.95, green: 0.73, blue: 0.36)

#if os(visionOS)
struct LobbyView: View {
  @Bindable var game: GameSession
  @Environment(\.openImmersiveSpace) private var openImmersiveSpace
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var entering = false
  @State private var showControls = false

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 9) {
          Image(systemName: "cube.fill").foregroundStyle(gold)
          Text("A LITTLE PLACE. ENDLESS POSSIBILITIES.")
            .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
        }
        Spacer(minLength: 0)
        VStack(alignment: .leading, spacing: 8) {
          Text("Worldcraft")
            .font(.system(size: 61, weight: .black, design: .serif)).tracking(-3)
          Text("Step into somewhere new.")
            .font(.system(size: 23, weight: .medium, design: .serif)).foregroundStyle(gold)
        }
        Text(
          "Deep oceans. Snowy peaks. A village to call home.\nFollow the clouds to a whole new planet."
        )
        .font(.system(size: 16)).lineSpacing(5).foregroundStyle(parchment.opacity(0.7))
        HStack(spacing: 18) {
          Label("Head-tracked", systemImage: "visionpro")
          Label("Spatial sound", systemImage: "waveform")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(parchment.opacity(0.65))
        Spacer(minLength: 0)
        HStack {
          Circle().fill(gold).frame(width: 6, height: 6)
          Text("CREATIVE SANDBOX · VISION PRO")
            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2)
        }
      }
      .padding(36)
      .frame(width: 440)
      .frame(maxHeight: .infinity)
      .background(Color(red: 0.075, green: 0.14, blue: 0.12))

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          WorldPreview(seed: UInt64(game.seedText) ?? 8192)
            .frame(height: 204)
            .overlay(alignment: .topLeading) {
              Text("YOUR NEXT HORIZON")
                .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                .foregroundStyle(parchment.opacity(0.65)).padding(.top, 14)
            }
          HStack(alignment: .firstTextBaseline) {
            Text("Choose your world").font(.system(size: 24, weight: .bold, design: .serif))
            Spacer()
            Text("01 / EXPLORE").font(.system(size: 10, design: .monospaced)).foregroundStyle(gold)
          }
          HStack {
            Text("World seed").font(.system(size: 13, weight: .semibold))
            Spacer()
            TextField("8192", text: $game.seedText)
              .font(.system(size: 16, design: .monospaced))
              .textFieldStyle(.roundedBorder).frame(width: 150)
              .accessibilityLabel("World seed, a whole number")
            Button {
              game.seedText = String(UInt64.random(in: 1...999_999_999))
            } label: {
              Image(systemName: "shuffle")
            }
            .accessibilityLabel("Choose a random world seed")
          }
          Text(
            "The same seed grows the same landscape. Changing it starts a new world and replaces the saved world when you play."
          )
          .font(.system(size: 11)).foregroundStyle(parchment.opacity(0.6))
          HStack {
            Label(game.input.deviceDescription, systemImage: "gamecontroller")
              .font(.system(size: 12)).foregroundStyle(gold)
            Spacer()
            Button("Controls") { showControls.toggle() }.font(.system(size: 12))
          }
          DisclosureGroup("Settings") {
            VStack(spacing: 12) {
              Toggle("Smooth turning", isOn: $game.smoothTurning).font(.system(size: 13))
              Text(
                "Small stick movements look more slowly. Headset movement stays independent."
              )
              .font(.system(size: 11)).foregroundStyle(parchment.opacity(0.6))
              HStack {
                Text("Look speed").font(.system(size: 12)).frame(width: 85, alignment: .leading)
                Slider(value: $game.turnSpeed, in: 30...180, step: 15).tint(gold)
                Text("\(Int(game.turnSpeed))°/s").font(.system(size: 11, design: .monospaced))
                  .frame(width: 53)
              }
              Toggle("Head-directed walking", isOn: $game.headDirectedMovement).font(
                .system(size: 13))
              Toggle("Show voxel hands", isOn: $game.showHands).font(.system(size: 13))
              Toggle("Third-person camera", isOn: $game.thirdPerson).font(.system(size: 13))
              volume("Music", value: $game.musicVolume)
              volume("World sounds", value: $game.effectsVolume)
              DrawDistanceControl(game: game).tint(gold)
              NPCLifeSettings(game: game)
            }.padding(.top, 10)
          }
          .font(.system(size: 13, weight: .semibold))
          if let message = game.errorMessage {
            Text(message).font(.system(size: 12)).foregroundStyle(.orange)
          }
          Button {
            entering = true
            Task {
              do {
                try game.prepare()
                switch await openImmersiveSpace(id: "world") {
                case .opened: dismissWindow(id: "lobby")
                case .userCancelled:
                  game.report("Immersion was cancelled. Your world is ready when you are.")
                case .error: game.report("visionOS could not open the immersive world.")
                @unknown default: game.report("The immersive world is unavailable.")
                }
              } catch { game.report("Could not create the world: \(error.localizedDescription)") }
              entering = false
            }
          } label: {
            HStack {
              if entering { ProgressView().tint(.black) }
              Text(entering ? "Growing your world…" : "Enter your world")
              Spacer()
              Image(systemName: "arrow.up.right")
            }.font(.system(size: 16, weight: .bold)).padding(.vertical, 6)
          }
          .buttonStyle(.borderedProminent).tint(gold).foregroundStyle(
            Color(red: 0.10, green: 0.16, blue: 0.12)
          )
          .disabled(entering || !game.seedIsValid || game.isImmersed || game.isStopping)
          Text(game.status).font(.system(size: 11)).foregroundStyle(parchment.opacity(0.5))
        }.padding(.horizontal, 30).padding(.vertical, 20)
      }
      .frame(width: 560)
      .background(Color(red: 0.105, green: 0.19, blue: 0.16))
    }
    .frame(width: 1000, height: 700)
    .foregroundStyle(parchment)
    .clipShape(RoundedRectangle(cornerRadius: 26))
    .task {
      game.input.start()
      await game.restore()
    }
    .sheet(isPresented: $showControls) { ControlsView() }
  }

  private func volume(_ title: String, value: Binding<Float>) -> some View {
    HStack {
      Text(title).font(.system(size: 12)).frame(width: 85, alignment: .leading)
      Slider(value: value, in: 0...1).tint(gold).accessibilityLabel(title)
    }
  }
}
#endif

struct ControlsView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Make yourself at home.").font(.system(size: 30, weight: .bold, design: .serif))
        Text(
          GamePresentation.controlsIntroduction
        )
        .font(.system(size: 14)).foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 15) {
          GridRow {
            Text("ACTION")
            Text("KEYBOARD / MOUSE")
            Text("GAMEPAD")
          }.font(.system(size: 11, weight: .bold, design: .monospaced))
          row("Move", "W A S D", "Left stick")
          row("Turn heading", "Q / E or mouse X", "Right stick X")
          row("Jump / double-jump to fly", "Space / Space twice", "A / Cross, twice to fly")
          row("Look up / down", "Mouse / Up Down", "Right stick vertical")
          row("Fly / swim up and down", "Hold Space / Control", "Hold A / Cross / B / Circle")
          row("Toggle run / walk", "Press Shift", "Click left stick (L3)")
          row("First / third person", "V", "D-pad Down")
          row("Harvest / place or feed", "Hold mouse L / mouse R, X / Z", "Hold RT / Square (X)")
          row("Select hotbar slot", "1–9, [ / ] or scroll", "Left / right paddle or LB / RB")
          row("Open backpack", "I", "D-pad Up")
          row("Toggle flight", "F", "Y / Triangle")
          row("Space / rocket destination", ", / .", "D-pad left / right")
          row("Use / talk / feed", "R (look at target)", "Left trigger (LT / L2)")
          row("Drive / brake and reverse", "W / S", "RT / LT")
          row("Car entry / exit · handbrake", "R · Space", "Triangle (Y) · R1 (RB)")
          row("Pause", "Esc", "Menu / Options")
        }.font(.system(size: 14))
        DisclosureGroup("Sailing · dinghies and yachts") {
          VStack(alignment:.leading,spacing:14) {
            Grid(alignment:.leading,horizontalSpacing:28,verticalSpacing:12) {
              row("Board / leave", "R", "L2 to board · Triangle / Y to leave")
              row("Steer · paddle / harbour motor", "A / D · W / S", "Left stick X · left stick Y")
              row("Raise / lower sails", "H", "Cross / A")
              row("Drop / raise anchor", "Space", "R1 / RB")
              row("Manual trim in / out", "[ / ]", "R2 / L2")
              row("Resume automatic trim", "T", "L1 / LB")
            }.font(.system(size:13))
            Text("Sails trim automatically until you adjust them. Raise sails, steer across the wind and tack to travel upwind. The slow harbour motor or dinghy paddles help you leave a berth. The wind pennant and sailing display show the apparent wind.")
              .font(.system(size:12)).foregroundStyle(.secondary)
          }.padding(.top,12)
        }
        Text(
          "Blocks are half a metre wide. Ground creative flight hovers when you release the controls. Fly 1 km above the terrain to enter space; riding an animal keeps you on the planet. Space flight uses momentum: steer with the right stick, then push the left stick to accelerate in that full 3D direction. Space / A and Control / B fire local up/down thrusters; releasing thrust slows you gently. Sprint accelerates faster. Approach a planet to land. Your planets save together."
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
        Button("Ready to explore") { dismiss() }.buttonStyle(.borderedProminent).tint(gold)
      }.padding(32)
    }
    #if os(visionOS)
    .frame(width:770,height:760)
    #else
    .frame(maxWidth:770,maxHeight:760)
    #endif
  }
  private func row(_ action: String, _ keyboard: String, _ gamepad: String) -> some View {
    GridRow {
      Text(action).fontWeight(.semibold)
      Text(keyboard).foregroundStyle(.secondary)
      Text(gamepad).foregroundStyle(.secondary)
    }
  }
}

struct WorldPreview: View {
  let seed: UInt64
  var body: some View {
    Canvas { context, size in
      let generator = TerrainGenerator(seed: seed)
      let width: CGFloat = 10
      let depth: CGFloat = 5
      let origin = CGPoint(x: size.width / 2, y: 62)
      func polygon(_ points: [CGPoint], _ color: Color) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        context.fill(path, with: .color(color))
      }
      for sum in 0...34 {
        for x in 0...17 {
          let z = sum - x
          guard (0...17).contains(z) else { continue }
          let height = generator.height(atX: x * 3, z: z * 3)
          let h = CGFloat(max(height, TerrainGenerator.seaLevel) - 8) * 2.4
          let cx = origin.x + CGFloat(x - z) * width
          let cy = origin.y + CGFloat(x + z) * depth - h
          let top = CGPoint(x: cx, y: cy - depth)
          let right = CGPoint(x: cx + width, y: cy)
          let bottom = CGPoint(x: cx, y: cy + depth)
          let left = CGPoint(x: cx - width, y: cy)
          let water = height < TerrainGenerator.seaLevel
          let land =
            water
            ? Color(red: 0.30, green: 0.61, blue: 0.68) : Color(red: 0.55, green: 0.66, blue: 0.35)
          polygon(
            [left, bottom, .init(x: bottom.x, y: bottom.y + h), .init(x: left.x, y: left.y + h)],
            water ? land.opacity(0.8) : Color(red: 0.34, green: 0.37, blue: 0.22))
          polygon(
            [
              bottom, right, .init(x: right.x, y: right.y + h), .init(x: bottom.x, y: bottom.y + h),
            ], water ? land.opacity(0.6) : Color(red: 0.26, green: 0.29, blue: 0.18))
          polygon([top, right, bottom, left], land)
          if !water && generator.hash(x, z) % 23 == 0 {
            context.fill(
              Path(CGRect(x: cx - 2, y: cy - 21, width: 4, height: 21)), with: .color(.brown))
            context.fill(
              Path(CGRect(x: cx - 9, y: cy - 30, width: 18, height: 14)),
              with: .color(Color(red: 0.23, green: 0.40, blue: 0.22)))
            context.fill(
              Path(CGRect(x: cx - 6, y: cy - 36, width: 12, height: 9)),
              with: .color(Color(red: 0.35, green: 0.49, blue: 0.25)))
          }
        }
      }
    }.accessibilityLabel("Isometric preview of your procedural voxel world")
  }
}
