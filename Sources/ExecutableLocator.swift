import Foundation

enum ExecutableLocator {
    static func find(named name: String, preferredPaths: [String]) -> URL? {
        let fileManager = FileManager.default
        for path in preferredPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for directory in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
            let path = String(directory) + "/" + name
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
