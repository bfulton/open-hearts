import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    keepKeyOutOfBackups(engineBridge)
  }

  /// Where the device's secret key is kept: a file in Application Support
  /// that no backup carries (lib/secret_store_io.dart, IosSecretStore).
  /// Dart reads and writes the file; this only says where the folder is
  /// and marks the file as not to be backed up, and says so only once
  /// the file itself does.
  private func keepKeyOutOfBackups(_ engineBridge: FlutterImplicitEngineBridge) {
    let channel = FlutterMethodChannel(
      name: "game.openhearts/identity",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "directory":
        do {
          let folder = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          result(folder.path)
        } catch {
          result(FlutterError(code: "directory", message: error.localizedDescription, details: nil))
        }
      case "excludeFromBackup":
        guard let path = call.arguments as? String else {
          result(FlutterError(code: "arguments", message: "a path is needed", details: nil))
          return
        }
        do {
          var file = URL(fileURLWithPath: path)
          var marked = URLResourceValues()
          marked.isExcludedFromBackup = true
          try file.setResourceValues(marked)
          // Asked of a URL made afresh, which cannot answer from what
          // the first one remembers.
          let said = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
          result(said.isExcludedFromBackup == true)
        } catch {
          result(FlutterError(code: "excludeFromBackup", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
