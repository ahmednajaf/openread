import SwiftUI

// The website's ink, paper and lavender palette, rendered with native materials.
enum ReaderStyle {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.76, green: 0.68, blue: 0.86, alpha: 1) : UIColor(red: 0.47, green: 0.37, blue: 0.65, alpha: 1) })
    static let gold = Color(red: 0.85, green: 0.67, blue: 0.42)
    static let ink = Color.primary
}
struct ReadingBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                (scheme == .dark ? Color(red: 0.085, green: 0.073, blue: 0.11) : Color(red: 0.98, green: 0.97, blue: 0.985))
                Ellipse().fill(Color(red: 0.66, green: 0.48, blue: 0.79).opacity(scheme == .dark ? 0.22 : 0.16))
                    .frame(width: geometry.size.width * 1.2, height: 430).blur(radius: 85).offset(x: 90, y: -geometry.size.height * 0.34)
                Ellipse().fill(ReaderStyle.gold.opacity(scheme == .dark ? 0.10 : 0.12))
                    .frame(width: 360, height: 360).blur(radius: 80).offset(x: -120, y: geometry.size.height * 0.25)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}
struct BookEmblem: View {
    var compact = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(.primary.opacity(0.07), lineWidth: 0.7)
            Ellipse().strokeBorder(.primary.opacity(0.09), lineWidth: 0.7).rotationEffect(.degrees(-35))
            Image(systemName: "book.pages.fill").font(.system(size: compact ? 21 : 36, weight: .ultraLight)).symbolRenderingMode(.hierarchical)
        }.foregroundStyle(ReaderStyle.accent).frame(width: compact ? 48 : 96, height: compact ? 48 : 96).accessibilityHidden(true)
    }
}
struct BookCover: View {
    let reading: Reading
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color(red: 0.44, green: 0.36, blue: 0.54), Color(red: 0.22, green: 0.18, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse().stroke(.white.opacity(0.25), lineWidth: 0.7).frame(width: 75, height: 75).rotationEffect(.degrees(-35)).offset(x: 28, y: -38)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.leading, 7)
            Image(systemName: "text.book.closed").font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.8)).padding(12)
        }.frame(width: 65, height: 84).shadow(color: .black.opacity(0.12), radius: 7, y: 4).accessibilityHidden(true)
    }
}
struct NativePrimaryButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}
extension View { func nativePrimaryButton() -> some View { modifier(NativePrimaryButton()) } }
