import Foundation

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--bench") {
    runBench()
    exit(0)
}

let mode: RunMode = arguments.contains("--latency") ? .latency
                  : arguments.contains("--flood") ? .flood
                  : .interactive
runApp(mode: mode)
