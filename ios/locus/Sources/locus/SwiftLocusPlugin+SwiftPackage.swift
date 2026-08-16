#if LOCUS_SWIFT_PACKAGE
import Flutter
import Foundation

/// Flutter's Swift package registrant resolves the plugin by the `pluginClass`
/// name in pubspec.yaml. CocoaPods provides that name through LocusPlugin.m;
/// SwiftPM excludes the mixed-language forwarding shim and exposes this
/// Objective-C-compatible adapter from the generated Swift module header.
@objc(LocusPlugin)
public final class SwiftPackageLocusPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    SwiftLocusPlugin.register(with: registrar)
  }
}
#endif
