import Foundation
#if canImport(FoundationNetworking)
// On Linux, URLSession and friends live in this separate module. On
// Darwin it does not exist and Foundation already re-exports them, so
// the guard keeps macOS exactly as it was.
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
#if canImport(os)
import os       // unused today; kept so a Darwin-only
#endif          // logger can be added without a platform check

enum NetworkProxyMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .system: .localized("Follow System")
        case .manual: .localized("Manual")
        }
    }
}

enum NetworkProxyKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case http
    case socks5

    var id: Self { self }

    var title: String {
        switch self {
        case .http: .localized("HTTP")
        case .socks5: .localized("SOCKS5")
        }
    }
}

/// The proxy Pulse applies to its own requests and supported helper processes.
struct NetworkProxySettings: Codable, Equatable, Sendable {
    var mode: NetworkProxyMode
    var kind: NetworkProxyKind
    var host: String
    var port: Int?

    static let `default` = NetworkProxySettings(mode: .system, kind: .http, host: "", port: nil)

    var endpoint: (host: String, port: UInt16)? {
        guard mode == .manual,
              let host = Self.validHost(host),
              let port,
              (1...65_535).contains(port)
        else { return nil }
        return (host, UInt16(port))
    }

    static func validHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }

    static func validPort(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(text), (1...65_535).contains(port) else { return nil }
        return port
    }

    /// A complete environment rather than only the added keys, because setting
    /// `Process.environment` replaces what the child would otherwise inherit.
    func processEnvironment(over base: [String: String]) -> [String: String]? {
        guard let endpoint else { return nil }

        var environment = base
        for key in [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy"
        ] {
            environment.removeValue(forKey: key)
        }

        let host = endpoint.host.contains(":") && !endpoint.host.hasPrefix("[")
            ? "[\(endpoint.host)]"
            : endpoint.host
        switch kind {
        case .http:
            let proxy = "http://\(host):\(endpoint.port)"
            environment["HTTP_PROXY"] = proxy
            environment["HTTPS_PROXY"] = proxy
        case .socks5:
            environment["ALL_PROXY"] = "socks5://\(host):\(endpoint.port)"
        }
        environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
        return environment
    }
}

/// Owns the session configuration for every non-loopback HTTP request Pulse
/// makes. Antigravity deliberately keeps its local language-server session.
enum NetworkSession {
    private struct State {
        var settings = NetworkProxySettings.default
        var session = URLSession(configuration: .default)
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var shared: URLSession {
        state.withLock { $0.session }
    }

    static func apply(_ settings: NetworkProxySettings) {
        let configuration = configured(.default, for: settings)
        let replacement = URLSession(configuration: configuration)
        let (changed, previous) = state.withLock { state in
            guard state.settings != settings else { return (false, state.session) }
            let previous = state.session
            state.settings = settings
            state.session = replacement
            return (true, previous)
        }

        if changed {
            previous.invalidateAndCancel()
        } else {
            replacement.invalidateAndCancel()
        }
    }

    /// Adds the current proxy to a caller's cookie/cache/timeout choices.
    static func configured(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configured(configuration, for: state.withLock { $0.settings })
    }

    static func subprocessEnvironment() -> [String: String]? {
        state.withLock { $0.settings }.processEnvironment(over: ProcessInfo.processInfo.environment)
    }

    // Internal so `NetworkProxyTests` can prove the system/manual boundary
    // without making a real network request.
    static func configured(
        _ configuration: URLSessionConfiguration,
        for settings: NetworkProxySettings
    ) -> URLSessionConfiguration {
        guard let endpoint = settings.endpoint else { return configuration }

        #if canImport(Network)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return configuration }

        let target = NWEndpoint.hostPort(host: NWEndpoint.Host(endpoint.host), port: port)
        switch settings.kind {
        case .http:
            configuration.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: target)]
        case .socks5:
            configuration.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: target)]
        }
        #else
        // Foundation on Linux has no `ProxyConfiguration` and no
        // `proxyConfigurations` — verified by compiling both, not assumed. The
        // older dictionary form is what swift-corelibs-foundation's libcurl
        // backend reads, so the same settings are expressed as
        // `connectionProxyDictionary` here.
        //
        // The keys are the CFNetwork spellings written out as strings rather
        // than as the `kCFNetworkProxies*` constants: those constants are not
        // declared on Linux, and the backend parses the strings.
        //
        // `HTTPEnable` is set alongside the HTTPS pair because libcurl will
        // not proxy a plain-HTTP request from an HTTPS-only dictionary, and a
        // provider endpoint reached over http:// would then silently bypass
        // the proxy the user asked for — a quieter failure than a refused
        // connection.
        switch settings.kind {
        case .http:
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": endpoint.host,
                "HTTPPort": Int(endpoint.port),
                "HTTPSEnable": 1,
                "HTTPSProxy": endpoint.host,
                "HTTPSPort": Int(endpoint.port),
            ]
        case .socks5:
            configuration.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy": endpoint.host,
                "SOCKSPort": Int(endpoint.port),
            ]
        }
        #endif
        return configuration
    }
}
