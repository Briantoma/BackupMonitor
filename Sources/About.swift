import SwiftUI

/// About window: app icon, version, Oz Color logo and links, credits. Its own window rather than
/// the standard About panel, whose credits box is short and scrolls.
enum About {
    static let shop = URL(string: "https://shop.oz-color.fr/")!

    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "About Backup Monitor"
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: AboutView())
            window.contentViewController = content
            window.setContentSize(content.view.fittingSize)   // size first, so center() uses the real size
            window.center()
            DockPresence.track(window)
            self.window = window
        }
        DockPresence.show()
        window?.makeKeyAndOrderFront(nil)
        // Otherwise the first link gets the focus ring on opening; Tab still reaches the links.
        window?.makeFirstResponder(nil)
    }
}

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("Backup Monitor").font(.title3).bold()
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption).foregroundStyle(.secondary)

            // Black logo in light mode, white in dark mode.
            if let logo = Bundle.main.image(forResource: colorScheme == .dark ? "OzColor-white" : "OzColor-black") {
                Image(nsImage: logo).resizable().frame(width: 72, height: 72).padding(.top, 12)
            }
            Text("Made by Oz Color")
            Link("shop.oz-color.fr", destination: About.shop)

            Text("For Silverstack XT and Silverstack Lab. Offload Manager is not supported.").padding(.top, 12)
            Text("Not affiliated with Pomfort.")
            Text("Original idea from Joe Jamieson").padding(.top, 4)

            if let copyright = info["NSHumanReadableCopyright"] as? String {
                Text(copyright).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 320)
    }
}
