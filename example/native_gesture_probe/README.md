# UIKit pan activation probe

This isolated UIKit app measures default UIPanGestureRecognizer activation with
an ordinary competing UITapGestureRecognizer. The native Mapbox SDK constructs
a default UIPanGestureRecognizer in MapViewDependencyProvider; this probe isolates
that recognizer rather than loading map tiles or Flutter.

Requires Xcode and the `xcodeproj` Ruby gem (included with CocoaPods):

```sh
ruby generate.rb
xcodebuild test -project GestureProbe.xcodeproj -scheme GestureProbe \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath build -parallel-testing-enabled NO
```

The UI test sends actual simulator touches with XCTest and reads the distance
from touch-down when the recognizer reports `.began`. It asserts no pan through
9 points and a pan at 10 points and above. `results.json` records a passing run
on iPhone 17 / iOS 26.5. Larger drags report their first available event beyond
the boundary (12–13.3 points in this run), not a different threshold.

This establishes recognizer activation for this OS and input sequence, not full
Mapbox camera parity or a guarantee about every UIKit/device configuration.
