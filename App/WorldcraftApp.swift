import SwiftUI

#if os(visionOS)
@main
struct WorldcraftApp: App {
  @State private var game = GameSession()

  var body: some Scene {
    WindowGroup(id: "lobby") {
      LobbyView(game: game)
    }
    .defaultSize(width: 1000, height: 700)
    .windowResizability(.contentSize)

    ImmersiveSpace(id: "world") {
      ImmersiveWorldView(game: game)
    }
    .immersionStyle(selection: .constant(.full), in: .full)
    .upperLimbVisibility(.hidden)
  }
}
#endif
