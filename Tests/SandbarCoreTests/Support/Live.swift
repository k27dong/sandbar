import Foundation

enum Live {
    static let isOn = ProcessInfo.processInfo.environment["SANDBAR_LIVE"] == "1"

    static func program(_ variable: String) -> URL {
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            preconditionFailure("\(variable) is not set; real runs go through swiftbox-live.sh")
        }
        return URL(filePath: path)
    }
}
