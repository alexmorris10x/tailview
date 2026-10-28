import Foundation

@main
struct WidgetRouteSmoke {
    static func main() {
        for route in WidgetRoute.allCases {
            precondition(WidgetRoute(url: route.url) == route, "Widget destination must round-trip")
        }
        let otherScheme = WidgetRoute.scheme == "tailview-dev" ? "tailview" : "tailview-dev"
        let invalid = [
            "\(otherScheme)://connect", "https://connect", "\(WidgetRoute.scheme)://unknown",
            "\(WidgetRoute.scheme)://connect/path", "\(WidgetRoute.scheme)://connect?mac=untrusted",
            "\(WidgetRoute.scheme)://connect#extra", "\(WidgetRoute.scheme)://name@connect",
            "\(WidgetRoute.scheme)://connect:123"
        ]
        for value in invalid {
            precondition(WidgetRoute(url: URL(string: value)!) == nil,
                         "Ignore links outside this app variant and known destinations")
        }
        print("PASS: \(WidgetRoute.scheme) widget links and rejected destinations")
    }
}
