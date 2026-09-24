import XCTest
final class ProbeTests: XCTestCase {
 func testRecognitionSweep() throws {
  let app = XCUIApplication(); app.launch()
  let canvas = app.otherElements["canvas"]; XCTAssertTrue(canvas.waitForExistence(timeout: 15))
  for distance in [1, 4, 8, 9, 10, 12, 18, 19, 24, 36, 50] {
   app.buttons["reset"].tap()
   let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
   let end = start.withOffset(CGVector(dx: distance, dy: 0))
   start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
   let status = app.staticTexts["status"].label
   let data = try XCTUnwrap(status.data(using: .utf8))
   let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
   let began = try XCTUnwrap(value["beganDistance"] as? Double)
   if distance < 10 { XCTAssertEqual(began, -1) }
   else { XCTAssertGreaterThanOrEqual(began, 10) }
   print("NATIVE_PAN_PROBE distance=\(distance) \(status)")
  }
 }
}
