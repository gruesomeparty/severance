import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// Dark = the MDR terminal, light = the severed floor. The two gauge wells stay
// navy CRT islands in BOTH themes (see the mockup caption), so their colors are
// fixed rather than theme-derived.
struct Palette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }

    var desk: Color { dark ? Color(hex: 0x071523) : Color(hex: 0xDCE4E1) }
    var panelTop: Color { dark ? Color(hex: 0x0D2338) : Color(hex: 0xFBFDFC) }
    var panel: Color { dark ? Color(hex: 0x0B1F33) : Color(hex: 0xF2F6F4) }
    var panelBorder: Color { dark ? Color(hex: 0x9FE8FF, alpha: 0.16) : Color(hex: 0x16303B, alpha: 0.14) }
    var ink: Color { dark ? Color(hex: 0xE8F1F4) : Color(hex: 0x16303B) }
    var inkMute: Color { dark ? Color(hex: 0x46647D) : Color(hex: 0x6B8189) }
    var inkSoft: Color { dark ? Color(hex: 0x8FA9BD) : Color(hex: 0x44606C) }
    var accent: Color { dark ? Color(hex: 0x9FE8FF) : Color(hex: 0x1F6E63) }
    var accentDim: Color { dark ? Color(hex: 0x58C4E5) : Color(hex: 0x2F8577) }
    var accentBG: Color { dark ? Color(hex: 0x9FE8FF, alpha: 0.09) : Color(hex: 0x1F6E63, alpha: 0.08) }
    var accentBorder: Color { dark ? Color(hex: 0x9FE8FF, alpha: 0.30) : Color(hex: 0x1F6E63, alpha: 0.35) }
    var hairline: Color { dark ? Color(hex: 0x9FE8FF, alpha: 0.09) : Color(hex: 0x16303B, alpha: 0.10) }
    var ok: Color { dark ? Color(hex: 0x7FD6A4) : Color(hex: 0x1F8A5A) }
    var amber: Color { dark ? Color(hex: 0xE8B34B) : Color(hex: 0xB0761A) }
    var severed: Color { dark ? Color(hex: 0xE06055) : Color(hex: 0xC24A40) }
    var mint: Color { dark ? Color(hex: 0x7FD6A4) : Color(hex: 0x2F8577) }
    var barBG: Color { dark ? Color(hex: 0x9FE8FF, alpha: 0.10) : Color(hex: 0x16303B, alpha: 0.12) }

    // Gauge well — navy in both themes; its numerals are the bright terminal cyan.
    let well = Color(hex: 0x081A2C)
    let wellBorder = Color(hex: 0x9FE8FF, alpha: 0.14)
    let wellInk = Color(hex: 0x9FE8FF)
    let wellInkDim = Color(hex: 0x58C4E5)
    let wellAmber = Color(hex: 0xE8B34B)
    let wellRedTick = Color(hex: 0xE06055)
}

// Serif numerals: New York (Apple's serif), per the PRD's "Spectral-style serif
// numerals … or use New York" — no bundled font required.
extension Font {
    static func serifNumerals(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
