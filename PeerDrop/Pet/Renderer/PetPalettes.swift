import SwiftUI

struct ColorPalette: Equatable {
    let outline: Color    // slot 1
    let primary: Color    // slot 2
    let secondary: Color  // slot 3
    let highlight: Color  // slot 4
    let accent: Color     // slot 5
    let pattern: Color    // slot 6

    func color(for index: Int) -> Color? {
        switch index {
        case 1: return outline
        case 2: return primary
        case 3: return secondary
        case 4: return highlight
        case 5: return accent
        case 6: return pattern
        default: return nil
        }
    }
}

enum PetPalettes {
    static let all: [ColorPalette] = [
        // 0: Warm Orange — playful puppy
        ColorPalette(
            outline:   Color(red: 0x5C/255, green: 0x3A/255, blue: 0x1E/255),
            primary:   Color(red: 0xF4/255, green: 0xA0/255, blue: 0x41/255),
            secondary: Color(red: 0xFE/255, green: 0xDE/255, blue: 0x8A/255),
            highlight: Color(red: 0xFF/255, green: 0xF5/255, blue: 0xD6/255),
            accent:    Color(red: 0xE8/255, green: 0x5D/255, blue: 0x3A/255),
            pattern:   Color(red: 0xD4/255, green: 0x85/255, blue: 0x3A/255)
        ),
        // 1: Sky Blue — water spirit
        ColorPalette(
            outline:   Color(red: 0x2A/255, green: 0x40/255, blue: 0x66/255),
            primary:   Color(red: 0x6C/255, green: 0xB4/255, blue: 0xEE/255),
            secondary: Color(red: 0xB8/255, green: 0xE0/255, blue: 0xFF/255),
            highlight: Color(red: 0xE8/255, green: 0xF4/255, blue: 0xFF/255),
            accent:    Color(red: 0x3A/255, green: 0x7B/255, blue: 0xD5/255),
            pattern:   Color(red: 0x4A/255, green: 0x90/255, blue: 0xD9/255)
        ),
        // 2: Lavender — dreamy
        ColorPalette(
            outline:   Color(red: 0x4A/255, green: 0x35/255, blue: 0x60/255),
            primary:   Color(red: 0xB0/255, green: 0x8C/255, blue: 0xD8/255),
            secondary: Color(red: 0xD8/255, green: 0xC0/255, blue: 0xF0/255),
            highlight: Color(red: 0xF0/255, green: 0xE8/255, blue: 0xFF/255),
            accent:    Color(red: 0x8B/255, green: 0x5F/255, blue: 0xC7/255),
            pattern:   Color(red: 0x9B/255, green: 0x70/255, blue: 0xD0/255)
        ),
        // 3: Fresh Green — grass sprite
        ColorPalette(
            outline:   Color(red: 0x2D/255, green: 0x5A/255, blue: 0x1E/255),
            primary:   Color(red: 0x7E/255, green: 0xC8/255, blue: 0x50/255),
            secondary: Color(red: 0xB8/255, green: 0xE8/255, blue: 0x90/255),
            highlight: Color(red: 0xE0/255, green: 0xFF/255, blue: 0xD0/255),
            accent:    Color(red: 0x4C/255, green: 0xAF/255, blue: 0x50/255),
            pattern:   Color(red: 0x5D/255, green: 0xBF/255, blue: 0x60/255)
        ),
        // 4: Cherry Pink — cute girl
        ColorPalette(
            outline:   Color(red: 0x6B/255, green: 0x30/255, blue: 0x40/255),
            primary:   Color(red: 0xF0/255, green: 0x80/255, blue: 0x80/255),
            secondary: Color(red: 0xFF/255, green: 0xB8/255, blue: 0xC0/255),
            highlight: Color(red: 0xFF/255, green: 0xE8/255, blue: 0xEC/255),
            accent:    Color(red: 0xE8/255, green: 0x50/255, blue: 0x80/255),
            pattern:   Color(red: 0xE8/255, green: 0x68/255, blue: 0x88/255)
        ),
        // 5: Caramel — brown bear
        ColorPalette(
            outline:   Color(red: 0x4A/255, green: 0x28/255, blue: 0x10/255),
            primary:   Color(red: 0xC8/255, green: 0x78/255, blue: 0x30/255),
            secondary: Color(red: 0xE8/255, green: 0xB8/255, blue: 0x78/255),
            highlight: Color(red: 0xFF/255, green: 0xF0/255, blue: 0xD8/255),
            accent:    Color(red: 0xA0/255, green: 0x58/255, blue: 0x28/255),
            pattern:   Color(red: 0xB0/255, green: 0x68/255, blue: 0x38/255)
        ),
        // 6: Slate Gray — cool type
        ColorPalette(
            outline:   Color(red: 0x2A/255, green: 0x2A/255, blue: 0x3A/255),
            primary:   Color(red: 0x78/255, green: 0x88/255, blue: 0xA0/255),
            secondary: Color(red: 0xA8/255, green: 0xB8/255, blue: 0xC8/255),
            highlight: Color(red: 0xD8/255, green: 0xE0/255, blue: 0xE8/255),
            accent:    Color(red: 0x50/255, green: 0x68/255, blue: 0xA0/255),
            pattern:   Color(red: 0x60/255, green: 0x78/255, blue: 0xA8/255)
        ),
        // 7: Lemon Yellow — energetic
        ColorPalette(
            outline:   Color(red: 0x5A/255, green: 0x50/255, blue: 0x20/255),
            primary:   Color(red: 0xE8/255, green: 0xD4/255, blue: 0x4A/255),
            secondary: Color(red: 0xF0/255, green: 0xE8/255, blue: 0x88/255),
            highlight: Color(red: 0xFF/255, green: 0xFF/255, blue: 0xF0/255),
            accent:    Color(red: 0xC8/255, green: 0xA8/255, blue: 0x30/255),
            pattern:   Color(red: 0xD0/255, green: 0xB8/255, blue: 0x38/255)
        ),
    ]

    static func palette(for genome: PetGenome) -> ColorPalette {
        all[genome.paletteIndex]
    }
}
