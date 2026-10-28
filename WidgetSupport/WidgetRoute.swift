import Foundation

/// Widget links carry only a destination. Pairing credentials stay in the app.
enum WidgetRoute: String, CaseIterable {
    case connect, keyboard, settings

    static var scheme: String {
        #if DEBUG
        "tailview-dev"
        #else
        "tailview"
        #endif
    }

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              let host = url.host else { return nil }
        self.init(rawValue: host)
    }
}
