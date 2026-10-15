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
            // Nothing here prints.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .newItem) {
                Button("Open…", systemImage: "folder") { model.isImporting = true }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
                Button("Export LUT…", systemImage: "cube") { model.exportLUT() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportLUT)
                Button("Cancel", systemImage: "xmark.circle") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canCancel)
            }
            CommandMenu("Preset") {
                Group {
                    Button("Open Preset…") { model.openPreset() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("Save Preset…") { model.savePreset() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Divider()
                    Button("Make Default for \(model.filmName)") { model.makeDefaultForFilm() }
                    Button("Restore Factory Defaults") { model.restoreFactoryDefaults() }
                }
                .disabled(!model.canUsePresets)
            }
        }

        // A window of its own: the settings have the main window's inspector.
        Window("Log", id: "log") {
            LogView()
                .environment(model)
        }
        .defaultSize(width: 420, height: 480)
    }
}
