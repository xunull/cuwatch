import Foundation

/// Which Minimax API host to talk to.
///
/// **Domain note (2026-06-21 correction):** the official Minimax developer
/// brand uses the domain `minimaxi.com` (note the trailing `i`), NOT
/// `minimax.com` / `minimax.io` (those are marketing surfaces). API hosts:
///   - Global:           https://api.minimaxi.com
///   - Mainland China:   https://api.minimaxi.cn
///
/// Per plan premise #5: `.global` ships as the v1 default since the wedge
/// audience is English Show HN. Users in mainland China can switch to
/// `.china` via Preferences to use the local mirror.
///
/// The old code shipped `https://www.minimax.io` (marketing site, no API)
/// and `https://www.minimax.cn` (dead host); both have been corrected.
public enum MinimaxEndpoint: String, CaseIterable, Equatable, Sendable, Codable {
    case global
    case china

    public var baseURL: URL {
        switch self {
        case .global: return URL(string: "https://api.minimaxi.com")!
        case .china:  return URL(string: "https://api.minimaxi.cn")!
        }
    }

    /// Display label used in Preferences > Services > Minimax > Endpoint toggle.
    public var displayName: String {
        switch self {
        case .global: return "minimaxi.com"
        case .china:  return "minimaxi.cn"
        }
    }

    public static let `default`: MinimaxEndpoint = .global
}
