import SwiftUI

@main
struct SpektraMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: PhotoModel { delegate.model }

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
                    Button("Open Preset…") { model.isImportingPreset = true }
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

/// Owns the model, so the app can ask before quitting during a save, and keep the settings for the
/// next launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PhotoModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let phase = model.savePhase else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while saving?"
        alert.informativeText = "\(phase) If you quit now, the photo isn't saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.storeSettings()
    }
}
