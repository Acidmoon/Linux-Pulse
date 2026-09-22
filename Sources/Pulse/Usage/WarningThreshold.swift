/// Where the ring turns red.
///
/// Moved out of `Panel/UsageTint.swift` for the Linux build: the tinting is drawn
/// by AppKit and excluded there, but which threshold the user picked is a stored
/// setting. The enum is the setting; the colour is the view's business.
/// Where the ring turns red.
///
/// A short list rather than a slider: this is the one step in the colour
/// language that means "pay attention", and a figure somebody nudged to 73 is
/// not a clearer signal than one they picked. Every option sits above
/// `UsageTint.cautionThreshold`, so moving this one never has to push the
/// yellow step out of its way.
enum WarningThreshold: Int, CaseIterable, Identifiable, Sendable {
    case sixty = 60
    case seventy = 70
    case seventyFive = 75
    case eighty = 80
    case eightyFive = 85
    case ninety = 90

    static let `default` = WarningThreshold.seventyFive

    var id: Int { rawValue }
    var fraction: Double { Double(rawValue) / 100 }

    /// Not run through `localized` — see `AlertThreshold.title` for why a bare
    /// percentage is not a sentence.
    var title: String { "\(rawValue)%" }
}
