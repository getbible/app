import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let nativeFiles = NativeFilesHandler()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeFiles") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "life.getbible.mobile/files",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler(nativeFiles.handle)
  }
}

private final class NativeFilesHandler: NSObject, UIDocumentPickerDelegate {
  private let maxFileBytes = 64 * 1024 * 1024
  private let maxShareBytes = 256 * 1024
  private var pendingResult: FlutterResult?
  private var exportDirectory: URL?
  private var pendingLimit = 64 * 1024 * 1024
  private var reading = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["shareText", "saveText", "pickTextFile"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard claim(result) else { return }
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "shareText":
      let text = arguments?["text"] as? String ?? ""
      guard text.utf8.count <= maxShareBytes else {
        fail("This text is too large for a share sheet. Save it as a file instead.")
        return
      }
      let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
      controller.setValue(arguments?["subject"] as? String ?? "getBible", forKey: "subject")
      controller.completionWithItemsHandler = { [weak self] _, completed, _, error in
        if error != nil {
          self?.fail("Sharing could not be completed. Save or copy the text instead.")
        } else {
          self?.finish(completed ? "completed" : "cancelled")
        }
      }
      present(controller)
    case "saveText":
      let text = arguments?["text"] as? String ?? ""
      let filename = arguments?["filename"] as? String ?? "getBible.txt"
      guard text.utf8.count <= maxFileBytes, validFilename(filename) else {
        fail("The export text or filename exceeds the supported limits.")
        return
      }
      // Create a unique directory; two exports must never overwrite one another.
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("getbible-export-\(UUID().uuidString)", isDirectory: true)
      exportDirectory = directory
      reading = true
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let url = directory.appendingPathComponent(filename)
          try text.write(to: url, atomically: true, encoding: .utf8)
          DispatchQueue.main.async {
            self.reading = false
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) {
              picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            } else {
              picker = UIDocumentPickerViewController(url: url, in: .exportToService)
            }
            picker.delegate = self
            self.present(picker)
          }
        } catch {
          DispatchQueue.main.async { self.fail("The temporary export file could not be created.") }
        }
      }
    case "pickTextFile":
      let limit = arguments?["maxBytes"] as? Int ?? maxFileBytes
      guard limit > 0, limit <= maxFileBytes else {
        fail("Invalid file size limit.")
        return
      }
      pendingLimit = limit
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.plain-text"], in: .import)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      present(picker)
    default:
      finish(FlutterMethodNotImplemented)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard pendingResult != nil, !reading else { return }
    if exportDirectory != nil {
      finish(!urls.isEmpty)
      return
    }
    guard let url = urls.first else {
      finish(nil)
      return
    }
    // Do not release the pending slot while the background stream is reading.
    reading = true
    let limit = pendingLimit
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let text = try self.readBoundedText(url: url, limit: limit)
        DispatchQueue.main.async { self.finish(text) }
      } catch {
        DispatchQueue.main.async { self.fail(error.localizedDescription) }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard !reading else { return }
    finish(exportDirectory != nil ? false : nil)
  }

  private func readBoundedText(url: URL, limit: Int) throws -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    if let size, size > limit { throw fileError("The selected file exceeds the size limit.") }
    guard let stream = InputStream(url: url) else {
      throw fileError("The selected backup could not be opened.")
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw fileError("The selected backup could not be read.") }
      if count == 0 { break }
      guard count <= limit - data.count else {
        throw fileError("The selected file exceeds the size limit.")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw fileError("The selected file is not valid UTF-8 text.")
    }
    return text
  }

  private func validFilename(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 200 && name != "." && name != ".." &&
      !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\" }
  }

  private func fileError(_ message: String) -> NSError {
    NSError(domain: "life.getbible.mobile.files", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func claim(_ result: @escaping FlutterResult) -> Bool {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "Another file operation is already open.", details: nil))
      return false
    }
    pendingResult = result
    return true
  }

  private func fail(_ message: String) {
    finish(FlutterError(code: "file_failed", message: message, details: nil))
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    reading = false
    if let directory = exportDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    exportDirectory = nil
    result?(value)
  }

  private func present(_ controller: UIViewController) {
    guard let presenter = topViewController(), presenter.view.window != nil,
      !presenter.isBeingDismissed else {
      fail("The file operation could not be opened. Please retry.")
      return
    }
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY, width: 1, height: 1)
    }
    presenter.present(controller, animated: true)
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }
}
