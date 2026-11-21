
import SwiftUI
import UniformTypeIdentifiers

// Diagnostic-only. Never writes a bookmark or changes production library settings.
final class PickerLab: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let logKey = "mornye.pickerLab.log.v1"
    private var active: Attempt?
    private var generation = 0

    private final class Attempt {
        let id: String
        let picker: UIViewController
        var window: UIWindow?
        weak var priorWindow: UIWindow?
        var callback = false
        var finished = false
        init(_ id: String, _ picker: UIViewController) {
            self.id = id
            self.picker = picker
        }
    }

    func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var entries = UserDefaults.standard.stringArray(forKey: logKey) ?? []
        entries.append("\(stamp) \(message)")
        if entries.count > 600 { entries.removeFirst(entries.count - 600) }
        UserDefaults.standard.set(entries, forKey: logKey)
        NSLog("PickerLab: %@", message)
    }

    func logs() -> String {
        (UserDefaults.standard.stringArray(forKey: logKey) ?? []).joined(separator: "\n")
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: logKey)
        log("Log cleared")
    }

    func environment(window: UIWindow?) {
        let scene = window?.windowScene
        let provisioned = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        log("ENV iOS=\(UIDevice.current.systemVersion) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") embedded.mobileprovision=\(provisioned) scene=\(String(describing: scene?.activationState)) window=\(window != nil)")
    }

    func start(_ id: String, window: UIWindow?) -> String {
        guard ["A", "B", "C", "D"].contains(id) else { return "Unknown experiment" }
        guard active == nil else {
            log("\(id) rejected: another experiment is active")
            return "Another picker is active; dismiss it or reopen Mornye first"
        }
        guard let window = window, let root = window.rootViewController else {
            log("\(id) failed: no active window/root")
            return "No active window"
        }
        let controller: UIViewController
        if id == "C" {
            controller = UIHostingController(rootView: LabImporter(
                onEvent: { [weak self] event in self?.log("C \(event)") },
                onResult: { [weak self] result in
                    guard let self = self, self.active?.id == "C" else { return }
                    self.active?.callback = true
                    switch result {
                    case .success(let urls):
                        self.log("C fileImporter callback count=\(urls.count)")
                        urls.forEach { self.probe($0, id: "C") }
                    case .failure(let error):
                        self.log("C fileImporter error=\(error.localizedDescription)")
                    }
                    self.finish("C", reason: "fileImporter completed")
                }
            ))
        } else {
            let types: [UTType] = id == "D" ? [.audio] : [.folder]
            let picker = LabDocumentPicker(forOpeningContentTypes: types, asCopy: false)
            picker.onDisappear = { [weak self] in self?.log("\(id) viewDidDisappear") }
            picker.delegate = self
            picker.allowsMultipleSelection = false
            if id == "A" { picker.modalPresentationStyle = .fullScreen }
            picker.presentationController?.delegate = self
            controller = picker
        }
        let attempt = Attempt(id, controller)
        active = attempt
        generation += 1
        let serial = generation
        log("\(id) begin scene=\(String(describing: window.windowScene?.activationState))")
        if id == "A", let scene = window.windowScene {
            let hostWindow = UIWindow(windowScene: scene)
            hostWindow.windowLevel = .alert + 1
            let host = UIViewController()
            host.view.backgroundColor = .clear
            hostWindow.rootViewController = host
            attempt.window = hostWindow
            attempt.priorWindow = window
            hostWindow.makeKeyAndVisible()
            host.present(controller, animated: true) { [weak self] in self?.log("A presented completion") }
        } else {
            var presenter = root
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(controller, animated: true) { [weak self] in self?.log("\(id) presented completion") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.generation == serial,
                  let attempt = self.active, attempt.id == id, !attempt.callback else { return }
            self.log("\(id) NO DELEGATE/RESULT CALLBACK AFTER 10 SECONDS")
        }
        return "Presented \(id)"
    }

    private func probe(_ url: URL, id: String) {
        let granted = url.startAccessingSecurityScopedResource()
        log("\(id) URL type=\(url.hasDirectoryPath ? "folder" : "file") securityScope=\(granted)")
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            log("\(id) readable=\(String(describing: values.isReadable)) directory=\(String(describing: values.isDirectory))")
            if values.isDirectory == true {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                log("\(id) one-time enumeration succeeded entries=\(children.count)")
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let sample = try handle.read(upToCount: 1)
                log("\(id) one-byte read succeeded bytes=\(sample?.count ?? 0)")
            }
        } catch { log("\(id) access ERROR=\(error.localizedDescription)") }
        // No bookmarks are generated, stored, or sent to Flutter.
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let attempt = active, attempt.picker === controller else {
            log("ORPHAN didPickDocumentsAt count=\(urls.count)")
            return
        }
        attempt.callback = true
        log("\(attempt.id) didPickDocumentsAt count=\(urls.count)")
        urls.forEach { probe($0, id: attempt.id) }
        finish(attempt.id, reason: "delegate selection")
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let attempt = active, attempt.picker === controller else {
            log("ORPHAN cancel callback")
            return
        }
        attempt.callback = true
        log("\(attempt.id) documentPickerWasCancelled")
        finish(attempt.id, reason: "cancelled")
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        log("\(active?.id ?? "?") presentationControllerDidDismiss")
        if let attempt = active { finish(attempt.id, reason: "presentation dismissed") }
    }

    private func finish(_ id: String, reason: String) {
        guard let attempt = active, attempt.id == id, !attempt.finished else { return }
        attempt.finished = true
        log("\(id) finished: \(reason)")
        attempt.picker.dismiss(animated: true)
        attempt.window?.isHidden = true
        attempt.priorWindow?.makeKeyAndVisible()
        attempt.window = nil
        active = nil
    }
}

private final class LabDocumentPicker: UIDocumentPickerViewController {
    var onDisappear: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

private struct LabImporter: View {
    let onEvent: (String) -> Void
    let onResult: (Result<[URL], Error>) -> Void
    @State private var showImporter = false
    var body: some View {
        VStack {
            Text("Picker Lab C").font(.headline)
            Button("Open Files folder picker") { showImporter = true }
            Button("Close") { onResult(.failure(NSError(domain: "PickerLab", code: -2, userInfo: [NSLocalizedDescriptionKey: "Closed by user"]))) }
        }
        .onAppear {
            onEvent("SwiftUI host appeared")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showImporter = true }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            onResult(result)
        }
    }
}
