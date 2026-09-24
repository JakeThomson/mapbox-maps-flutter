# Texture gesture regression harness

Run from `example/` on an iOS simulator with its normal native Mapbox setup.
Put `MAPBOX_ACCESS_TOKEN` in a local JSON define file; do not commit credentials.

```sh
flutter pub get
flutter run -d <simulator-id> \
  -t integration_test/map_texture_gestures_test.dart \
  --dart-define-from-file=/absolute/path/to/local-defines.json \
  --dart-define=GESTURE_VARIANT=fixed
```

The harness forwards scripted Flutter pointer events through MapTexture and
reads camera state back from native Mapbox. MAP_GESTURE_RESULT contains the
measurements; the fixed run asserts expected camera behavior. GESTURE_VARIANT
labels the run, not the implementation. To compare, use an isolated checkout
with lib/src/map_texture.dart from 304d2d2, labelled baseline.

## Root cause and native activation comparison

Jake's original GestureDetector combines tap and scale recognition. Flutter's
tap recognizer yields after its 18-point tolerance, allowing scale to win the
arena. The original panBegin then used the recognition location as its origin,
discarding the movement before recognition. A one-move swipe could therefore
finish without moving the camera at all.

Preserving that displacement solved dropped swipes but left the activation
boundary at 19 logical pixels in our integer sweep. A separate native UIKit
XCTest probe (../native_gesture_probe) found no pan through 9 points and pan
recognition at 10, using the default UIPanGestureRecognizer also constructed by
Mapbox's native dependency provider.

The texture now uses a ScaleGestureRecognizer subclass that requests normal
arena acceptance at 10 points for a single touch. Pinch/rotation keep Flutter's
scale machinery. Small movements still resolve as taps; an ancestor that wins
the arena still prevents the map from panning. This is scoped to the texture,
not a global Flutter gesture-setting change.

## Recorded camera comparison

map_texture_gestures_results.json contains original, previous-patch and current
results from iPhone 17 / iOS 26.5, Flutter 3.44.7 (84fc5cbb22). The Sortd host ran
the same harness body with its own token loading and Material import. All runs
used the updated native host and zero camera pitch.

| Scenario | Original | Current patch |
| --- | --- | --- |
| Single move through 9 points | No movement | No movement |
| Single move at 10, 12, 18 points | No movement (12/18 measured) | Camera moves |
| Single move at 19/24/36/37/50 points | No movement | Camera moves |
| Three repeated 50-point swipes | 0/3 move | 3/3 move |
| Touch down during fling | Continued drift | Zero measured drift |
| Lift one finger after pinch | Unwanted drift | Zero measured drift |
| Incidental 2-degree twist | Rotates 2 degrees | No rotation |
| Intentional 10-degree twist | Rotates 10 degrees | Rotates 8 degrees after gate |
| Sub-percent pinch update | No zoom response | +0.005 zoom levels |
| Pause 40 ms, then release | No drift in this live run | No drift |
| Overlay control | Receives tap | Receives tap |

JSON center deltas are summed absolute longitude/latitude differences, not
meters or screen pixels. The original sweep omitted 9/10-point samples; its
recognizer path and the 12/18-point samples establish the delayed activation.

## Native source audit and test coverage

Compared against installed Mapbox iOS 11.31.0:
- RotateGestureHandler: ported its 3/5/7/15-degree angle/speed gates, with tests
  for each speed band and deliberately slow rotation.
- PanGestureHandler: added the 1/30-second release pause cutoff. A deterministic
  40 ms pause produced a stale fling before the fix; both live runs happened
  not to drift, so the unit regression is the evidence for that case.
- PanGestureHandler: moved the fling anchor to at least 3/4 of the view height.
- GestureDecelerationCameraAnimator: existing per-frame displacement,
  per-millisecond decay factor and 35-point/second stopping rule match its code.

Run flutter test at the package root. Coverage includes activation, small tap
movement, an ancestor winning the arena, overlay taps, double tap, quick zoom,
rotation, cancellation, paused release and multi-touch fling suppression.
The native probe measures UIKit recognition; the map harness measures texture
camera behavior. Neither is an App Store build comparison. The pitched fling
anchor is source-aligned and compiled, not measured against a native map here.
