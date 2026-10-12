import SwiftUI

@main
struct SpektraMacApp: App {
    @State private var model = PhotoModel()

    var body: some Scene {
        Window("SpektraMac", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            // Nothing here prints, and Preview takes ⌘P.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .newItem) {
                Button("Open…", systemImage: "folder") { model.isImporting = true }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Preview", systemImage: "eye") { model.renderPreview() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!model.canRender)
                Button("Render", systemImage: "camera.aperture") { model.renderFullResolution() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canRender)
                Button("Cancel", systemImage: "xmark.circle") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canCancel)
                Divider()
                Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
            }
        }
    }
}
