// Real Mapbox camera with deterministic Flutter touches.
// See map_texture_gestures.md for simulator setup and comparison procedure.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  LiveTestWidgetsFlutterBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  const variant = String.fromEnvironment(
    'GESTURE_VARIANT',
    defaultValue: 'fixed',
  );
  const channel = MethodChannel('plugins.flutter.io/mapbox_maps_headless');
  testWidgets(
    'real Mapbox texture gesture comparison: $variant',
    (tester) async {
      const token = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
      expect(token, isNotEmpty,
          reason: 'Pass MAPBOX_ACCESS_TOKEN via --dart-define-from-file.');
      MapboxOptions.setAccessToken(token);
      MapboxMap? map;
      var filterTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  const Text(
                    'ALBO-3426 · $variant',
                    style: TextStyle(fontSize: 22),
                  ),
                  const Text('Actual Mapbox camera / scripted touch sequences'),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: MapTexture(
                            onMapCreated: (value) => map = value,
                            styleUri: MapboxStyles.MAPBOX_STREETS,
                            cameraOptions: CameraOptions(
                              center: Point(
                                coordinates: Position(-0.1276, 51.5072),
                              ),
                              zoom: 12,
                              bearing: 0,
                              pitch: 0,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 16,
                          left: 16,
                          child: ElevatedButton(
                            onPressed: () => filterTaps++,
                            child: const Text('Filter control'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 200 && map == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(map, isNotNull);
      await map!.gestures.updateSettings(GesturesSettings(pitchEnabled: false));
      await tester.pump(const Duration(seconds: 2));
      final textureFinder = find.byType(Texture);
      final textureId = tester.widget<Texture>(textureFinder).textureId;
      final origin = tester.getCenter(textureFinder);
      final localOrigin = origin - tester.getTopLeft(textureFinder);
      var clock = const Duration(seconds: 1);
      final results = <String, dynamic>{'variant': variant};

      Future<void> settle([int ms = 80]) =>
          tester.pump(Duration(milliseconds: ms));
      Future<CameraState> camera() => map!.getCameraState();
      Future<void> reset() async {
        await channel.invokeMethod<void>('panBegin', {
          'textureId': textureId,
          'x': localOrigin.dx,
          'y': localOrigin.dy,
        });
        await channel.invokeMethod<void>('panEnd', {'textureId': textureId});
        await map!.setCamera(
          CameraOptions(
            center: Point(coordinates: Position(-0.1276, 51.5072)),
            zoom: 12,
            bearing: 0,
            pitch: 0,
          ),
        );
        await settle();
        clock += const Duration(seconds: 1);
      }

      double centerDelta(CameraState a, CameraState b) =>
          (a.center.coordinates.lng - b.center.coordinates.lng)
              .abs()
              .toDouble() +
          (a.center.coordinates.lat - b.center.coordinates.lat)
              .abs()
              .toDouble();
      Future<void> move(TestGesture finger, Offset to, int ms) async {
        clock += Duration(milliseconds: ms);
        await finger.moveTo(to, timeStamp: clock);
        await settle(ms);
      }

      Future<TestGesture> down(Offset at, int pointer) async {
        final finger = await tester.createGesture(pointer: pointer);
        await finger.down(at, timeStamp: clock);
        return finger;
      }

      // Measure the actual activation boundary rather than inferring it from
      // Flutter's constants (the tap/scale arena affects recognition too).
      final activation = <String, double>{};
      for (final distance in [1, 4, 8, 12, 18, 19, 24, 36, 37, 50]) {
        await reset();
        final before = await camera();
        final finger = await down(origin, 1);
        await move(finger, origin + Offset(distance.toDouble(), 0), 16);
        activation['$distance'] = centerDelta(before, await camera());
        await finger.cancel(timeStamp: clock);
      }
      results['activation_distance_center_delta'] = activation;

      // The native handler suppresses deceleration after a 1/30 s pause.
      await reset();
      final paused = await down(origin, 1);
      for (var i = 1; i <= 8; i++) {
        await move(paused, origin + Offset(i * 10, 0), 10);
      }
      await settle(40);
      clock += const Duration(milliseconds: 40);
      await paused.up(timeStamp: clock);
      final pausedStart = await camera();
      await settle(250);
      results['paused_release_drift'] = centerDelta(
        pausedStart,
        await camera(),
      );

      // A quick single-move swipe must not lose the displacement crossing slop.
      await reset();
      final repeated = <double>[];
      for (var i = 0; i < 3; i++) {
        final before = await camera();
        final finger = await down(origin, 1);
        await move(finger, origin + const Offset(50, 0), 16);
        final after = await camera();
        repeated.add(centerDelta(before, after));
        await finger.up(timeStamp: clock + const Duration(milliseconds: 1));
        await reset();
      }
      results['single_move_swipe_center_delta'] = repeated;

      // Start a real native fling, touch down, then hold without moving.
      await reset();
      final flick = await down(origin, 1);
      for (var i = 1; i <= 8; i++) {
        await move(flick, origin + Offset(i * 10, 0), 10);
      }
      await flick.up(timeStamp: clock + const Duration(milliseconds: 1));
      await settle(50);
      clock += const Duration(milliseconds: 100);
      final hold = await down(origin, 2);
      await settle(30);
      final heldStart = await camera();
      await settle(250);
      final heldEnd = await camera();
      results['touch_down_drift'] = centerDelta(heldStart, heldEnd);
      await hold.cancel(timeStamp: clock + const Duration(milliseconds: 300));

      // Lift the moving finger after a pinch while the other remains down.
      await reset();
      var first = await down(origin - const Offset(50, 0), 1);
      var second = await down(origin + const Offset(50, 0), 2);
      for (var i = 1; i <= 8; i++) {
        await move(second, origin + Offset(50 + i * 10, 0), 10);
      }
      await second.up(timeStamp: clock + const Duration(milliseconds: 1));
      await settle(30);
      final releaseStart = await camera();
      await settle(250);
      final releaseEnd = await camera();
      results['pinch_release_drift'] = centerDelta(releaseStart, releaseEnd);
      await first.up(timeStamp: clock + const Duration(milliseconds: 300));

      // Pinch then apply a two-degree incidental twist.
      await reset();
      first = await down(origin - const Offset(50, 0), 1);
      second = await down(origin + const Offset(50, 0), 2);
      await move(second, origin + const Offset(90, 0), 16);
      await move(second, origin + const Offset(95, 0), 16);
      final beforeJitter = await camera();
      await move(
        second,
        origin + Offset(95, 145 * math.tan(2 * math.pi / 180)),
        32,
      );
      final afterJitter = await camera();
      results['incidental_rotation_degrees'] =
          ((afterJitter.bearing - beforeJitter.bearing + 180) % 360 - 180)
              .abs();
      await second.up(timeStamp: clock);
      await first.up(timeStamp: clock);

      // Deliberate rotation must engage; suppressing all rotation is not a fix.
      await reset();
      first = await down(origin - const Offset(50, 0), 1);
      second = await down(origin + const Offset(50, 0), 2);
      await move(second, origin + const Offset(90, 0), 16);
      await move(second, origin + const Offset(95, 0), 16);
      final twistStart = await camera();
      for (var degrees = 1; degrees <= 10; degrees++) {
        await move(
          second,
          origin + Offset(95, 145 * math.tan(degrees * math.pi / 180)),
          16,
        );
      }
      final twistEnd = await camera();
      results['intentional_rotation_degrees'] =
          ((twistEnd.bearing - twistStart.bearing + 180) % 360 - 180).abs();
      await second.up(timeStamp: clock);
      await first.up(timeStamp: clock);

      // A sub-percent pinch change should still advance the zoom smoothly.
      await reset();
      first = await down(origin - const Offset(50, 0), 1);
      second = await down(origin + const Offset(50, 0), 2);
      await move(second, origin + const Offset(90, 0), 16);
      await move(second, origin + const Offset(95, 0), 16);
      final beforeZoom = await camera();
      await move(second, origin + const Offset(95.5, 0), 16);
      final afterZoom = await camera();
      results['small_pinch_zoom_delta'] = afterZoom.zoom - beforeZoom.zoom;
      await second.up(timeStamp: clock);
      await first.up(timeStamp: clock);

      await tester.tap(find.text('Filter control'));
      await settle();
      results['filter_taps'] = filterTaps;
      // Structured output has no credentials or user data.
      // ignore: avoid_print
      print('MAP_GESTURE_RESULT ${jsonEncode(results)}');
      await reset();
      await tester.pump(const Duration(seconds: 2));
      if (variant == 'fixed') {
        expect(repeated.every((value) => value > 0.00001), isTrue);
        expect(results['touch_down_drift'], lessThan(0.000001));
        expect(results['pinch_release_drift'], lessThan(0.000001));
        expect(results['incidental_rotation_degrees'], lessThan(0.1));
        expect(results['small_pinch_zoom_delta'], greaterThan(0));
        expect(filterTaps, 1);
        expect(results['paused_release_drift'], lessThan(0.000001));
        expect(results['intentional_rotation_degrees'], greaterThan(1));
        expect(activation['18'], lessThan(0.000001));
        expect(activation['19'], greaterThan(0.00001));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
