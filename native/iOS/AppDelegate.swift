import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    static var ready: Task<Bool, Never>!
    static var libraryReady = false
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Self.ready = Task {
            let opened = await Task.detached(priority: .userInitiated) { Core.open() }.value
            guard opened else { AppLog.error("lifecycle", L("app.openFailed")); return false }
            finishOpening()
            Self.libraryReady = true
            return true
        }
        return true
    }

    @MainActor private func finishOpening() {
        LibraryPrefs.removeRetired()
        MemoryPressure.start()
        CrashWatch.shared.start()
        #if DEBUG
        DebugSeed.runIfRequested()
        if ProcessInfo.processInfo.environment["TL_RESET_UI_STATE"] != nil {
            SearchFields.saved = SearchFields()
            for k in ["filter.bad", "ai.prompt", "search.style", "search.fuzzy", "search.history", "grid.columns", "grid.level"] { UserDefaults.standard.removeObject(forKey: k) }
        }
        HitchMonitor.shared.startIfRequested()
        #endif
        Session.applyStoredCookies()
        AudioPolicy.observe()
        // GitHub builds: a newer release, at most once a day
        UpdateCheck.run { r in
            // the app's own window, not the lock in front of it: this is still there after unlocking
            UpdatePrompt.show(r, on: UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first?.window?.rootViewController)
        }
        // Under memory pressure: stop AI work and release the model (it restarts on the next library change).
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutoTagger.shared.stop() }
            Task { await AIEngine.shared.unloadAll() }
        }
        ModelStore.shared.configure()
        DispatchQueue.main.async {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TL_NO_TIMERS"] != nil { return }
            #endif
            ActivityCenter.shared.start()
            GridThumbnails.keepLibraryWarm { UIScreen.main.scale }   // grid thumbnails made ahead of time
            SyncService.shared.start()
            // Recycle bin: delete what stayed longer than the retention period.
            DispatchQueue.global(qos: .utility).async { if Core.expireTrash() > 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) } } }
            AutoTagger.shared.startIfEnabled()
            // photos / files shared from other apps: import as soon as a share completes
            ShareInbox.observe { ShareInbox.importPending() }
            ShareInbox.importPending()
        }
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Main", sessionRole: session.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// 下载帖子 on the app's icon: 浏览 with the quick download card. Waits for the feed when the app
    /// is only starting.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        QuickDownloadRequest.ask()
        completionHandler(shortcutItem.type == "downloadPosts")
    }

    /// The app lock: a window of its own in front of everything, presented sheets too.
    private var lockWindow: UIWindow?
    private let lockState = AppLockScreen.State()
    /// Asked since it locked. A cancelled prompt does not come back by itself (the button does it);
    /// the prompt itself makes the scene inactive and active again.
    private var lockAsked = false

    private func showLock(on scene: UIWindowScene) {
        lockAsked = false
        lockState.message = nil
        lockState.unavailable = false
        guard lockWindow == nil else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let screen = AppLockScreen(unlock: { [weak self] in self?.askToUnlock() }, openAnyway: { [weak self] in
            AppLock.enabled = false
            self?.hideLock()
        }, state: lockState)
        let host = UIHostingController(rootView: screen)
        host.view.backgroundColor = .systemBackground
        w.rootViewController = host
        w.makeKeyAndVisible()
        lockWindow = w
    }

    private func hideLock() {
        lockWindow?.isHidden = true
        lockWindow = nil
        window?.makeKey()
    }

    private func askToUnlock() {
        guard lockWindow != nil, !lockState.busy else { return }
        lockAsked = true
        lockState.busy = true
        lockState.message = nil
        AppLock.authenticate { [weak self] outcome in
            guard let self else { return }
            self.lockState.busy = false
            switch outcome {
            case .passed: self.hideLock()
            case .stayed(let reason): self.lockState.message = reason
            case .unavailable: self.lockState.unavailable = true
            }
        }
    }

    /// Before the system takes its picture for the app switcher: nothing of the library is in it,
    /// and coming back asks again.
    func sceneDidEnterBackground(_ scene: UIScene) {
        if AppLock.enabled, let scene = scene as? UIWindowScene { showLock(on: scene) }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let loading = UIViewController()
        loading.view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        loading.view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: loading.view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: loading.view.centerYAnchor)])
        spinner.startAnimating()
        window.rootViewController = loading
        window.makeKeyAndVisible()
        self.window = window
        if options.shortcutItem?.type == "downloadPosts" { QuickDownloadRequest.ask() }
        if AppLock.enabled { showLock(on: scene) }
        Task {
            guard await AppDelegate.ready.value else {
                spinner.stopAnimating()
                let alert = UIAlertController(title: L("app.openFailed"), message: L("app.openFailed.message"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                loading.present(alert, animated: true)
                return
            }
            // the phone layout or the sidebar layout, by the window's size (`AdaptiveRootViewController`)
            let root = AdaptiveRootViewController()
            window.rootViewController = root
            MascotPetView.install(in: root.view)
            #if DEBUG
            if ProcessInfo.processInfo.environment["TL_SIZE_TOUR"] != nil { root.debugSizeTour(scene) }
            if let log = ProcessInfo.processInfo.environment["TL_WINDOW_TOUR"] {
                root.debugWindowTour(scene, sizes: [CGSize(width: 1194, height: 834), CGSize(width: 1000, height: 760), CGSize(width: 760, height: 760), CGSize(width: 600, height: 800), CGSize(width: 400, height: 800)], log: log)
            }
            #endif
            if !options.urlContexts.isEmpty { self.scene(scene, openURLContexts: options.urlContexts) }
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if lockWindow != nil, !lockAsked { askToUnlock() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["TL_NO_TIMERS"] != nil { return }
        #endif
        if AppDelegate.libraryReady { ShareInbox.importPending() }
    }

    /// Handles .tlpack files opened from Files or AirDrop.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        Task {
            guard await AppDelegate.ready.value else { return }
            for ctx in contexts {
                let url = ctx.url
                let ext = url.pathExtension.lowercased()
                DispatchQueue.global(qos: .userInitiated).async {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let message: String
                    do {
                        guard ext == "tlpack" else { return }
                        let r = try Core.importPack(url)
                        message = L("app.imported", r.posts, r.media)
                    } catch { message = L("app.importFailed", error.localizedDescription) }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .libraryChanged, object: nil)
                        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                        var top = self.window?.rootViewController
                        while let p = top?.presentedViewController { top = p }
                        top?.present(a, animated: true)
                    }
                }
            }
        }
    }
}

