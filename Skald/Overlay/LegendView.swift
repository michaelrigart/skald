import SkaldCore
import SwiftUI

/// What each underline colour means: a 2-point sample line in the colour, dotted for Punctuation, and the title.
struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(IssueCategory.allCases, id: \.self) { category in
                HStack(spacing: 8) {
                    Sample(category: category)
                        .frame(width: 28, height: OverlayGeometry.underlineThickness)
                    Text(category.title)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct Sample: View {
        let category: IssueCategory

        var body: some View {
            Canvas { context, size in
                let colour = Color(nsColor: CategoryPalette.color(category))
                if CategoryPalette.isDotted(category) {
                    var x: CGFloat = 0
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: min(2, size.width - x), height: size.height)), with: .color(colour))
                        x += 4
                    }
                } else {
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1), with: .color(colour))
                }
            }
            .accessibilityHidden(true)
        }
    }
}
