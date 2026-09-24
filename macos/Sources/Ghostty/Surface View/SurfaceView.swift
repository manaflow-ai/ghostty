import Foundation
import GhosttyKit
import System

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Ghostty {
    /// Configuration for creating a terminal surface.
    struct SurfaceConfiguration {
        var fontSize: Float32?

        var workingDirectory: String? {
            get { normalizedWorkingDirectory }
            set { normalizedWorkingDirectory = newValue.map { FilePath($0).string } }
        }
        private var normalizedWorkingDirectory: String?

        var command: String?
        var environmentVariables: [String: String] = [:]
        var initialInput: String?
        var waitAfterCommand = false
        var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

        init() {}

        init(from config: ghostty_surface_config_s) {
            fontSize = config.font_size
            if let workingDirectory = config.working_directory {
                self.workingDirectory = String(cString: workingDirectory, encoding: .utf8)
            }
            if let command = config.command {
                self.command = String(cString: command, encoding: .utf8)
            }
            if config.env_var_count > 0, let environment = config.env_vars {
                for index in 0..<config.env_var_count {
                    let variable = environment[index]
                    if
                        let key = String(cString: variable.key, encoding: .utf8),
                        let value = String(cString: variable.value, encoding: .utf8)
                    {
                        environmentVariables[key] = value
                    }
                }
            }
            context = config.context
        }

        /// Provides a C-compatible configuration whose pointers remain valid
        /// for the duration of `body`.
        func withCValue<T>(
            view: SurfaceView,
            _ body: (inout ghostty_surface_config_s) throws -> T
        ) rethrows -> T {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
#if os(macOS)
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            config.scale_factor = NSScreen.main!.backingScaleFactor
#elseif os(iOS)
            config.platform_tag = GHOSTTY_PLATFORM_IOS
            config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(view).toOpaque()
            ))
            // The surface updates this value from its window-backed display
            // after attachment.
            config.scale_factor = UIScreen.main.scale
#else
#error("unsupported target")
#endif

            config.font_size = fontSize ?? 0
            config.wait_after_command = waitAfterCommand
            config.context = context

            return try workingDirectory.withCString { workingDirectory in
                config.working_directory = workingDirectory
                return try command.withCString { command in
                    config.command = command
                    return try initialInput.withCString { initialInput in
                        config.initial_input = initialInput
                        let keys = Array(environmentVariables.keys)
                        let values = Array(environmentVariables.values)
                        return try keys.withCStrings { keyStrings in
                            try values.withCStrings { valueStrings in
                                var environment = [ghostty_env_var_s]()
                                environment.reserveCapacity(environmentVariables.count)
                                for index in 0..<environmentVariables.count {
                                    environment.append(ghostty_env_var_s(
                                        key: keyStrings[index],
                                        value: valueStrings[index]
                                    ))
                                }
                                return try environment.withUnsafeMutableBufferPointer { buffer in
                                    config.env_vars = buffer.baseAddress
                                    config.env_var_count = environmentVariables.count
                                    return try body(&config)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

#if canImport(AppKit)
extension Ghostty {
    /// Focuses immediately when attached, or records one pending request that
    /// is fulfilled by `SurfaceView.viewDidMoveToWindow`.
    @MainActor
    static func moveFocus(to: SurfaceView, from: SurfaceView? = nil) {
        SurfaceFocusCoordinator.requestFocus(to: to, from: from)
    }
}

@MainActor
enum SurfaceFocusCoordinator {
    private final class Request {
        weak var target: Ghostty.SurfaceView?
        weak var previous: Ghostty.SurfaceView?

        init(target: Ghostty.SurfaceView, previous: Ghostty.SurfaceView?) {
            self.target = target
            self.previous = previous
        }
    }

    private static var pending: [ObjectIdentifier: Request] = [:]

    static func requestFocus(to target: Ghostty.SurfaceView, from previous: Ghostty.SurfaceView?) {
        let id = ObjectIdentifier(target)
        guard let window = target.window else {
            pending[id] = Request(target: target, previous: previous)
            return
        }
        pending[id] = nil
        if let previous, previous !== target { _ = previous.resignFirstResponder() }
        window.makeFirstResponder(target)
    }

    static func surfaceDidMoveToWindow(_ surface: Ghostty.SurfaceView) {
        let id = ObjectIdentifier(surface)
        guard
            surface.window != nil,
            let request = pending.removeValue(forKey: id),
            let target = request.target
        else { return }
        requestFocus(to: target, from: request.previous)
    }
}
#endif
