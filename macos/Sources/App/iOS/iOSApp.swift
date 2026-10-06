import Combine
import GhosttyKit
import UIKit

@main
final class GhosttyIOSAppDelegate: UIResponder, UIApplicationDelegate {
    let ghostty: Ghostty.App

    override init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            preconditionFailure("Initialize ghostty backend failed")
        }
        ghostty = Ghostty.App()
        super.init()
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = GhosttyIOSSceneDelegate.self
        return configuration
    }
}

@MainActor
final class GhosttyIOSSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard
            let windowScene = scene as? UIWindowScene,
            let appDelegate = UIApplication.shared.delegate as? GhosttyIOSAppDelegate
        else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = GhosttyTerminalViewController(ghostty: appDelegate.ghostty)
        window.makeKeyAndVisible()
        self.window = window
    }
}

@MainActor
private final class GhosttyTerminalViewController: UIViewController {
    private let ghostty: Ghostty.App
    private var surfaceView: Ghostty.SurfaceView?
    private var stateView: UIStackView?
    private var cancellables: Set<AnyCancellable> = []

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ghostty.$readiness
            .removeDuplicates()
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        ghostty.$config
            .sink { [weak self] config in self?.view.backgroundColor = config.backgroundColor }
            .store(in: &cancellables)
        render()
    }

    private func render() {
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        stateView?.removeFromSuperview()
        stateView = nil
        view.backgroundColor = ghostty.config.backgroundColor

        guard ghostty.readiness == .ready, let app = ghostty.app else {
            let image = UIImageView(image: UIImage(named: "AppIconImage"))
            image.contentMode = .scaleAspectFit
            image.heightAnchor.constraint(lessThanOrEqualToConstant: 96).isActive = true
            let title = UILabel()
            title.text = "Ghostty"
            title.textAlignment = .center
            let state = UILabel()
            state.text = String(localized: "State: \(ghostty.readiness.rawValue)")
            state.textAlignment = .center
            let stack = UIStackView(arrangedSubviews: [image, title, state])
            stack.axis = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            ])
            stateView = stack
            return
        }

        let surface = Ghostty.SurfaceView(app)
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        surfaceView = surface
    }
}
