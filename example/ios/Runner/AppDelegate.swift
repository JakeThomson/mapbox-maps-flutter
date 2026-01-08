import UIKit
import mapbox_maps_flutter
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      GeneratedPluginRegistrant.register(with: self)
      
      ViewAnnotationRegistry.shared.register(viewIdentifier: "custom_callout") { args in
          let view = CalloutView()
          if let emoji = args?["callout_emoji"] as? String {
              view.emoji = emoji
          }
          if let label = args?["callout_label"] as? String {
              view.label = label
          }
          if let colorValue = args?["backgroundColor"] as? Int {
              view.backgroundColor = UIColor(rgb: colorValue)
          }
          view.sizeToFit()
          return view
      }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
