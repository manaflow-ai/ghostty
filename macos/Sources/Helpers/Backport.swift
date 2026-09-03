#if canImport(AppKit)
import AppKit

enum BackportNSGlassStyle {
    case regular, clear

    #if compiler(>=6.2)
    @available(macOS 26, *)
    var official: NSGlassEffectView.Style {
        switch self {
        case .regular: .regular
        case .clear: .clear
        }
    }
    #endif
}
#endif
