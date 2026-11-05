import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// The app lock: Flutter stops drawing on its way to the background, so this is what keeps the
  /// library out of the picture the system takes for the app switcher.
  private var cover: UIView?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIScene.didActivateNotification, object: nil)
  }

  @objc private func enteredBackground() {
    guard UserDefaults.standard.bool(forKey: "flutter.appLock.enabled"), cover == nil, let window else { return }
    let view = UIView(frame: window.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .systemBackground
    window.addSubview(view)
    cover = view
  }

  @objc private func becameActive() {
    cover?.removeFromSuperview()
    cover = nil
  }
}
