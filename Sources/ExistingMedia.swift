import Foundation

enum ExistingMedia {
    private static let extensions: Set<String> = ["mp4", "mkv", "webm", "m4v", "mov", "flv", "ts"]

    static func find(folder: URL, series: String, episode: Episode?, identifier: String, title: String) -> URL? {
        let seriesFolder = folder.appendingPathComponent(InputPolicy.folderName(series), isDirectory: true)
        let folderName = normalize(folder.lastPathComponent)
        let seriesName = normalize(InputPolicy.folderName(series))
        var searches = [(folder, true), (seriesFolder, true)]
        if folderName != seriesName { searches.append((folder, false)) }
        for (directory, inSeries) in searches {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = file.pathExtension.lowercased()
                guard extensions.contains(ext), !file.lastPathComponent.contains(".part"),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      size(of: attributes) > 0 else { continue }
                if matches(file: file, episode: episode, identifier: identifier, title: title, inSeries: inSeries) { return file }
            }
        }
        return nil
    }

    private static func matches(file: URL, episode: Episode?, identifier: String, title: String, inSeries: Bool) -> Bool {
        let rawName = file.deletingPathExtension().lastPathComponent.lowercased()
        return filenameMatches(rawName, episode: episode, identifier: identifier, title: title, inSeries: inSeries)
    }

    static func filenameMatches(_ rawName: String, episode: Episode?, identifier: String, title: String, inSeries: Bool) -> Bool {
        filenameMatchReason(rawName, episode: episode, identifier: identifier, title: title, inSeries: inSeries) != nil
    }

    static func filenameMatchReason(_ rawName: String, episode: Episode?, identifier: String, title: String, inSeries: Bool) -> String? {
        let name = normalize(rawName)
        let rawIDs = [identifier, episode?.id, episode?.bvid].compactMap { $0 }
        let numericIDs = rawIDs.compactMap { value -> String? in
            guard let match = value.range(of: #"^[A-Za-z]+([0-9]+)$"#, options: .regularExpression) else { return nil }
            return String(value[match]).filter(\.isNumber)
        }
        let ids = (rawIDs + numericIDs).map(normalize)
        if let id = ids.first(where: { !$0.isEmpty && name.contains($0) }) { return "id:\(id)" }
        guard inSeries, let episode else {
            let expected = normalize(title)
            return expected.count >= 4 && name.contains(expected) ? "title" : nil
        }
        let index = String(episode.index)
        let seasonPattern = #"(?i)(?:^|[^0-9])S01E0*"# + index + #"(?![0-9])"#
        if rawName.range(of: seasonPattern, options: .regularExpression) != nil { return "season" }
        let episodePattern = #"第0*"# + index + #"(?:话|集)(?![0-9])"#
        if rawName.range(of: episodePattern, options: .regularExpression) != nil { return "episode" }
        let titleMarker = normalize(episode.title)
        if titleMarker.count >= 8, name.contains(titleMarker) { return "title" }
        return rawName.range(of: #"^(?:0*"# + index + #")(?![0-9])\s*[-_. ]"#, options: .regularExpression) != nil ? "prefix" : nil
    }

    private static func size(of attributes: [FileAttributeKey: Any]) -> Int64 {
        if let number = attributes[.size] as? NSNumber { return number.int64Value }
        if let value = attributes[.size] as? Int { return Int64(value) }
        return 0
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
