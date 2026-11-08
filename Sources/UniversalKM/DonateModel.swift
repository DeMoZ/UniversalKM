import AppKit
import UniversalKMCore

/// Ways to donate for the panel's donate section, downloaded from the `DeMoZ/donations` repository
/// each time the section opens, so links and texts change without a release. The last copy shows
/// while (or if) the download fails (design D18).
@MainActor
final class DonateModel: ObservableObject {
    @Published private(set) var info: DonationInfo? = Donations.cached()
    @Published private(set) var isLoading = false

    /// The language the interface is shown in first, then the system's, so the texts match the panel.
    var languages: [String] { Bundle.main.preferredLocalizations + Locale.preferredLanguages }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            if let fresh = await Donations.download() { info = fresh }
            isLoading = false
        }
    }

    func open(_ method: DonationMethod) {
        NSWorkspace.shared.open(method.url)
    }
}
