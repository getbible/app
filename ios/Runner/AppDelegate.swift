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
  private var pendingResult: FlutterResult?
  private var exportedURL: URL?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "shareText":
      let text = arguments?["text"] as? String ?? ""
      let filename = arguments?["filename"] as? String
      let subject = arguments?["subject"] as? String ?? "getBible.Life"
      var items: [Any] = [text]
      if let filename, !filename.isEmpty,
         let url = temporaryFile(text: text, filename: filename) {
        items = [url]
      }
      let controller = UIActivityViewController(
        activityItems: items,
        applicationActivities: nil
      )
      controller.setValue(subject, forKey: "subject")
      present(controller)
      result(nil)
    case "saveText":
      guard claim(result) else { return }
      let text = arguments?["text"] as? String ?? ""
      let filename = arguments?["filename"] as? String ?? "getBible-Life.txt"
      guard let url = temporaryFile(text: text, filename: filename) else {
        finish(FlutterError(
          code: "save_failed",
          message: "The temporary export file could not be created.",
          details: nil
        ))
        return
      }
      exportedURL = url
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      } else {
        // Keep export-as-copy behavior on the supported iOS 13 deployment target.
        picker = UIDocumentPickerViewController(url: url, in: .exportToService)
      }
      picker.delegate = self
      present(picker)
    case "pickTextFile":
      guard claim(result) else { return }
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forOpeningContentTypes: [.json, .plainText],
          asCopy: true
        )
      } else {
        // Import creates a local copy, matching the modern picker's asCopy mode.
        picker = UIDocumentPickerViewController(
          documentTypes: ["public.json", "public.plain-text"],
          in: .import
        )
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      present(picker)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    if exportedURL != nil {
      cleanupExport()
      result(true)
      return
    }
    guard let url = urls.first else {
      result(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let text = try String(contentsOf: url, encoding: .utf8)
        DispatchQueue.main.async { result(text) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "open_failed",
            message: "The selected backup could not be read as UTF-8 text.",
            details: error.localizedDescription
          ))
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let wasExport = exportedURL != nil
    cleanupExport()
    finish(wasExport ? false : nil)
  }

  private func claim(_ result: @escaping FlutterResult) -> Bool {
    guard pendingResult == nil else {
      result(FlutterError(
        code: "busy",
        message: "Another file operation is already open.",
        details: nil
      ))
      return false
    }
    pendingResult = result
    return true
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }

  private func temporaryFile(text: String, filename: String) -> URL? {
    let safeName = filename.replacingOccurrences(of: "/", with: "-")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  private func cleanupExport() {
    if let exportedURL {
      try? FileManager.default.removeItem(at: exportedURL)
    }
    exportedURL = nil
  }

  private func present(_ controller: UIViewController) {
    guard let presenter = topViewController() else { return }
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 1,
        height: 1
      )
    }
    presenter.present(controller, animated: true)
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}
