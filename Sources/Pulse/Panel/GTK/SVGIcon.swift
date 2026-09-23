#if !canImport(AppKit)
import Foundation

/// A provider's bundled mark, parsed once and kept.
///
/// **The Linux half of `LobeIconStore`.** That one asks `NSImage` to render the
/// SVG and marks the result as a template, so only its alpha matters and the
/// rail tints it. There is nothing to ask here, so the geometry is parsed into
/// the same `PathCommand` list the rest of the panel draws with, and the
/// template behaviour is simply what happens: one fill, one colour.
///
/// Two things were measured before this was written:
///
///   - **Every one of the 34 icons declares `fill-rule="evenodd"`**, and most of
///     them draw a hole with it. Drawn under the nonzero rule they are solid
///     blobs.
///   - **One file uses a `clipPath`** (`openclaw.svg`), and its clip is
///     `M0 0h24v24H0z` — the whole viewBox, which is to say no clipping at all.
///     So clipping is not implemented, and the reason is a measurement rather
///     than an omission. A future icon that really clips would need it, and this
///     comment is where that would be found out.
enum SVGIcon {
    struct Icon {
        let commands: [PathCommand]
        /// Almost always `0 0 24 24`, and read rather than assumed so that a
        /// differently-proportioned icon lands correctly.
        let viewBox: CGRect
        let evenOdd: Bool
    }

    /// Guarded by `@MainActor` on the only thing that touches it.
    @MainActor
    private static var cache: [String: Icon] = [:]

    /// Nil when the resource is missing or has no drawable path — which the
    /// caller shows as a question mark, the way `LobeIconView` does.
    ///
    /// `@MainActor` because the cache is: the rail draws on the main thread, and
    /// a lock around a dictionary read thirty times a second is a cost with no
    /// argument behind it.
    @MainActor
    static func icon(named name: String) -> Icon? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let icon = parse(text)
        cache[name] = icon
        return icon
    }

    /// Reads the attributes this needs out of the file.
    ///
    /// Not an XML parser: these are generated files with one shape in them, and
    /// the alternative is a dependency for six regular expressions' worth of
    /// reading. Everything else in them — the gradients, the `<title>`, the
    /// style attribute — is discarded, because a template render keeps only the
    /// outline.
    static func parse(_ text: String) -> Icon? {
        var commands: [PathCommand] = []
        for data in attribute("d", in: text) {
            commands.append(contentsOf: SVGPathData.parse(data))
        }
        guard !commands.isEmpty else { return nil }
        return Icon(commands: commands,
                    viewBox: viewBox(in: text) ?? CGRect(x: 0, y: 0, width: 24, height: 24),
                    evenOdd: text.contains("fill-rule=\"evenodd\""))
    }

    /// Every value of `name="..."` in the text.
    static func attribute(_ name: String, in text: String) -> [String] {
        var values: [String] = []
        let needle = Array("\(name)=\"")
        let characters = Array(text)
        var index = 0
        while index + needle.count < characters.count {
            guard Array(characters[index..<(index + needle.count)]) == needle else {
                index += 1
                continue
            }
            index += needle.count
            let start = index
            while index < characters.count, characters[index] != "\"" { index += 1 }
            values.append(String(characters[start..<index]))
            index += 1
        }
        return values
    }

    private static func viewBox(in text: String) -> CGRect? {
        guard let value = attribute("viewBox", in: text).first else { return nil }
        let numbers = value.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}
#endif
