import Foundation

enum FileNameMatch: String, Codable, CaseIterable, Identifiable {
    case contains = "包含", exact = "完全匹配", prefix = "开头是", suffix = "结尾是", regularExpression = "正则表达式"
    var id: String { rawValue }
}

enum FileSizeUnit: String, Codable, CaseIterable, Identifiable {
    case kb = "KB", mb = "MB", gb = "GB"
    var id: String { rawValue }
    var multiplier: Double {
        switch self {
        case .kb: return 1_000
        case .mb: return 1_000_000
        case .gb: return 1_000_000_000
        }
    }
}

struct AdvancedSearchFilters: Codable, Equatable {
    var name = ""
    var nameMatch: FileNameMatch = .contains
    var minimumSize = ""
    var maximumSize = ""
    var sizeUnit: FileSizeUnit = .mb
    var modifiedDays = ""

    var hasSize: Bool { !minimumSize.trimmingCharacters(in: .whitespaces).isEmpty || !maximumSize.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasTime: Bool { !modifiedDays.trimmingCharacters(in: .whitespaces).isEmpty }
    var isActive: Bool { !name.isEmpty || hasSize || hasTime }

    var sizeTitle: String {
        if minimumSize.isEmpty { return "≤\(maximumSize) \(sizeUnit.rawValue)" }
        if maximumSize.isEmpty { return "≥\(minimumSize) \(sizeUnit.rawValue)" }
        return "\(minimumSize)–\(maximumSize) \(sizeUnit.rawValue)"
    }

    func requestFields() throws -> [String: String] {
        var fields: [String: String] = [:]
        if !name.isEmpty {
            let literal = NSRegularExpression.escapedPattern(for: name)
            let pattern: String
            switch nameMatch {
            case .contains: pattern = literal
            case .exact: pattern = "^\(literal)$"
            case .prefix: pattern = "^\(literal)"
            case .suffix: pattern = "\(literal)$"
            case .regularExpression: pattern = name
            }
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { throw ClientError.message("文件名的正则表达式不正确，请检查后重试。") }
            fields["re"] = pattern
        }
        if hasSize {
            let minimum = try sizeValue(minimumSize)
            let maximum = try sizeValue(maximumSize)
            if let minimum, let maximum, minimum > maximum {
                throw ClientError.message("最小大小不能大于最大大小。")
            }
            if let minimum, let maximum { fields["size"] = "\(minimum)..\(maximum)" }
            else if let minimum { fields["size"] = ">=\(minimum)" }
            else if let maximum { fields["size"] = "<=\(maximum)" }
        }
        if hasTime {
            guard let days = Int(modifiedDays.trimmingCharacters(in: .whitespaces)), (1...36500).contains(days) else {
                throw ClientError.message("修改时间请输入 1 到 36500 之间的天数。")
            }
            fields["mtime"] = "<\(days)d"
        }
        return fields
    }

    static func normalizedExtensions(_ text: String) throws -> String {
        let parts = text.lowercased().components(separatedBy: CharacterSet(charactersIn: ",，;； ").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.allSatisfy({ $0.range(of: "^[a-z0-9_+-]+$", options: .regularExpression) != nil }) else {
            throw ClientError.message("请输入有效的文件后缀，多个后缀用逗号分隔。")
        }
        return Array(Set(parts)).sorted().joined(separator: ",")
    }

    private func sizeValue(_ text: String) throws -> UInt64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let value = Double(text), value.isFinite, value >= 0, value * sizeUnit.multiplier < Double(UInt64.max) else {
            throw ClientError.message("文件大小请输入有效的非负数。")
        }
        return UInt64(value * sizeUnit.multiplier)
    }
}
