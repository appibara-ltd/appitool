import ArgumentParser
import Foundation

struct FlowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flow",
        abstract: "Executes the automated 7-stage release flow pipeline.",
        subcommands: [
            FlowIOSCommand.self,
            FlowAndroidCommand.self,
        ]
    )
}
