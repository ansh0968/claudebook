import PencilKit
import UIKit

/// Shared UserDefaults persistence for Apple Pencil behavior across all canvases and menus.
enum PencilSettings {
    static let doubleTapUndoKey = "pencilDoubleTapUndo"

    static var isDoubleTapUndoEnabled: Bool {
        get {
            if let stored = UserDefaults.standard.object(forKey: doubleTapUndoKey) as? Bool {
                return stored
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: doubleTapUndoKey)
        }
    }
}

/// Attaches a `UIPencilInteraction` to a `PKCanvasView` so Apple Pencil double-taps trigger Undo
/// when enabled, and falls back to `PKToolPicker`'s system behavior when disabled.
@MainActor
final class PencilDoubleTapInteraction: NSObject, UIPencilInteractionDelegate {
    let interaction = UIPencilInteraction()
    private weak var canvas: PKCanvasView?
    var onDoubleTap: (() -> Void)?

    var isEnabled: Bool {
        get { interaction.isEnabled }
        set { interaction.isEnabled = newValue }
    }

    override init() {
        super.init()
        interaction.delegate = self
        interaction.isEnabled = PencilSettings.isDoubleTapUndoEnabled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func attach(to canvas: PKCanvasView) {
        self.canvas = canvas
        interaction.isEnabled = PencilSettings.isDoubleTapUndoEnabled
        if !(canvas.interactions.contains { $0 === interaction }) {
            canvas.addInteraction(interaction)
        }
    }

    @objc private nonisolated func defaultsDidChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.syncWithDefaults() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.syncWithDefaults() }
        }
    }

    private func syncWithDefaults() {
        let enabled = PencilSettings.isDoubleTapUndoEnabled
        if interaction.isEnabled != enabled {
            interaction.isEnabled = enabled
        }
    }

    func handleTap() {
        guard interaction.isEnabled else { return }
        if let onDoubleTap {
            onDoubleTap()
        } else {
            canvas?.undoManager?.undo()
        }
    }

    // MARK: UIPencilInteractionDelegate

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handleTap()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handleTap()
    }
}
