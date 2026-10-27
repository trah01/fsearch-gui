import Foundation

enum TimeFilter: String, CaseIterable, Identifiable {
    case any = "任何时间", today = "今天", week = "过去 7 天", month = "过去 30 天"
    var id: String { rawValue }
    var value: String? {
        switch self {
        case .any: return nil
        case .today:
            let seconds = max(1, Int(Date().timeIntervalSince(Calendar.current.startOfDay(for: Date()))))
            return "<\(seconds)s"
        case .week: return "<7d"
        case .month: return "<30d"
        }
    }
}

enum SizeFilter: String, CaseIterable, Identifiable {
    case any = "任何大小", large = "大文件（>100 MB）", small = "小文件（<1 MB）"
    var id: String { rawValue }
    var value: String? {
        switch self {
        case .any: return nil
        case .large: return ">100MB"
        case .small: return "<1MB"
        }
    }
}

extension FileCategory {
    static let sidebar: [FileCategory] = [.all, .document, .image, .video, .audio, .application, .folder, .other]
    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .document: return "doc"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .application: return "app.dashed"
        case .folder: return "folder"
        case .archive: return "archivebox"
        case .executable: return "terminal"
        case .custom: return "doc.badge.gearshape"
        case .other: return "doc.on.doc"
        }
    }
}
