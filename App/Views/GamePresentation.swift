import SwiftUI

enum GamePresentation {
  static var controlsIntroduction: String {
    #if os(visionOS)
    "Look and aim with your headset. Every game action uses your keyboard, mouse or gamepad."
    #else
    "Look and aim with the right stick or mouse. Play with a gamepad or keyboard and mouse. Menus also support touch."
    #endif
  }
  static var recenterLabel: String {
    #if os(visionOS)
    "Recenter view · C / R3"
    #else
    "Level camera · C / R3"
    #endif
  }
}

extension View {
  @ViewBuilder func gamePanelBackground() -> some View {
    #if os(visionOS)
    glassBackgroundEffect()
    #else
    background(Color(red: 0.055, green: 0.095, blue: 0.085).opacity(0.97),
      in: .rect(cornerRadius: 24))
      .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.15)))
      .shadow(color: .black.opacity(0.4), radius: 24)
    #endif
  }
}
