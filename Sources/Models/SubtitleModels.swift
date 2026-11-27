import Foundation

struct SubtitleCue: Identifiable, Equatable, Sendable {
    let id: Int
    let startTime: Double
    let endTime: Double
    let text: String
}

enum SubtitleColorPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case white = "纯白"
    case yellow = "暖黄"
    case cyan = "晶青"

    var id: Self { self }
}

struct SubtitleStyleSettings: Codable, Equatable, Sendable {
    var fontSize: Double = 20.0
    var bottomPadding: Double = 28.0
    var timeOffsetSeconds: Double = 0.0
    var backgroundOpacity: Double = 0.45
    var colorPreset: SubtitleColorPreset = .white

    static let `default` = SubtitleStyleSettings()
}

struct CloudSubtitleCandidate: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let fileExtension: String
    let sourceKind: MediaSourceKind
    let accountID: UUID?
    let directURL: URL?
    let headers: [String: String]
    let embySubtitleStreamIndex: Int?
    let mediaSourceId: String?
    let itemId: String?

    init(
        id: String,
        name: String,
        fileExtension: String,
        sourceKind: MediaSourceKind,
        accountID: UUID? = nil,
        directURL: URL? = nil,
        headers: [String: String] = [:],
        embySubtitleStreamIndex: Int? = nil,
        mediaSourceId: String? = nil,
        itemId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension.lowercased()
        self.sourceKind = sourceKind
        self.accountID = accountID
        self.directURL = directURL
        self.headers = headers
        self.embySubtitleStreamIndex = embySubtitleStreamIndex
        self.mediaSourceId = mediaSourceId
        self.itemId = itemId
    }
}

enum SubtitleTrackSource: Equatable, Hashable, Sendable {
    case embedded(optionIndex: Int, languageCode: String, displayName: String)
    case externalLocal(url: URL, displayName: String)
    case externalCloud(candidate: CloudSubtitleCandidate)
}

struct SubtitleTrackOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let detail: String
    let source: SubtitleTrackSource
}

enum SubtitleParser: Sendable {
    static func decodeText(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let utf8Check = data.prefix(3)
        var normalizedData = data
        if utf8Check.count == 3 && Array(utf8Check) == [0xEF, 0xBB, 0xBF] {
            normalizedData = data.dropFirst(3)
        }
        if let str = String(data: normalizedData, encoding: .utf8) {
            return stripLeadingBOM(str)
        }
        if let str = String(data: data, encoding: .utf16) {
            return stripLeadingBOM(str)
        }
        if let str = String(data: data, encoding: .utf16LittleEndian) {
            return stripLeadingBOM(str)
        }
        if let str = String(data: data, encoding: .utf16BigEndian) {
            return stripLeadingBOM(str)
        }
        let gbEncodingRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let gbEncoding = String.Encoding(rawValue: gbEncodingRaw)
        if let str = String(data: normalizedData, encoding: gbEncoding) {
            return stripLeadingBOM(str)
        }
        if let str = String(data: normalizedData, encoding: .isoLatin1) {
            return stripLeadingBOM(str)
        }
        return String(decoding: normalizedData, as: UTF8.self)
    }

    static func parse(data: Data, fileExtension: String) -> [SubtitleCue] {
        let text = decodeText(from: data)
        return parse(text: text, fileExtension: fileExtension)
    }