#if DEBUG
/// Development helper: TL_IMPORT_DIR imports a legacy folder tree; TL_DEMO_TAGS adds sample AI/user tags.
enum DebugSeed {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["TL_IMPORT_DIR"] {
            do { let r = try Core.importLegacyDirectory(URL(fileURLWithPath: dir)); NSLog("import: %d posts, %d media, %d skipped", r.posts, r.media, r.skipped.count) }
            catch { NSLog("import failed: %@", "\(error)") }
        }
        if env["TL_RESET_UI_STATE"] != nil {
            // UI tests start from the full sample: bring back anything an earlier test binned.
            let binned = Core.trashList().map(\.mediaId)
            if !binned.isEmpty { _ = try? Core.restore(binned) }
            for f in Core.folders() { try? Core.deleteFolder(f.name) }
        }
        // two local external models, for looking at the pages and sheets that list models
        if env["TL_SEED_EXTERNAL"] != nil {
            for n in ["本地 Ollama", "本地 LM Studio"] {
                var m = ExternalModel.new(); m.name = n; m.url = "http://127.0.0.1:11434"; ExternalModels.save(m)
            }
        }
        if env["TL_DEMO_TAGS"] != nil, let items = try? Core.feed(FeedRequest(seed: 7)) {
            let models = ["EZCon--Huihui-Qwen3-VL-2B-Instruct-abliterated-4bit-mlx", "alexgusevski--Huihui-Qwen3-VL-8B-Instruct-abliterated-q4-mlx"]
            let ai = ["墙", "白墙", "猫", "天空", "城市夜景", "人像", "风景", "蓝色"]
            for (i, it) in items.enumerated() {
                try? Core.aiApply(mediaId: it.mediaId, model: models[i % 2], labels: [ai[i % ai.count], ai[(i * 3 + 1) % ai.count]])
                if i % 3 == 0 { try? Core.addTag("收藏", to: it.mediaId) }
            }
        }
    }
}
#endif
