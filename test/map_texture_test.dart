import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

/// MapTexture talks to the host over one method channel, so the channel is
/// where its behaviour is observable without a device: what it asks for, when,
/// and whether it cleans up after itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/mapbox_maps_headless');
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'create':
          return 7;
        case 'ornaments':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpMap(WidgetTester tester,
      {ui.Size size = const ui.Size(320, 640)}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: const MapTexture(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  MethodCall? callNamed(List<MethodCall> calls, String name) {
    for (final call in calls) {
      if (call.method == name) return call;
    }
    return null;
  }

  testWidgets('creates the map at the size of its constraints', (tester) async {
    await pumpMap(tester, size: const ui.Size(300, 500));
    final create = callNamed(calls, 'create');
    expect(create, isNotNull);
    expect(create!.arguments['width'], 300.0);
    expect(create.arguments['height'], 500.0);
    await unmount(tester);
  });

  testWidgets('renders a Texture once the host returns an id', (tester) async {
    await pumpMap(tester);
    expect(find.byType(Texture), findsOneWidget);
    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 7);
    await unmount(tester);
  });

  testWidgets('every map gets its own channel suffix', (tester) async {
    await pumpMap(tester);
    final first = callNamed(calls, 'create')!.arguments['channelSuffix'] as int;
    calls.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpMap(tester);
    final second =
        callNamed(calls, 'create')!.arguments['channelSuffix'] as int;
    expect(second, isNot(first));
    await unmount(tester);
  });

  testWidgets('passes the style through', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MapTexture(styleUri: 'mapbox://styles/test')),
    );
    await tester.pump();
    await tester.pump();
    expect(callNamed(calls, 'create')!.arguments['styleUri'],
        'mapbox://styles/test');
    await unmount(tester);
  });

  testWidgets('resizes the host map when the constraints change',
      (tester) async {
    await pumpMap(tester, size: const ui.Size(300, 500));
    calls.clear();
    await pumpMap(tester, size: const ui.Size(200, 400));
    await tester.pump();
    final resize = callNamed(calls, 'resize');
    expect(resize, isNotNull);
    expect(resize!.arguments['width'], 200.0);
    expect(resize.arguments['height'], 400.0);
    await unmount(tester);
  });

  testWidgets('disposes the host map when it leaves the tree', (tester) async {
    await pumpMap(tester);
    calls.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    final dispose = callNamed(calls, 'dispose');
    expect(dispose, isNotNull);
    expect(dispose!.arguments['textureId'], 7);
  });

  testWidgets('a drag forwards panBegin, panUpdate and panEnd', (tester) async {
    await pumpMap(tester);
    calls.clear();
    await tester.drag(find.byType(Texture), const Offset(-40, -20));
    await tester.pumpAndSettle();
    expect(callNamed(calls, 'panBegin'), isNotNull);
    expect(callNamed(calls, 'panUpdate'), isNotNull);
    expect(callNamed(calls, 'panEnd'), isNotNull);
    await unmount(tester);
  });

  testWidgets('gesturesEnabled false forwards nothing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 320,
          height: 640,
          child: MapTexture(gesturesEnabled: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    calls.clear();
    await tester.drag(find.byType(Texture), const Offset(-40, -20));
    await tester.pumpAndSettle();
    expect(callNamed(calls, 'panBegin'), isNull);
    await unmount(tester);
  });
  testWidgets('touch down interrupts motion before a drag is recognised',
      (tester) async {
    await pumpMap(tester);
    calls.clear();
    final finger =
        await tester.startGesture(tester.getCenter(find.byType(Texture)));
    await tester.pump();
    expect(callNamed(calls, 'touchDown'), isNotNull);
    expect(callNamed(calls, 'panUpdate'), isNull);
    await finger.up();
    await unmount(tester);
  });

  testWidgets('a recognised swipe retains its initial displacement',
      (tester) async {
    await pumpMap(tester);
    calls.clear();
    final origin = tester.getCenter(find.byType(Texture));
    final finger = await tester.startGesture(origin);
    await finger.moveBy(const Offset(50, 0),
        timeStamp: const Duration(milliseconds: 16));
    await finger.moveBy(const Offset(10, 0),
        timeStamp: const Duration(milliseconds: 32));
    await tester.pump();
    final begin = callNamed(calls, 'panBegin')!;
    expect(begin.arguments['x'], 160.0);
    final updates = calls.where((c) => c.method == 'panUpdate').toList();
    expect(updates.last.arguments['x'], 220.0);
    await finger.up();
    await unmount(tester);
  });

  testWidgets('lifting one finger from a pinch never starts a fling',
      (tester) async {
    await pumpMap(tester);
    final center = tester.getCenter(find.byType(Texture));
    final first =
        await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    for (var i = 1; i <= 6; i++) {
      await second.moveBy(const Offset(10, 0),
          timeStamp: Duration(milliseconds: i * 10));
    }
    calls.clear();
    await second.up(timeStamp: const Duration(milliseconds: 65));
    await tester.pump();
    expect(callNamed(calls, 'fling'), isNull);
    await first.up();
    await unmount(tester);
  });

  testWidgets('pinch jitter under three degrees does not rotate the map',
      (tester) async {
    await pumpMap(tester);
    final center = tester.getCenter(find.byType(Texture));
    final first =
        await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    await second.moveTo(center + const Offset(90, 0),
        timeStamp: const Duration(milliseconds: 16));
    await second.moveTo(center + const Offset(95, 0),
        timeStamp: const Duration(milliseconds: 32));
    calls.clear();
    await second.moveTo(center + Offset(95, 145 * math.tan(2 * math.pi / 180)),
        timeStamp: const Duration(milliseconds: 48));
    await tester.pump();
    expect(callNamed(calls, 'rotateBy'), isNull);
    await second.up();
    await first.up();
    await unmount(tester);
  });

  testWidgets('small pinch updates are forwarded without one percent steps',
      (tester) async {
    await pumpMap(tester);
    final center = tester.getCenter(find.byType(Texture));
    final first =
        await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    await second.moveTo(center + const Offset(90, 0),
        timeStamp: const Duration(milliseconds: 16));
    await second.moveTo(center + const Offset(95, 0),
        timeStamp: const Duration(milliseconds: 32));
    calls.clear();
    await second.moveBy(const Offset(0.5, 0),
        timeStamp: const Duration(milliseconds: 48));
    await tester.pump();
    expect(callNamed(calls, 'zoomBy'), isNotNull, reason: calls.toString());
    await second.up();
    await first.up();
    await unmount(tester);
  });
  testWidgets('repeated quick swipes each move from their own touch origin',
      (tester) async {
    await pumpMap(tester);
    final origin = tester.getCenter(find.byType(Texture));
    for (var i = 0; i < 3; i++) {
      calls.clear();
      final finger = await tester.startGesture(origin, pointer: i + 1);
      await finger.moveBy(const Offset(50, 0),
          timeStamp: const Duration(milliseconds: 16));
      await finger.up(timeStamp: const Duration(milliseconds: 20));
      await tester.pump();
      expect(callNamed(calls, 'touchDown'), isNotNull);
      expect(callNamed(calls, 'panBegin')!.arguments['x'], 160.0);
      expect(callNamed(calls, 'panUpdate')!.arguments['x'], 210.0);
    }
    await unmount(tester);
  });

  testWidgets('an intentional twist rotates without applying discarded jitter',
      (tester) async {
    await pumpMap(tester);
    final center = tester.getCenter(find.byType(Texture));
    final first =
        await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    await second.moveTo(center + const Offset(90, 0),
        timeStamp: const Duration(milliseconds: 16));
    await second.moveTo(center + const Offset(95, 0),
        timeStamp: const Duration(milliseconds: 32));
    calls.clear();
    for (var degrees = 1; degrees <= 10; degrees++) {
      await second.moveTo(
          center + Offset(95, 145 * math.tan(degrees * math.pi / 180)),
          timeStamp: Duration(milliseconds: 32 + degrees * 16));
    }
    await tester.pump();
    final rotations = calls.where((c) => c.method == 'rotateBy').toList();
    expect(rotations, isNotEmpty);
    for (final call in rotations) {
      expect((call.arguments['radians'] as double).abs(),
          lessThan(2 * math.pi / 180));
    }
    await second.up();
    await first.up();
    await unmount(tester);
  });

  testWidgets('a single-finger flick still forwards release velocity',
      (tester) async {
    await pumpMap(tester);
    calls.clear();
    final finger =
        await tester.startGesture(tester.getCenter(find.byType(Texture)));
    for (var i = 1; i <= 6; i++) {
      await finger.moveBy(const Offset(10, 0),
          timeStamp: Duration(milliseconds: i * 10));
    }
    await finger.up(timeStamp: const Duration(milliseconds: 65));
    await tester.pump();
    expect(callNamed(calls, 'fling')!.arguments['vx'], greaterThan(500));
    await unmount(tester);
  });

  testWidgets('a cancelled drag does not fling', (tester) async {
    await pumpMap(tester);
    final finger =
        await tester.startGesture(tester.getCenter(find.byType(Texture)));
    for (var i = 1; i <= 6; i++) {
      await finger.moveBy(const Offset(10, 0),
          timeStamp: Duration(milliseconds: i * 10));
    }
    calls.clear();
    await finger.cancel(timeStamp: const Duration(milliseconds: 65));
    await tester.pump();
    expect(callNamed(calls, 'fling'), isNull);
    await unmount(tester);
  });

  testWidgets('controls above the map still receive taps', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      const Positioned.fill(child: MapTexture()),
      Center(
          child: TextButton(
              onPressed: () => tapped = true, child: const Text('Filter'))),
    ])));
    await tester.pump();
    await tester.pump();
    calls.clear();
    await tester.tap(find.text('Filter'));
    await tester.pump();
    expect(tapped, isTrue);
    expect(callNamed(calls, 'touchDown'), isNull);
    expect(callNamed(calls, 'tap'), isNull);
    await unmount(tester);
  });
  testWidgets('a paused drag release does not start a stale fling',
      (tester) async {
    await pumpMap(tester);
    final finger =
        await tester.startGesture(tester.getCenter(find.byType(Texture)));
    for (var i = 1; i <= 6; i++) {
      await finger.moveBy(const Offset(10, 0),
          timeStamp: Duration(milliseconds: i * 10));
    }
    calls.clear();
    await finger.up(timeStamp: const Duration(milliseconds: 100));
    await tester.pump();
    expect(callNamed(calls, 'fling'), isNull);
    await unmount(tester);
  });

  testWidgets('measure pan recognition distance without losing movement',
      (tester) async {
    await pumpMap(tester);
    final origin = tester.getCenter(find.byType(Texture));
    final recognised = <int>[];
    for (final distance in [1, 4, 8, 12, 18, 19, 24, 36, 37, 50]) {
      calls.clear();
      final finger = await tester.startGesture(origin);
      await finger.moveBy(Offset(distance.toDouble(), 0),
          timeStamp: const Duration(milliseconds: 16));
      await tester.pump();
      final update = callNamed(calls, 'panUpdate');
      if (update != null) {
        recognised.add(distance);
        expect(update.arguments['x'], 160.0 + distance);
      }
      await finger.cancel(timeStamp: const Duration(milliseconds: 20));
    }
    // A tap must remain possible; recognition must not discard a short swipe.
    expect(recognised, isNot(contains(1)));
    expect(recognised, contains(50));
    // ignore: avoid_print
    print('PAN_RECOGNITION_DISTANCES $recognised');
    await unmount(tester);
  });
  for (final entry
      in <int, int?>{100: null, 20: 3, 10: 5, 5: 7, 1: 15}.entries) {
    testWidgets('rotation gate at ${entry.key} ms per degree', (tester) async {
      await pumpMap(tester);
      final detector = tester.widget<GestureDetector>(find.descendant(
          of: find.byType(MapTexture), matching: find.byType(GestureDetector)));
      detector.onScaleStart!(ScaleStartDetails(
          focalPoint: const Offset(160, 320),
          pointerCount: 2,
          sourceTimeStamp: Duration.zero));
      calls.clear();
      int? firstRotation;
      for (var degrees = 1; degrees <= 20; degrees++) {
        detector.onScaleUpdate!(ScaleUpdateDetails(
            focalPoint: const Offset(160, 320),
            pointerCount: 2,
            rotation: degrees * math.pi / 180,
            sourceTimeStamp: Duration(milliseconds: entry.key * degrees)));
        if (firstRotation == null && callNamed(calls, 'rotateBy') != null) {
          firstRotation = degrees;
        }
      }
      if (entry.value == null) {
        expect(firstRotation, isNull);
      } else {
        // Degree/radian conversion may put an exact boundary one ulp below
        // its threshold; activation must occur within the next sample.
        expect(firstRotation, inInclusiveRange(entry.value!, entry.value! + 1));
      }
      detector.onScaleEnd!(ScaleEndDetails());
      await unmount(tester);
    });
  }
}
