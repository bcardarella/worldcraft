import GameController
import RealityKit
import SwiftUI
import WorldCore

#if os(visionOS)
struct ImmersiveWorldView: View {
  @Bindable var game: GameSession
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
  @Environment(\.openWindow) private var openWindow
  @FocusState private var gameHasFocus: Bool

  var body: some View {
    RealityView { content, attachments in
      if let hotbar = attachments.entity(for: "hotbar") {
        hotbar.position = [0, -0.40, -1.5]
        hotbar.scale = .init(repeating: 1.5)
        game.headAnchor.addChild(hotbar)
      }
      if let pause = attachments.entity(for: "pause") {
        pause.position = [0, 0, -1.6]
        pause.isEnabled = false
        game.headAnchor.addChild(pause)
      }
      if let loading = attachments.entity(for: "loading") {
        loading.position = [0, 0, -1.6]
        game.headAnchor.addChild(loading)
      }
      if let inventory = attachments.entity(for: "inventory") {
        inventory.position = [0, 0, -1.6]
        inventory.scale = .init(repeating: 1.5)
        inventory.isEnabled = false
        game.headAnchor.addChild(inventory)
      }
      let crosshair = Entity()
      let white = UnlitMaterial(color: .init(white: 1, alpha: 0.8))
      for size: SIMD3<Float> in [[0.012, 0.002, 0.001], [0.002, 0.012, 0.001]] {
        crosshair.addChild(ModelEntity(mesh: .generateBox(size: size), materials: [white]))
      }
      crosshair.name = "crosshair"
      crosshair.position = [0, 0, -1.5]
      game.headAnchor.addChild(crosshair)
      game.start(content: content)
    } update: { _, attachments in
      attachments.entity(for: "pause")?.isEnabled = game.isPaused
      attachments.entity(for: "inventory")?.isEnabled = game.inventoryOpen && !game.isPaused
      attachments.entity(for: "hotbar")?.isEnabled = !game.inventoryOpen
      attachments.entity(for: "loading")?.isEnabled = game.isLoading && !game.isPaused
      game.headAnchor.findEntity(named: "crosshair")?.isEnabled = !game.isPaused && !game.inventoryOpen && !game.isLoading
    } attachments: {
      Attachment(id: "hotbar") {
        HotbarView(game: game).modifier(InventoryGazeFade(alwaysVisible: game.errorMessage != nil))
          .handlesGameControllerEvents(matching: .gamepad)
      }
      Attachment(id: "pause") { PauseView(game: game) }
      Attachment(id: "loading") {
        VStack(spacing: 14) {
          ProgressView()
          Text(game.status).font(.headline)
          if let error = game.errorMessage {
            Text(error).font(.callout).foregroundStyle(.orange)
          }
          Button("Return to lobby") { game.leaveWorld() }
        }
        .multilineTextAlignment(.center)
        .padding(28).frame(width: 360)
        .glassBackgroundEffect()
      }
      Attachment(id: "inventory") {
        InventoryView(game: game).modifier(InventoryGazeFade())
          .handlesGameControllerEvents(matching: .gamepad)
      }
    }
    .handlesGameControllerEvents(matching: .gamepad)
    .focusable()
    .focusEffectDisabled()
    .focused($gameHasFocus)
    .modifier(WorldRecenterHandler(game: game))
    .onAppear { gameHasFocus = true }
    .onChange(of: scenePhase) { _, phase in
      game.sceneActivityChanged(isActive: phase == .active)
      if phase == .active { gameHasFocus = true }
    }
    .onChange(of: game.isPaused) { _, paused in
      if !paused { gameHasFocus = true }
    }
    .onChange(of: game.inventoryOpen) { _, open in
      if !open { gameHasFocus = true }
    }
    .onChange(of: game.exitRequested) { _, requested in
      if requested {
        Task {
          await game.saveAndStop()
          await dismissImmersiveSpace()
          openWindow(id: "lobby")
        }
      }
    }
    .onDisappear {
      Task {
        if game.isImmersed {
          await game.saveAndStop()
          openWindow(id: "lobby")
        }
      }
    }
  }
}

