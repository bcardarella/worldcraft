import SwiftUI

struct NPCLifeSettings: View {
  @Bindable var game: GameSession
  @State private var key = ""
  @State private var configuring = false
  @State private var reasoningKey = ""
  @State private var configuringReasoning = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Jev characters, wildlife and racers", isOn: $game.jevEnabled)
        .font(.system(size: 12))
      Text(game.jevKeyConfigured ? "TypeSafe key configured" : "Add your TypeSafe key to enable live decisions.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Button(game.jevKeyConfigured ? "Update TypeSafe key" : "Connect TypeSafe") { configuring = true }
        .font(.system(size: 11))
      Text("Jev chooses daily activities for people and animals, plus race pace, overtakes and yielding. Uses your TypeSafe account.")
        .font(.system(size: 10)).foregroundStyle(.secondary)
      Text(game.npcDecisionStatus).font(.system(size: 10)).foregroundStyle(.secondary)
      // This view also lives in a RealityView attachment. Immersive contexts
      // cannot present sheets; edit the key inside the existing settings panel.
      if configuring {
        VStack(alignment: .leading, spacing: 12) {
          Text("Connect Jev").font(.headline)
          Text("Keys entered here are saved in this device's Keychain, outside world saves and logs.")
            .font(.caption).foregroundStyle(.secondary)
          SecureField("TypeSafe API key", text: $key).textContentType(.password)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          if let message = game.jevConfigurationError { Text(message).foregroundStyle(.orange).font(.caption) }
          HStack {
            Button("Cancel") { key = ""; configuring = false }
            Spacer()
            Button("Save key") {
              if game.saveJevKey(key) { key = ""; configuring = false }
            }.buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          if game.jevHasSavedKey {
            Button("Remove saved key", role: .destructive) { game.removeJevKey(); key = ""; configuring = false }
          }
        }
        .padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
      }
      Divider().padding(.vertical, 4)
      Toggle("Reasoning for difficult decisions", isOn: $game.reasoningEnabled)
        .font(.system(size: 12))
      Text("Qwen3.5-Flash · $0.05/hour OpenRouter cap")
        .font(.system(size: 11))
      Text("Occasional plans help with damaged homes or unmet animal needs. Jev handles routine choices. Only bounded fictional world facts are sent; the cap is shared across planets and persists between launches. TypeSafe usage is separate.")
        .font(.system(size: 10)).foregroundStyle(.secondary)
      Text(game.reasoningStatus).font(.system(size: 10)).foregroundStyle(.secondary)
      Button(game.reasoningKeyConfigured ? "Update OpenRouter key" : "Connect OpenRouter") { configuringReasoning = true }
        .font(.system(size: 11))
      if configuringReasoning {
        VStack(alignment: .leading, spacing: 12) {
          Text("Connect OpenRouter").font(.headline)
          SecureField("OpenRouter API key", text: $reasoningKey).textContentType(.password)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          if let message = game.reasoningConfigurationError { Text(message).font(.caption).foregroundStyle(.orange) }
          HStack {
            Button("Cancel") { reasoningKey = ""; configuringReasoning = false }
            Spacer()
            Button("Save key") {
              if game.saveReasoningKey(reasoningKey) { reasoningKey = ""; configuringReasoning = false }
            }.buttonStyle(.borderedProminent).disabled(reasoningKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          if game.reasoningHasSavedKey {
            Button("Remove saved key", role: .destructive) {
              game.removeReasoningKey(); reasoningKey = ""; configuringReasoning = false
            }
          }
        }.padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
      }
    }
    .onDisappear { key = ""; configuring = false; reasoningKey = ""; configuringReasoning = false }
  }
}
