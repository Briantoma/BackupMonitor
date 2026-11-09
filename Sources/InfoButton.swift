import SwiftUI

/// Small (i) icon: hover shows the explanation as a tooltip, a click shows it in a popover.
/// AppKit underneath, because a SwiftUI popover needs @State (no macro plugin in the Command Line Tools).
struct InfoButton: NSViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "More information")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.text = text
        button.toolTip = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text) }

    @MainActor final class Coordinator: NSObject {
        var text: String
        private let popover = NSPopover()

        init(text: String) {
            self.text = text
            popover.behavior = .transient
        }

        @objc func toggle(_ sender: NSButton) {
            if popover.isShown { popover.performClose(nil); return }
            let label = NSTextField(wrappingLabelWithString: text)
            label.isSelectable = true
            label.translatesAutoresizingMaskIntoConstraints = false
            let view = NSView()
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
                label.widthAnchor.constraint(equalToConstant: 260),
            ])
            let controller = NSViewController()
            controller.view = view
            popover.contentViewController = controller
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }
}
