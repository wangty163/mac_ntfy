//
//  ProxyConfig.swift
//  NtfyMac
//
//  Explicit proxy control for all ntfy traffic. URLSession's default behavior
//  is to auto-detect the macOS system proxy, which breaks the long-lived
//  notification stream when a tool like Clash/Surge manages the system proxy:
//  the stream is forced through the local proxy (even for hosts the proxy
//  would route DIRECT) where it can stall, buffer or lose local DNS overrides.
//  Instead of trusting auto-detection, the user picks one of three modes:
//  bypass the system proxy entirely (default), follow it, or use an explicit
//  HTTP/SOCKS5 proxy that is known to handle streaming.
//

import Foundation
import CFNetwork

enum ProxyMode: String, CaseIterable, Identifiable {
    case direct
    case system
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .direct: return "Direct (ignore system proxy)"
        case .system: return "System proxy"
        case .custom: return "Custom proxy"
        }
    }
}

enum ProxyType: String, CaseIterable, Identifiable {
    case http
    case socks5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: return "HTTP (CONNECT)"
        case .socks5: return "SOCKS5"
        }
    }
}

struct ProxyConfig {
    var mode: ProxyMode
    var type: ProxyType
    var host: String
    var port: Int

    enum Keys {
        static let mode = "proxyMode"
        static let type = "proxyType"
        static let host = "proxyHost"
        static let port = "proxyPort"
    }

    static let registrationDefaults: [String: Any] = [
        Keys.mode: ProxyMode.direct.rawValue,
        Keys.type: ProxyType.http.rawValue,
        Keys.host: "127.0.0.1",
        Keys.port: 7890,
    ]

    /// UserDefaults is thread-safe, so each connection attempt can read the
    /// current proxy settings just before connecting, without plumbing the
    /// main-actor AppSettings object through to every session factory.
    static func current(defaults: UserDefaults = .standard) -> ProxyConfig {
        ProxyConfig(
            mode: ProxyMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .direct,
            type: ProxyType(rawValue: defaults.string(forKey: Keys.type) ?? "") ?? .http,
            host: defaults.string(forKey: Keys.host) ?? "127.0.0.1",
            port: defaults.integer(forKey: Keys.port)
        )
    }

    func apply(to config: URLSessionConfiguration) {
        switch mode {
        case .system:
            // Leave URLSession's default system-proxy auto-detection in place.
            break
        case .direct:
            // An empty proxy dictionary disables proxying outright; nil would
            // mean "fall back to the system settings".
            config.connectionProxyDictionary = [:]
        case .custom:
            let host = host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, (1...65535).contains(port) else {
                config.connectionProxyDictionary = [:]
                return
            }
            switch type {
            case .http:
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1,
                    kCFNetworkProxiesHTTPProxy as String: host,
                    kCFNetworkProxiesHTTPPort as String: port,
                    kCFNetworkProxiesHTTPSEnable as String: 1,
                    kCFNetworkProxiesHTTPSProxy as String: host,
                    kCFNetworkProxiesHTTPSPort as String: port,
                ]
            case .socks5:
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesSOCKSEnable as String: 1,
                    kCFNetworkProxiesSOCKSProxy as String: host,
                    kCFNetworkProxiesSOCKSPort as String: port,
                ]
            }
        }
    }

    /// One-shot session for publish/test requests, honoring the proxy mode.
    /// Callers should invalidate it when done to avoid leaking sessions.
    static func makeEphemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        current().apply(to: config)
        return URLSession(configuration: config)
    }
}

extension Notification.Name {
    /// Posted by AppSettings whenever any proxy setting changes, so open
    /// connections can be restarted with the new configuration.
    static let ntfyProxyConfigChanged = Notification.Name("ntfyProxyConfigChanged")
}
