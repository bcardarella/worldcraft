#if os(iOS)
import RealityKit
import SwiftUI
import WorldCore

struct IPadRootView: View {
  let game: GameSession
  var pointerCaptureChanged: (Bool) -> Void = { _ in }
  var gameControllerCaptureChanged: (Bool) -> Void = { _ in }
  @State private var showingWorld = false
  private var capturePointer: Bool {
    showingWorld && game.isImmersed && !game.isLoading && !game.isPaused
      && !game.inventoryOpen && !game.exitRequested && !game.isStopping
  }
  var body: some View {
    Group {
      if showingWorld {
        IPadWorldView(game: game) { showingWorld = false }
      } else {
        IPadLobbyView(game: game) { showingWorld = true }
      }
    }
    .preferredColorScheme(.dark)
    .onChange(of: capturePointer, initial: true) { _, capture in pointerCaptureChanged(capture) }
    // GameInput owns gameplay, inventory, and pause controls. Only the lobby
    // hands the gamepad back to UIKit; touch and mouse remain available in menus.
    .onChange(of: showingWorld, initial: true) { _, capture in gameControllerCaptureChanged(capture) }
    .onDisappear {
      pointerCaptureChanged(false)
      gameControllerCaptureChanged(false)
    }
  }
}

private struct IPadWorldView: View {
  let game: GameSession
  let onExit: () -> Void
  @State private var leaving = false

  var body: some View {
    GeometryReader { size in
      ZStack {
        RealityView { content in
          content.camera = .virtual
          content.renderingEffects.motionBlur = .disabled
          content.renderingEffects.depthOfField = .disabled
          content.renderingEffects.cameraGrain = .disabled
          game.start(content: content)
          content.audioListener = game.screenCamera
        }
        .realityViewCameraControls(.none)
        .ignoresSafeArea()

        if !game.isLoading && !game.isPaused && !game.inventoryOpen {
          Image(systemName: "plus").font(.system(size: 18, weight: .light))
            .foregroundStyle(.white.opacity(0.8)).shadow(radius: 2).allowsHitTesting(false)
          VStack {
            HStack {
              Spacer()
              Button { game.setInventoryOpen(true) } label: { Image(systemName: "backpack") }
                .accessibilityLabel("Open inventory")
              Button { game.setPaused(true) } label: { Image(systemName: "pause.fill") }
                .accessibilityLabel("Pause game")
            }.buttonStyle(.bordered).controlSize(.large)
            Spacer(minLength: 8)
            HotbarView(game: game).padding(10)
              .background(.black.opacity(0.38), in: .rect(cornerRadius: 16))
              .allowsHitTesting(false)
          }.padding(16)
        }
        if game.isLoading && !game.isPaused {
          VStack(spacing: 14) {
            ProgressView()
            Text(game.status).font(.headline)
            if let error = game.errorMessage { Text(error).foregroundStyle(.orange) }
            Button("Return to lobby") { game.leaveWorld() }
          }.multilineTextAlignment(.center).padding(28).frame(width: 360).gamePanelBackground()
        }
        if game.inventoryOpen && !game.isPaused {
          Color.black.opacity(0.45).ignoresSafeArea()
          ScrollView { InventoryView(game: game) }
            .frame(width: min(640, size.size.width - 24), height: min(600, size.size.height - 24))
        }
        if game.isPaused {
          Color.black.opacity(0.45).ignoresSafeArea()
          PauseView(game: game, panelHeight: min(660, size.size.height - 24))
        }
        if leaving {
          Color.black.opacity(0.7).ignoresSafeArea()
          ProgressView("Saving your world…").padding(30).gamePanelBackground()
        }
      }
    }
    // Camera projection and the crosshair share the exact full-screen viewport.
    // Menus retain their own padding inside that viewport.
    .ignoresSafeArea()
    .background(.black)
    .onChange(of: game.exitRequested) { _, requested in
      guard requested, !leaving else { return }
      leaving = true
      Task {
        await game.saveAndStop()
        onExit()
      }
    }
  }
}

private struct IPadLobbyView: View {
  @Bindable var game: GameSession
  let onEnter: () -> Void
  @State private var entering = false
  @State private var showControls = false

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        if geometry.size.width >= 900 {
          VStack(alignment: .leading, spacing: 20) {
            Label("CREATIVE SANDBOX", systemImage: "cube.fill").font(.caption.monospaced())
            Spacer()
            Text("Worldcraft").font(.system(size: 48, weight: .black, design: .serif))
            Text("A whole world in your hands.").font(.title2).foregroundStyle(.yellow)
            Text("Deep oceans. Snowy peaks. Cities full of life. Follow the clouds to another planet.")
              .foregroundStyle(.secondary)
            WorldPreview(seed: UInt64(game.seedText) ?? 8192).frame(height: 230)
            Spacer()
            Label("Gamepad · Keyboard & mouse", systemImage: "gamecontroller")
              .font(.callout).foregroundStyle(.secondary)
          }.padding(30).frame(width: geometry.size.width * 0.40)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Text("Worldcraft").font(.largeTitle.bold())
            Text("Choose your world").font(.title2)
            HStack {
              Text("World seed")
              Spacer()
              TextField("8192", text: $game.seedText).keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder).frame(width: 180)
                .accessibilityLabel("World seed")
              Button { game.seedText = String(UInt64.random(in: 1...999_999_999)) } label: {
                Image(systemName: "shuffle")
              }.accessibilityLabel("Choose a random world seed")
            }
            Text("Changing the seed starts a new world and replaces the saved world when you play.")
              .font(.caption).foregroundStyle(.secondary)
            Label(game.input.deviceDescription, systemImage: "gamecontroller")
            Text("Play with a gamepad or keyboard and mouse. Touch is available for menus and inventory.")
              .font(.callout).foregroundStyle(.secondary)
            Button("Controls") { showControls = true }
            DisclosureGroup("Settings") {
              VStack(spacing: 16) {
                HStack {
                  Text("Look speed")
                  Slider(value: $game.turnSpeed, in: 30...180, step: 15)
                  Text("\(Int(game.turnSpeed))°/s").monospacedDigit()
                }
                Toggle("Third-person camera", isOn: $game.thirdPerson)
                Toggle("Show voxel hands", isOn: $game.showHands)
                HStack { Text("Music"); Slider(value: $game.musicVolume, in: 0...1) }
                HStack { Text("World sounds"); Slider(value: $game.effectsVolume, in: 0...1) }
                DrawDistanceControl(game: game)
                NPCLifeSettings(game: game)
              }.padding(.top, 16)
            }
            if let error = game.errorMessage { Text(error).foregroundStyle(.orange) }
            Button {
              entering = true
              Task { @MainActor in
                await Task.yield()
                do { try game.prepare(); onEnter() }
                catch { game.report("Could not create the world: \(error.localizedDescription)") }
                entering = false
              }
            } label: {
              HStack {
                if entering { ProgressView() }
                Text(entering ? "Growing your world…" : "Enter your world")
                Spacer()
                Image(systemName: "arrow.right")
              }.padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).tint(.orange)
              .disabled(entering || !game.seedIsValid || game.isStopping)
            Text(game.status).font(.caption).foregroundStyle(.secondary)
          }.padding(30).frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
        }.background(.white.opacity(0.025))
      }
    }
    .background(Color(red: 0.045, green: 0.095, blue: 0.08).ignoresSafeArea())
    .task { game.input.start(); await game.restore() }
    .sheet(isPresented: $showControls) { ControlsView() }
  }
}
#endif
