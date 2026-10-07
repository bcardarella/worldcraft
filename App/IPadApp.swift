#if os(iOS)
import GameController
import SwiftUI
import UIKit

@main
@MainActor final class IPadApp: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
    configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Worldcraft", sessionRole: session.role)
    configuration.delegateClass = IPadSceneDelegate.self
    return configuration
  }
}

@MainActor final class IPadSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var game: GameSession?
  private var checkpoint: Task<Void, Never>?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let game = GameSession()
    self.game = game
    let window = UIWindow(windowScene: scene)
    window.rootViewController = IPadGameController(game: game)
    self.window = window
    window.makeKeyAndVisible()
  }

  func sceneWillResignActive(_ scene: UIScene) {
    game?.sceneActivityChanged(isActive: false)
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func sceneDidBecomeActive(_ scene: UIScene) { game?.sceneActivityChanged(isActive: true) }
  func sceneDidEnterBackground(_ scene: UIScene) {
    guard let game, game.isImmersed, checkpoint == nil else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Worldcraft") { [weak self] in
      Task { @MainActor in
        self?.checkpoint?.cancel()
        // Keep the cancelled checkpoint registered until it drains. A second
        // background transition must not let an old task finish a newer one.
        self?.endBackgroundTime()
      }
    }
    checkpoint = Task { [weak self] in
      await game.saveCheckpoint()
      self?.finishCheckpoint()
    }
  }
  private func finishCheckpoint() {
    checkpoint = nil
    endBackgroundTime()
  }
  private func endBackgroundTime() {
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }
  func sceneDidDisconnect(_ scene: UIScene) {
    guard let game else { return }
    Task { await game.saveAndStop() }
  }
}

/// Route gamepad events at the UIKit root, before a focused SwiftUI button can
/// consume A as an activation as well as GameInput consuming it as a jump.
/// Pointer lock is independent: inventory releases the mouse, but its gamepad
/// navigation still belongs to GameInput rather than UIKit's focus system.
@MainActor private final class IPadGameController: GCEventViewController {
  private let contentController: UIHostingController<IPadRootView>
  private var capturePointer = false
  init(game: GameSession) {
    contentController = UIHostingController(rootView: IPadRootView(game: game))
    super.init(nibName: nil, bundle: nil)
    controllerUserInteractionEnabled = true // The lobby uses ordinary UI navigation.
    contentController.rootView.gameControllerCaptureChanged = { [weak self] capture in
      guard let self, self.controllerUserInteractionEnabled != !capture else { return }
      self.controllerUserInteractionEnabled = !capture
      // A held lobby/menu selection must not become a fresh gameplay action.
      game.input.reset()
    }
    contentController.rootView.pointerCaptureChanged = { [weak self] capture in
      guard let self, self.capturePointer != capture else { return }
      self.capturePointer = capture
      self.setNeedsUpdateOfPrefersPointerLocked()
      self.setNeedsUpdateOfHomeIndicatorAutoHidden()
      self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
      UIApplication.shared.isIdleTimerDisabled = capture
    }
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(game:)") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    addChild(contentController)
    let contentView = contentController.view!
    contentView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(contentView)
    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: view.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    contentController.didMove(toParent: self)
  }

  override var preferredFocusEnvironments: [UIFocusEnvironment] { [contentController] }
  override var prefersPointerLocked: Bool { capturePointer }
  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { capturePointer }
  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { capturePointer ? .all : [] }
}
#endif
