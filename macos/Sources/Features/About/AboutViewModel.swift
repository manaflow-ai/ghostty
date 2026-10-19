import Foundation

@MainActor
final class AboutViewModel {
  var currentIcon: Ghostty.MacOSIcon? {
    didSet { onIconChange?(currentIcon) }
  }
  var isHovering = false
  var onIconChange: ((Ghostty.MacOSIcon?) -> Void)?

  private var cyclingTask: Task<Void, Never>?
  private let sleep: @Sendable (Duration) async throws -> Void

    private let icons: [Ghostty.MacOSIcon] = [
        .official,
        .blueprint,
        .chalkboard,
        .microchip,
        .glass,
        .holographic,
        .paper,
        .retro,
        .xray,
    ]

  init(
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await ContinuousClock().sleep(for: $0)
    }
  ) {
    self.sleep = sleep
  }

    func startCyclingIcons() {
    cyclingTask?.cancel()
    let sleep = sleep
    cyclingTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await sleep(.seconds(3))
        } catch {
          return
        }
        guard let self, !isHovering else { continue }
                advanceToNextIcon()
            }
    }
  }

    func stopCyclingIcons() {
    cyclingTask?.cancel()
    cyclingTask = nil
        currentIcon = nil
    }

    func advanceToNextIcon() {
        let currentIndex = currentIcon.flatMap(icons.firstIndex(of:)) ?? 0
    currentIcon = icons[icons.indexWrapping(after: currentIndex)]
    }
}
