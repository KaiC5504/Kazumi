import UIKit
import UserNotifications
import Flutter
import AVKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let channel = FlutterMethodChannel(
            name: "com.predidit.kazumi/intent",
            binaryMessenger: engineBridge.applicationRegistrar.messenger()
        )
        channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "openWithReferer" {
                guard let args = call.arguments else { return }
                if let myArgs = args as? [String: Any],
                   let url = myArgs["url"] as? String,
                   let referer = myArgs["referer"] as? String {
                    self?.openVideoWithReferer(url: url, referer: referer)
                }
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        let storageChannel = FlutterMethodChannel(
            name: "com.predidit.kazumi/storage",
            binaryMessenger: engineBridge.applicationRegistrar.messenger()
        )
        storageChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "getAvailableStorage" {
                do {
                    let attrs = try FileManager.default.attributesOfFileSystem(
                        forPath: NSHomeDirectory()
                    )
                    if let freeSize = attrs[.systemFreeSize] as? Int64 {
                        result(freeSize)
                    } else {
                        result(-1)
                    }
                } catch {
                    result(-1)
                }
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        let folderImportChannel = FlutterMethodChannel(
            name: "com.predidit.kazumi/folder_import",
            binaryMessenger: engineBridge.applicationRegistrar.messenger()
        )
        folderImportChannel.setMethodCallHandler { [weak self] call, result in
            self?.folderImportBridge.handle(call, result: result)
        }
    }

    private let folderImportBridge = FolderImportBridge()
    
    // TODO: ADD VLC SUPPORT
    // VLC can be downloaded from iOS App Store, but don't know how to build selectable app lists, while checking if it is installled.
    // VLC supports more video formats than AVPlayer but does not support referer while AVPlayer does
    private func openVideoWithReferer(url: String, referer: String) {
        guard let videoUrl = URL(string: url) else { return }

        let headers: [String: String] = [
            "Referer": referer,
        ]
        let asset = AVURLAsset(url: videoUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.videoGravity = AVLayerVideoGravity.resizeAspect

        // Use UIScene API instead of deprecated keyWindow
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }

        rootViewController.present(playerViewController, animated: true) {
            playerViewController.player?.play()
        }

//        guard let appURL = URL(string: "vlc-x-callback://x-callback-url/stream?url=" + url) else {
//            return
//        }
//        if UIApplication.shared.canOpenURL(appURL) && referer.isEmpty {
//            UIApplication.shared.open(appURL, options: [:], completionHandler: nil)
//        }
    }
}

/// Folder picks from the Files app only grant access through the
/// security-scoped URL the picker returns, which file_picker discards.
/// Reads go through NSFileCoordinator so iCloud Drive / OneDrive items that
/// are not on the device yet get downloaded first.
final class FolderImportBridge: NSObject, UIDocumentPickerDelegate {
    private var pendingResult: FlutterResult?
    private var accessedURL: URL?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickFolder":
            pickFolder(result)
        case "releaseFolder":
            releaseAccess()
            result(nil)
        case "coordinatedCopy":
            guard let args = call.arguments as? [String: Any],
                  let src = args["src"] as? String,
                  let dst = args["dst"] as? String else {
                result(FlutterError(code: "bad_args", message: nil, details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let error = FolderImportBridge.coordinatedCopy(src: src, dst: dst)
                DispatchQueue.main.async {
                    if let error = error {
                        result(FlutterError(code: "copy_failed",
                                            message: error.localizedDescription,
                                            details: nil))
                    } else {
                        result(nil)
                    }
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func pickFolder(_ result: @escaping FlutterResult) {
        if pendingResult != nil {
            result(FlutterError(code: "busy", message: nil, details: nil))
            return
        }
        releaseAccess()
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        guard let presenter = FolderImportBridge.topViewController() else {
            result(nil)
            return
        }
        pendingResult = result
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            finish(nil)
            return
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        finish(url.path)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    private func finish(_ value: Any?) {
        pendingResult?(value)
        pendingResult = nil
    }

    private func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private static func coordinatedCopy(src: String, dst: String) -> Error? {
        let srcURL = URL(fileURLWithPath: src)
        let dstURL = URL(fileURLWithPath: dst)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: srcURL, options: [],
                                       error: &coordinatorError) { readURL in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: dstURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: dstURL.path) {
                    try fm.removeItem(at: dstURL)
                }
                try fm.copyItem(at: readURL, to: dstURL)
            } catch {
                copyError = error
            }
        }
        return coordinatorError ?? copyError
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