/// The system evaluates gaze outside the app process. Keep the hit region
/// stable while fading its rendering, including gaps between inventory slots.
private struct InventoryGazeFade: ViewModifier {
  var alwaysVisible = false
  func body(content: Content) -> some View {
    content
      .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 20))
      .hoverEffect { effect, active, _ in
        effect.animation(.easeInOut(duration: active ? 0.18 : 0.45).delay(active ? 0 : 0.65)) {
          $0.opacity(active || alwaysVisible ? 1 : 0)
        }
      }
      .hoverEffectGroup()
  }
}

private struct WorldRecenterHandler: ViewModifier {
  let game: GameSession

  @ViewBuilder func body(content: Content) -> some View {
    if #available(visionOS 26.0, *) {
      content.onWorldRecenter { phase in
        switch phase {
        case .began: game.beginWorldRecenter()
        case .ended: game.recenterOrientation()
        @unknown default: break
        }
      }
    } else {
      content
    }
  }
}
#endif

struct HotbarView: View {
  let game: GameSession
  var body: some View {
    VStack(spacing: 8) {
      if game.isInSpace {
        VStack(spacing: 3) {
          Text("Destination: \(game.destinationName)").font(.system(size: 13, weight: .semibold))
          Text(game.navigation).font(.system(size: 10, design: .monospaced)).foregroundStyle(
            .white.opacity(0.8))
        }.padding(.horizontal, 12).padding(.vertical, 7).background(
          .black.opacity(0.6), in: .rect(cornerRadius: 10))
      } else {
        HStack(spacing: 8) {
          Text(game.planetName).fontWeight(.semibold)
          if !game.settlementName.isEmpty {
            Text("· \(game.settlementName)")
            Label("\(game.residentCount)", systemImage: "person.fill")
          }
        }.font(.system(size: 11))
      }
      if game.flying && !game.isPaused { FlightStatus(game: game) }
      if !game.rocketStatus.isEmpty && !game.isPaused {
        Text(game.rocketStatus).font(.system(size: 11, weight: .medium))
          .foregroundStyle(.cyan).multilineTextAlignment(.center).frame(maxWidth: 460)
      }
      if !game.npcPrompt.isEmpty && !game.isPaused {
        Text(game.npcPrompt).font(.system(size: 12, weight: .semibold)).foregroundStyle(.yellow)
          .multilineTextAlignment(.center).frame(maxWidth: 480)
      }
      if !game.npcConversation.isEmpty && !game.isPaused {
        Text(game.npcConversation).font(.system(size: 13)).multilineTextAlignment(.center)
          .frame(maxWidth: 440).padding(10).background(.black.opacity(0.75), in: .rect(cornerRadius: 10))
      }
      if !game.targetName.isEmpty && !game.isPaused {
        Text(game.targetName).font(.system(size: 11, weight: .medium, design: .monospaced))
          .padding(.horizontal, 10).padding(.vertical, 4).background(
            .black.opacity(0.35), in: .capsule)
      }
      if game.throwingStrength>0 && !game.isPaused {
        VStack(spacing:3) {
          Text("THROW · \(Int(game.throwingStrength*100))% power · \(Int(game.throwingAccuracy*100))% accuracy").font(.system(size:11,weight:.semibold))
          ProgressView(value:game.throwingStrength).tint(.orange).frame(width:180)
          ProgressView(value:game.throwingAccuracy).tint(.mint).frame(width:180)
        }
      }
      if game.gatheringProgress > 0 && !game.isPaused {
        ProgressView(value: game.gatheringProgress).tint(.yellow).frame(width: 150)
      }
      if !game.gatheringNotice.isEmpty && !game.isPaused {
        Text(game.gatheringNotice).font(.system(size: 12, weight: .medium)).foregroundStyle(.mint)
          .multilineTextAlignment(.center).frame(maxWidth: 440)
      }
      HStack(spacing: 5) {
        ForEach(0..<Inventory.hotbarCount, id: \.self) { index in
          InventorySlotView(stack: game.inventory[index], slot: index, suffix: game.inventorySuffix,
            equipped: game.selectedSlot == index)
        }
      }.padding(8).background(.black.opacity(0.62), in: .rect(cornerRadius: 12))
      HStack(spacing: 12) {
        Text(game.status)
        Text("I / D-pad ↑: backpack").opacity(0.7)
        Text(game.coordinates).opacity(0.55)
      }.font(.system(size: 10, design: .monospaced))
      if !game.isInSpace {
        HStack(spacing: 14) {
          Label(game.worldClock, systemImage: "sun.horizon")
          Text(game.tideDescription)
          Text(game.biomeName)
          Label("\(game.animalCount)", systemImage: "pawprint")
          Text("\(game.dinosaurCount) dinosaurs")
          if game.hayHayCount > 0 { Text("\(game.hayHayCount) Hay Hays") }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
      }
      if !game.dinosaurMessage.isEmpty {
        Text(game.dinosaurMessage).font(.system(size: 12, weight: .bold)).foregroundStyle(.pink)
      }
      if game.showPerformance {
        VStack(spacing: 3) {
          Text(game.performanceSummary)
          Text(game.performanceDetail).foregroundStyle(.white.opacity(0.7))
          Text(game.npcDecisionStatus).foregroundStyle(.white.opacity(0.7))
        }.font(.system(size: 10, design: .monospaced))
          .padding(8).background(.black.opacity(0.65), in: .rect(cornerRadius: 8))
      }
      if let error = game.errorMessage {
        Text(error).font(.system(size: 10)).foregroundStyle(.orange).frame(maxWidth: 370)
      }
    }.foregroundStyle(.white)
  }
}

struct FlightStatus: View {
  let game: GameSession
  var body: some View {
    HStack(spacing: 14) {
      Text("\(Int(game.flightSpeed)) m/s").font(
        .system(size: 13, weight: .semibold, design: .monospaced))
      Text(game.isInSpace ? "Left stick: thrust · Right stick: steer" : "Space / A: rise · Control / B: descend").font(.system(size: 10))
    }.padding(.horizontal, 14).padding(.vertical, 8)
      .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
  }
}

struct PauseView: View {
  @Bindable var game: GameSession
  var panelHeight: CGFloat = 660
  #if os(visionOS)
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
  @Environment(\.openWindow) private var openWindow
  #endif
  @State private var leaving = false

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        Image(systemName: "leaf").font(.system(size: 26)).foregroundStyle(
          Color(red: 0.89, green: 0.76, blue: 0.46))
        Text("A moment of quiet.").font(.system(size: 27, weight: .bold, design: .serif))
        Text("Your world is saved as you play.").font(.system(size: 13)).foregroundStyle(.secondary)
        Text(
          "WASD / left stick: move · Right stick: look\nDouble Space / A: creative flight · F / Y: toggle\nSpace / A: rise · Control / B: descend · Shift / L3: toggle run or faster flight\nPaddles / LB RB: hotbar · Hold RT: harvest · Square / X: place · LT: use / feed\nI / D-pad Up: backpack · Blocks and plants fill your inventory"
        )
        .font(.system(size: 11, design: .monospaced)).multilineTextAlignment(.center).lineSpacing(5)
        Text("Esc / Menu: resume · L / B: save & leave")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        DrawDistanceControl(game: game).padding(.vertical, 4)
        Text("R / LT: use or talk · V / D-pad Down: camera").font(.system(size: 11, design: .monospaced))
        NPCLifeSettings(game: game)
        Toggle("Third-person camera", isOn: $game.thirdPerson)
        Button(GamePresentation.recenterLabel) { game.recenterOrientation() }
        Button("Back to the world") { game.setPaused(false) }.buttonStyle(.borderedProminent)
        Button(leaving ? "Saving…" : "Save & leave") {
          leaving = true
          #if os(visionOS)
          Task {
            await game.saveAndStop()
            await dismissImmersiveSpace()
            openWindow(id: "lobby")
            leaving = false
          }
          #else
          game.leaveWorld()
          #endif
        }.disabled(leaving)
      }.padding(30)
    }.frame(width: 430, height: panelHeight).gamePanelBackground()
      .handlesGameControllerEvents(matching: .gamepad)
  }
}
