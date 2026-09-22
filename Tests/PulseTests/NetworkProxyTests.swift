import Foundation
#if canImport(FoundationNetworking)
// URLSessionConfiguration lives here on Linux.
import FoundationNetworking
#endif
import Testing
@testable import Pulse

@Suite("Network proxy")
struct NetworkProxyTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PulseTests.networkProxy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("An upgrade keeps following the system")
    func defaultFollowsSystem() {
        withIsolatedDefaults { defaults in
            #expect(AppSettings.storedNetworkProxy(in: defaults) == .default)
            #expect(NetworkProxySettings.default.mode == .system)
            #expect(proxyCount(NetworkSession.configured(.ephemeral, for: .default)) == 0)
        }
    }

    @Test("Every offered manual proxy survives a round trip")
    func manualProxyRoundTrips() {
        withIsolatedDefaults { defaults in
            for kind in NetworkProxyKind.allCases {
                let settings = NetworkProxySettings(
                    mode: .manual,
                    kind: kind,
                    host: "127.0.0.1",
                    port: 7_897
                )
                AppSettings.storeNetworkProxy(settings, in: defaults)
                #expect(AppSettings.storedNetworkProxy(in: defaults) == settings)
                #expect(proxyCount(NetworkSession.configured(.ephemeral, for: settings)) == 1)
            }
        }
    }

    @Test("Unreadable storage falls back to the system")
    func unreadableStorageFallsBack() {
        withIsolatedDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: AppSettings.networkProxyDefaultsKey)
            #expect(AppSettings.storedNetworkProxy(in: defaults) == .default)
        }
    }

    @Test("Host and port validation refuses incomplete endpoints", arguments: [
        ("", "7897", false),
        ("   ", "7897", false),
        ("127.0.0.1", "0", false),
        ("127.0.0.1", "65536", false),
        ("127.0.0.1", "1.5", false),
        (" proxy.local ", " 443 ", true)
    ])
    func endpointValidation(host: String, port: String, valid: Bool) {
        let parsedHost = NetworkProxySettings.validHost(host)
        let parsedPort = NetworkProxySettings.validPort(port)
        #expect((parsedHost != nil && parsedPort != nil) == valid)
    }

    @Test("HTTP helpers receive only the chosen proxy")
    func httpProcessEnvironment() throws {
        let settings = NetworkProxySettings(mode: .manual, kind: .http, host: "proxy.local", port: 8_080)
        let environment = try #require(settings.processEnvironment(over: [
            "PATH": "/usr/bin",
            "ALL_PROXY": "socks5://old:1",
            "https_proxy": "http://old:2"
        ]))

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HTTP_PROXY"] == "http://proxy.local:8080")
        #expect(environment["HTTPS_PROXY"] == "http://proxy.local:8080")
        #expect(environment["ALL_PROXY"] == nil)
        #expect(environment["https_proxy"] == nil)
        #expect(environment["NO_PROXY"] == "localhost,127.0.0.1,::1")
    }

    @Test("SOCKS helpers receive ALL_PROXY and bracket an IPv6 host")
    func socksProcessEnvironment() throws {
        let settings = NetworkProxySettings(mode: .manual, kind: .socks5, host: "::1", port: 1_080)
        let environment = try #require(settings.processEnvironment(over: [
            "HTTP_PROXY": "http://old:1",
            "HTTPS_PROXY": "http://old:1"
        ]))

        #expect(environment["ALL_PROXY"] == "socks5://[::1]:1080")
        #expect(environment["HTTP_PROXY"] == nil)
        #expect(environment["HTTPS_PROXY"] == nil)
        #expect(environment["NO_PROXY"] == "localhost,127.0.0.1,::1")
    }

    @Test("Following the system does not replace a helper's environment")
    func systemProcessEnvironmentIsInherited() {
        #expect(NetworkProxySettings.default.processEnvironment(over: ["HTTPS_PROXY": "http://shell:9"]) == nil)
    }
}


/// Reads the proxy back out of a configuration without caring which spelling
/// the platform uses.
///
/// `NetworkProxy.configured` sets `proxyConfigurations` on Darwin and
/// `connectionProxyDictionary` on Linux, because Foundation there has neither
/// `ProxyConfiguration` nor `proxyConfigurations` — both were compiled to
/// confirm. The assertions that matter are the same either way: whether a
/// system-mode configuration carries a proxy at all, and whether a manual one
/// carries exactly the one that was asked for. Spelling that against
/// `proxyConfigurations` directly made the test Darwin-only for no reason.
///
/// Free functions rather than an extension: `URLSessionConfiguration` is an
/// `AnyObject` alias on Linux, and a non-nominal type cannot be extended.
private func proxyCount(_ configuration: URLSessionConfiguration) -> Int {
    #if canImport(FoundationNetworking)
    guard let dictionary = configuration.connectionProxyDictionary else { return 0 }
    // The Linux branch writes one enable key per kind, and libcurl reads
    // either HTTP or SOCKS — never both.
    let enabled = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable"]
        .filter { (dictionary[$0] as? Int) == 1 }
    return enabled.isEmpty ? 0 : 1
    #else
    return configuration.proxyConfigurations.count
    #endif
}
