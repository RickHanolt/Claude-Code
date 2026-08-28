import SwiftUI

/// The app's toy-block lettering, shared rather than owned by any one screen.
///
/// It started as the Calendar's day markers ("MON" over a big 25). Morning
/// Mode wants the same treatment for each kid's name, so it lives here from
/// the start — a second private copy in another view is how two screens that
/// are meant to match slowly stop matching.

/// Block colours, cycled per letter so a word reads red/yellow/green the way a
/// real set of children's blocks would rather than as a row of one colour.
let blockPalette: [Color] = [
    Color(red: 0.85, green: 0.26, blue: 0.24),
    Color(red: 0.95, green: 0.70, blue: 0.15),
    Color(red: 0.15, green: 0.62, blue: 0.35),
    Color(red: 0.13, green: 0.52, blue: 0.90),
    Color(red: 0.52, green: 0.27, blue: 0.84),
]

/// One letter tile.
///
/// Drawn rather than shipped as image assets. Weekday abbreviations come from
/// the device locale and kids' names are whatever a parent types, so an image
/// set would need every letter either could produce; and flat art picks its own
/// colours in dark mode, where a photographic block would sit on a background
/// it wasn't shot for.
struct AlphabetBlock: View {
    let letter: String
    let color: Color
    var size: CGFloat = 19
    var tilt: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                .fill(Color.white.opacity(0.92))
                .padding(size * 0.13)

            Text(letter)
                .font(.system(size: size * 0.58, weight: .black, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(tilt))
        .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
    }
}

/// A word spelled in blocks — "MON", "JONAH", "TEDDY".
///
/// `sizes` are tried largest-first and the first one that fits the space the
/// parent offers wins. Names are user-entered and unbounded: "JONAH" is five
/// blocks, but nothing stops a "CHRISTOPHER", and the wrong answers there are
/// pushing the layout off-screen or truncating somebody's kid's name. Shrinking
/// is the only option that stays correct at any length.
struct BlockWord: View {
    let word: String

    /// Shifts where the palette starts, so two words on screen together don't
    /// come out in the same colour sequence. Same seed always gives the same
    /// colours, so a kid's name looks the same every morning.
    var colorSeed: Int = 0

    var sizes: [CGFloat] = [22, 19, 16, 13, 11]

    private var letters: [String] {
        word.uppercased().map(String.init)
    }

    /// Fixed per position rather than random, so the blocks don't re-tilt on
    /// every redraw — the jitter should read as a hand-placed row, not a fidget.
    private static let tilts: [Double] = [-4.0, 2.5, -1.5, 3.0, -2.5, 1.5]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(sizes, id: \.self) { size in
                row(size: size)
            }
        }
    }

    private func row(size: CGFloat) -> some View {
        HStack(spacing: size * 0.11) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                AlphabetBlock(
                    letter: letter,
                    color: blockPalette[(index + colorSeed) % blockPalette.count],
                    size: size,
                    tilt: Self.tilts[index % Self.tilts.count]
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
    }
}
