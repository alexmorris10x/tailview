import Foundation

@main
struct ModifierSmoke {
    static func main() {
        var selection = ModifierSelection()
        selection.tap(.command, at: 10)
        precondition(selection.mode(for: .command) == .next)
        precondition(selection.active == [.command])
        selection.consumeNext()
        precondition(selection.active == nil)

        selection.tap(.control, at: 20)
        selection.tap(.control, at: 20.2)
        precondition(selection.mode(for: .control) == .held)
        selection.tap(.option, at: 21)
        precondition(selection.active == [.control, .option])
        selection.consumeNext()
        precondition(selection.active == [.control])
        selection.tap(.control, at: 22)
        precondition(selection.active == nil)

        selection.tap(.command, at: 30)
        selection.tap(.command, at: 31)
        precondition(selection.active == nil)
        selection.hold(.option)
        precondition(selection.mode(for: .option) == .held)
        selection.reset()
        precondition(selection.active == nil)
        print("Modifier smoke passed: next action, double-tap hold, combination, release, reset")
    }
}
