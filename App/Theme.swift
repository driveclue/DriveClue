import DriveClueCore
import SwiftUI

enum DiagnosticTheme {
    static let sidebar = Color(red: 0.89, green: 0.92, blue: 0.95)
    static let sidebarText = Color(red: 0.15, green: 0.20, blue: 0.25)
    static let sidebarMuted = Color(red: 0.42, green: 0.49, blue: 0.55)
    static let selection = Color(red: 0.22, green: 0.51, blue: 0.76)
    static let background = Color(red: 0.29, green: 0.33, blue: 0.36)
    static let panel = Color(red: 0.38, green: 0.42, blue: 0.45)
    static let row = Color(red: 0.36, green: 0.40, blue: 0.43)
    static let rowAlternate = Color(red: 0.33, green: 0.37, blue: 0.40)
    static let text = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let muted = Color(red: 0.76, green: 0.80, blue: 0.83)
    static let line = Color.white.opacity(0.13)
    static let footer = Color(red: 0.76, green: 0.79, blue: 0.81)
    static let green = Color(red: 0.43, green: 0.83, blue: 0.20)
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.20)
    static let deepOrange = Color(red: 0.95, green: 0.52, blue: 0.20)
    static let red = Color(red: 0.97, green: 0.36, blue: 0.34)
    static let teal = Color(red: 0.28, green: 0.78, blue: 0.72)
    static let orange = Color(red: 0.99, green: 0.60, blue: 0.26)
    static let purple = Color(red: 0.70, green: 0.56, blue: 0.95)
    static let rose = Color(red: 0.96, green: 0.44, blue: 0.58)
    static let cyan = Color(red: 0.36, green: 0.74, blue: 0.92)
    static let indigo = Color(red: 0.58, green: 0.60, blue: 0.96)
}

enum IndicatorStyle {
    static func color(_ status: IndicatorStatus) -> Color {
        switch status {
        case .ok: DiagnosticTheme.green
        case .warning: DiagnosticTheme.amber
        case .failing: DiagnosticTheme.deepOrange
        case .failed: DiagnosticTheme.red
        }
    }

    static func color(_ band: HealthBand) -> Color {
        switch band {
        case .good: DiagnosticTheme.green
        case .average: DiagnosticTheme.amber
        case .low: DiagnosticTheme.deepOrange
        case .bad: DiagnosticTheme.red
        }
    }
}
