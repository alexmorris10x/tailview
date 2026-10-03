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

        selection.tap(.command, at: 40)
        selection.tap(.function, at: 41)
        precondition(selection.active == [.function, .command])
        let command = ControlCommand(kind: .key, key: .delete, modifiers: selection.active)
        precondition(ControlCommand.decode(command.encoded()!) == command)

        precondition(FunctionKeys.keyCode(for: .delete, function: false) == 51)
        precondition(FunctionKeys.keyCode(for: .delete, function: true) == 117)
        precondition(FunctionKeys.keyCode(for: .left, function: true) == 115)
        precondition(FunctionKeys.keyCode(for: .right, function: true) == 119)
        precondition(FunctionKeys.keyCode(for: .up, function: true) == 116)
        precondition(FunctionKeys.keyCode(for: .down, function: true) == 121)
        precondition(FunctionKeys.keyCode(for: .left, function: false) == 123)
        precondition(FunctionKeys.keyCode(for: .returnKey, function: true) == 36)
        precondition(FunctionKeys.functionKeyCode(for: "1") == 122)
        precondition(FunctionKeys.functionKeyCode(for: "0") == 109)
        precondition(FunctionKeys.functionKeyCode(for: "=") == 111)
        precondition(FunctionKeys.functionKeyCode(for: "e") == nil)
        print("Modifier smoke passed: next action, double-tap hold, combination, release, reset, Fn layer")
    }
}