    static func parse(text: String, fileExtension: String) -> [SubtitleCue] {
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cues: [SubtitleCue]
        switch ext {
        case "vtt":
            cues = parseWebVTT(text)
        case "ass", "ssa":
            cues = parseASS(text)
        default:
            if text.lstripWhitespace().hasPrefix("WEBVTT") {
                cues = parseWebVTT(text)
            } else if text.contains("[Events]") && text.contains("Dialogue:") {
                cues = parseASS(text)
            } else {
                cues = parseSRT(text)
            }
        }
        return cues.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }
            return $0.endTime < $1.endTime
        }
    }

    static func activeCues(in cues: [SubtitleCue], at mediaTime: Double, offset: Double = 0) -> [SubtitleCue] {
        guard !cues.isEmpty, mediaTime.isFinite else { return [] }
        let queryTime = mediaTime + (offset.isFinite ? offset : 0)

        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startTime <= queryTime {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upperBound = min(cues.count, low)
        var startIdx = max(0, upperBound - 16)
        while startIdx > 0 && cues[startIdx].endTime >= queryTime {
            startIdx -= 1
        }
        var active: [SubtitleCue] = []
        for idx in startIdx..<upperBound {
            let cue = cues[idx]
            if cue.startTime <= queryTime && queryTime <= cue.endTime {
                active.append(cue)
            }
        }
        return active
    }

    static func parseSRT(_ raw: String) -> [SubtitleCue] {
        let normalized = normalizeLineEndings(raw)
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var nextID = 0

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timeLine = lines[timeLineIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count >= 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]),
                  end > start else {
                continue
            }

            let bodyLines = lines[(timeLineIndex + 1)...]
            let cleanedText = cleanFormattedText(bodyLines.joined(separator: "\n"))
            guard !cleanedText.isEmpty else { continue }

            cues.append(SubtitleCue(id: nextID, startTime: start, endTime: end, text: cleanedText))
            nextID += 1
        }
        return cues
    }

    static func parseWebVTT(_ raw: String) -> [SubtitleCue] {
        let normalized = normalizeLineEndings(raw)
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var nextID = 0

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = lines.first else { continue }
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                continue
            }

            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timeLine = lines[timeLineIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count >= 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]),
                  end > start else {
                continue
            }

            let bodyLines = lines[(timeLineIndex + 1)...]
            let cleanedText = cleanFormattedText(bodyLines.joined(separator: "\n"))
            guard !cleanedText.isEmpty else { continue }

            cues.append(SubtitleCue(id: nextID, startTime: start, endTime: end, text: cleanedText))
            nextID += 1
        }
        return cues
    }

    static func parseASS(_ raw: String) -> [SubtitleCue] {
        let normalized = normalizeLineEndings(raw)
        let lines = normalized.components(separatedBy: "\n")
        var inEvents = false
        var startIdx = 1
        var endIdx = 2
        var textIdx = 9
        var columnCount = 10
        var cues: [SubtitleCue] = []
        var nextID = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                inEvents = (line.caseInsensitiveCompare("[Events]") == .orderedSame)
                continue
            }

            if !inEvents && !line.hasPrefix("Dialogue:") {
                continue
            }

            if line.lowercased().hasPrefix("format:") {
                let spec = line.dropFirst("format:".count)
                let cols = spec.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                if let s = cols.firstIndex(of: "start") { startIdx = s }
                if let e = cols.firstIndex(of: "end") { endIdx = e }
                if let t = cols.firstIndex(of: "text") { textIdx = t }
                columnCount = max(cols.count, textIdx + 1)
                continue
            }

            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = String(line.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
            let fields = splitASSFields(payload, expectedColumns: columnCount)
            guard startIdx < fields.count,
                  endIdx < fields.count,
                  textIdx < fields.count else {
                continue
            }
            guard let start = parseTimestamp(fields[startIdx]),
                  let end = parseTimestamp(fields[endIdx]),
                  end > start else {
                continue
            }

            let textField = fields[textIdx]
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            let cleaned = cleanFormattedText(textField)
            guard !cleaned.isEmpty else { continue }

            cues.append(SubtitleCue(id: nextID, startTime: start, endTime: end, text: cleaned))
            nextID += 1
        }
        return cues
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return nil }

        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let colonParts = normalized.split(separator: ":").map(String.init)
        guard colonParts.count == 2 || colonParts.count == 3 else { return nil }

        let hours: Double
        let minutes: Double
        let secondsStr: String
        if colonParts.count == 3 {
            guard let h = Double(colonParts[0]), let m = Double(colonParts[1]) else { return nil }
            hours = h
            minutes = m
            secondsStr = colonParts[2]
        } else {
            hours = 0
            guard let m = Double(colonParts[0]) else { return nil }
            minutes = m
            secondsStr = colonParts[1]
        }

        let secParts = secondsStr.split(separator: ".", maxSplits: 1).map(String.init)
        guard let wholeSec = Double(secParts[0]) else { return nil }
        var fracSec = 0.0
        if secParts.count == 2 {
            let fracRaw = secParts[1]
            if let fracVal = Double(fracRaw), !fracRaw.isEmpty {
                let denom = pow(10.0, Double(fracRaw.count))
                fracSec = fracVal / denom
            }
        }
        return hours * 3600.0 + minutes * 60.0 + wholeSec + fracSec
    }

    private static func splitASSFields(_ payload: String, expectedColumns: Int) -> [String] {
        guard expectedColumns > 1 else { return [payload] }
        var fields: [String] = []
        fields.reserveCapacity(expectedColumns)
        var currentIndex = payload.startIndex

        for _ in 0..<(expectedColumns - 1) {
            if let commaIndex = payload[currentIndex...].firstIndex(of: ",") {
                fields.append(String(payload[currentIndex..<commaIndex]).trimmingCharacters(in: .whitespaces))
                currentIndex = payload.index(after: commaIndex)
            } else {
                break
            }
        }
        fields.append(String(payload[currentIndex...]).trimmingCharacters(in: .whitespaces))
        return fields
    }

    private static func normalizeLineEndings(_ input: String) -> String {
        stripLeadingBOM(input)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func stripLeadingBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func cleanFormattedText(_ text: String) -> String {
        var result = text
        // 移除 ASS 覆盖标签 {\pos(...)} 等与 VTT/HTML 标签 <i>, <c.color>
        result = result.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func lstripWhitespace() -> String {
        var idx = startIndex
        while idx < endIndex && self[idx].isWhitespace {
            idx = index(after: idx)
        }
        return String(self[idx...])
    }
}
