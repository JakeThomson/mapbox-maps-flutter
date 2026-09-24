import UIKit
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
 var window: UIWindow?
 func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  let window = UIWindow(frame: UIScreen.main.bounds)
  window.rootViewController = ProbeController(); window.makeKeyAndVisible(); self.window = window; return true
 }
}
final class ProbeController: UIViewController {
 let status = UILabel(); let canvas = ProbeView()
 override func viewDidLoad() {
  super.viewDidLoad(); view.backgroundColor = .white
  status.frame = CGRect(x: 20, y: 70, width: 360, height: 100); status.numberOfLines = 0
  status.accessibilityIdentifier = "status"; view.addSubview(status)
  let reset = UIButton(type: .system); reset.frame = CGRect(x: 20, y: 175, width: 100, height: 44)
  reset.setTitle("Reset", for: .normal); reset.accessibilityIdentifier = "reset"
  reset.addTarget(self, action: #selector(clear), for: .touchUpInside); view.addSubview(reset)
  canvas.frame = CGRect(x: 10, y: 240, width: view.bounds.width - 20, height: 450)
  canvas.backgroundColor = .systemTeal; canvas.accessibilityIdentifier = "canvas"; canvas.isAccessibilityElement = true
  canvas.report = { [weak self] in self?.status.text = $0 }; view.addSubview(canvas); clear()
 }
 @objc func clear() { canvas.reset() }
}
final class ProbeView: UIView {
 var report: ((String) -> Void)?; var origin = CGPoint.zero; var began = -1.0; var changed = 0; var taps = 0; var maxMove = 0.0
 override init(frame: CGRect) {
  super.init(frame: frame)
  addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
  addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
 }
 required init?(coder: NSCoder) { fatalError() }
 func reset() { began = -1; changed = 0; taps = 0; maxMove = 0; emit() }
 func emit() { report?("{\"beganDistance\":\(began),\"changed\":\(changed),\"taps\":\(taps),\"maxMove\":\(maxMove)}") }
 override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { origin = touches.first!.location(in: self) }
 override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
  let p = touches.first!.location(in: self); maxMove = max(maxMove, hypot(p.x-origin.x,p.y-origin.y)); emit()
 }
 @objc func pan(_ recognizer: UIPanGestureRecognizer) {
  if recognizer.state == .began { let p = recognizer.location(in: self); began = hypot(p.x-origin.x,p.y-origin.y) }
  if recognizer.state == .changed { changed += 1 }; emit()
 }
 @objc func tap(_ recognizer: UITapGestureRecognizer) { taps += 1; emit() }
}
