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
          // Background is always white (set in CalloutView.setupView) to match Android
          // Don't override backgroundColor here
          if let selected = args?["selected"] as? Bool {
              view.selected = selected
          }
          view.sizeToFit()
          return view
      }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
