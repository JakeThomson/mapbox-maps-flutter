# Texture gesture regression harness

Run from `example/` on an iOS simulator with the example app's normal native
Mapbox setup. Put `MAPBOX_ACCESS_TOKEN` in a local JSON define file (do not commit
credentials), then run:

```sh
flutter pub get
flutter run -d <simulator-id> \
  -t integration_test/map_texture_gestures_test.dart \
  --dart-define-from-file=/absolute/path/to/local-defines.json \
  --dart-define=GESTURE_VARIANT=fixed
```

The harness forwards scripted Flutter pointer events through `MapTexture` and
reads camera state back from native Mapbox. `MAP_GESTURE_RESULT` contains the
measurements. The fixed run also asserts the expected camera behavior.
`GESTURE_VARIANT` labels the run; it does not select another implementation.
For a comparison, run the same harness in an isolated checkout with
`lib/src/map_texture.dart` from `304d2d2`, labelled `baseline`.

## Recorded comparison

`map_texture_gestures_results.json` records iPhone 17 / iOS 26.5 results with
Flutter 3.44.7 (framework 84fc5cbb22). These runs used the Sortd host app and the
same harness body, with only token loading and the Material import adapted to
that host. Both runs used the updated native host; the comparison isolates the
original versus patched Dart gesture path. Camera pitch was zero.

| Scenario | Original Dart path | Patched path |
| --- | --- | --- |
| Single move at 1, 4, 8, 12, 18 logical pixels | No movement | No movement |
| Single move at 19, 24, 36, 37, 50 pixels | No movement | Full displacement forwarded |
| Three 50-pixel single-move swipes | 0/3 move | 3/3 move |
| Touch down during a fling | Continued drift | Zero measured drift |
| Lift one finger after a pinch | Unwanted drift | Zero measured drift |
| Incidental 2-degree twist | 2-degree rotation | No rotation |
| Intentional 10-degree twist | 10-degree rotation | 8-degree rotation after the gate |
| Sub-percent pinch update | No zoom change | +0.005 zoom levels |
| Pause 40 ms, then release | Zero drift in this live run | Zero drift |
| Overlaid button | Receives tap | Receives tap |

Center deltas in the JSON are summed absolute longitude/latitude differences,
not screen pixels or meters. The 19-pixel recognition result is specific to the
recorded Flutter configuration: it reflects the tap/scale gesture arena, not
just the standalone scale recognizer's pan-slop constant. The fix stops motion
at touch-down and preserves displacement when a drag wins; it keeps tap
recognition intact.

## Native-source audit

Compared with the installed Mapbox iOS 11.31.0 sources:

- `RotateGestureHandler`: ported the 3/5/7/15-degree angle gates and angular
  speed conditions. Unit cases cover each speed band and slow rotation.
- `PanGestureHandler`: added the native 1/30-second release timeout. A synthetic
  40 ms pause still produced a fling request before this addition, and does not
  afterward. The live baseline happened not to drift, so the deterministic test
  is the evidence for this case.
- `PanGestureHandler`: moved the fling anchor to at least 3/4 of the view height,
  matching its horizon-sensitivity mitigation.
- `GestureDecelerationCameraAnimator`: the existing host already uses the same
  per-frame displacement, per-millisecond normal deceleration factor and
  35-point/second stop condition. That decay equation was not retuned.

Run `flutter test` at the package root for the 52-test suite, including real
Flutter gesture recognition, release/cancellation cases and rotation gates.
The harness compares the two texture implementations. It does not inject UIKit
touches into the App Store build or establish identical device feel; the native
anchor change is source-aligned and simulator-compiled, not a pitched-map
before/after measurement.
