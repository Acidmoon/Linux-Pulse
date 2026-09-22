/// Which settings pane is showing.
///
/// Moved out of `Settings/SettingsView.swift` for the Linux build. The view is
/// excluded there, but `SettingsNavigation` — which is not, and which `pulse://`
/// links drive — is what owns the selection.
enum SettingsPane: Hashable {
    case general
    case account(AccountKey)
    /// Every agent's spending added up — a pane whose subject is not a
    /// provider, which is why it sits outside the accounts rather than inside
    /// one of them.
    case spend
    case about
    case integrations

    var title: String {
        switch self {
        case .general: .localized("General")
        // Not "Usage history", which is what a provider's own card is called.
        // Two panes with one name is two places to look for one thing.
        case .spend: .localized("Token spend")
        // Brand names, left as they are in every language.
        // A fallback: the view titles these from the account's own label.
        case .account(let account): account.provider.displayName
        case .about: .localized("About")
        case .integrations: .localized("Developer integrations")
        }
    }

    /// Only meaningful for the panes drawn with an SF Symbol; provider panes
    /// use the provider's own mark instead.
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .spend: "chart.bar"
        case .account: "square.stack.3d.up"
        case .about: "info.circle"
        case .integrations: "terminal"
        }
    }
}
