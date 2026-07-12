import Darwin
import Foundation
import ZwzCore

let dependencies = ZwzCLIDependencies.production()
exit(ZwzCLI.run(arguments: Array(CommandLine.arguments.dropFirst()), dependencies: dependencies))
