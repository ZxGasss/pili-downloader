import Foundation

/// Compile once against the archived pre-2.0 model and once against the current model.
@main struct UpgradeCompatibility {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let records = try TaskHistory.read(from: input)
        precondition(!records.isEmpty)
        let ids = records.map(\.id)
        precondition(Set(ids).count == ids.count)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try JSONEncoder().encode(records).write(to: output, options: .atomic)
        let decoded = try TaskHistory.read(from: output)
        precondition(decoded.map(\.id) == ids)
        precondition(decoded.map { $0.completed.count } == records.map { $0.completed.count })
        print("UPGRADE_JSON_PASS records=\(records.count) relationships=\(records.filter { $0.parentID != nil }.count)")
    }
}
