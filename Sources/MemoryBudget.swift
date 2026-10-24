import Foundation

enum MemoryBudget {
    static func isSmallMachine(bytes: UInt64) -> Bool { bytes <= 9 * 1024 * 1024 * 1024 }
    static var lowMemory: Bool {
        if Bundle.main.bundleIdentifier?.contains(".preview") == true,
           Bundle.main.object(forInfoDictionaryKey: "PiliLowMemoryMode") as? Bool == true { return true }
        return isSmallMachine(bytes: ProcessInfo.processInfo.physicalMemory)
    }
    static var episodes: Int { lowMemory ? 2 : 4 }
    static var connections: Int { lowMemory ? 4 : 8 }
    static let imageBytes = 6 * 1024 * 1024
    static let decodedBytes = 12 * 1024 * 1024
    static let encodedBytes = 8 * 1024 * 1024
}

