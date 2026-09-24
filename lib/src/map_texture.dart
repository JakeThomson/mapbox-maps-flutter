part of '../mapbox_maps_flutter.dart';

/// A map that is not a platform view.
///
/// [MapWidget] puts a `UiKitView` in the tree. UIKit composites that view, not
/// flutter, so nothing painted above it can read it: backdrop filters, shaders
/// and `toImageSync` captures all come back empty. Android avoids this by
/// rendering the map into a `TextureView`.
///
/// [MapTexture] is that mode for ios. The map is created without a platform
/// view and its frames go to a flutter texture, so the widget tree contains a
/// [Texture] and composites like any other widget.
///
/// The trade is that flutter owns the hit test, so gestures are forwarded
/// rather than handled by the map's own recognisers. Pan, pinch, rotation and
/// quick zoom are forwarded to the native host.
class MapTexture extends StatefulWidget {
  const MapTexture({
    super.key,
    this.styleUri,
    this.onMapCreated,
    this.gesturesEnabled = true,
    this.cameraOptions,
    this.onStyleLoadedListener,
    this.onCameraChangeListener,
    this.onMapIdleListener,
    this.onMapLoadedListener,
    this.onTapListener,
    this.onLongTapListener,
  });

  /// Style to load, defaults to the sdk's standard style.
  final String? styleUri;

  /// Called once with a [MapboxMap] bound to this map. Same api surface as the
  /// one [MapWidget] hands back.
  final void Function(MapboxMap map)? onMapCreated;

  /// Forward pan and pinch to the map. Turn off to drive the camera yourself.
  final bool gesturesEnabled;

  /// Where the camera starts. Applied in the host's init options, so the
  /// first frame the texture shows is already there rather than the sdk's
  /// default view.
  final CameraOptions? cameraOptions;

  /// The listeners [MapWidget] takes, delivered over the same events channel.
  /// The host subscribes at creation, so a style served from the cache cannot
  /// finish loading before anyone is listening.
  final OnStyleLoadedListener? onStyleLoadedListener;
  final OnCameraChangeListener? onCameraChangeListener;
  final OnMapIdleListener? onMapIdleListener;
  final OnMapLoadedListener? onMapLoadedListener;

  /// A tap on the map, resolved through the map's projection the way
  /// [MapWidget.onTapListener] is.
  ///
  /// Interactions registered with [MapboxMap.addInteraction] fire too: the
  /// host dispatches them itself, since the sdk's own tap recogniser never
  /// sees a touch here.
  final OnMapTapListener? onTapListener;

  /// A long press, delivered the same way.
  final OnMapLongTapListener? onLongTapListener;

  @override
  State<MapTexture> createState() => _MapTextureState();
}

class _MapTextureState extends State<MapTexture> {
  static const _channel =
      MethodChannel('plugins.flutter.io/mapbox_maps_headless');
  static int _nextSuffix = 90000;

  int? _textureId;
  MapboxMap? _map;
  _MapEvents? _events;
  ui.Size? _size;
  bool _creating = false;
  double _lastRotation = 0;
  double _discardedRotation = 0;
  bool _rotating = false;
  Duration? _rotationTimestamp;
  final Map<int, Offset> _pointers = {};
  Offset? _panOrigin;
  bool _hadMultiplePointers = false;
  bool _cancelled = false;
  Duration? _lastPanMoveTimestamp;
  Duration? _releaseTimestamp;
  double _lastScale = 1;
  Offset? _lastFocal;
  Offset? _lastTap;
  DateTime? _lastTapAt;

  /// Set while a quick zoom is running: where it started, and the last y.
  Offset? _quickZoomAnchor;
  double? _quickZoomY;

  /// Where the touch now down landed, when it was the second of a double
  /// tap. A quick zoom measures from here, not from where the scale
  /// recogniser won, which is a slop's distance further on.
  Offset? _secondTouchDown;
  Timer? _longPress;

  @override
  void didUpdateWidget(MapTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateEventListeners();
    _events?.updateSubscriptions();
  }

  /// Events that arrived before [MapTexture.onMapCreated] ran.
  ///
  /// The host subscribes at creation, so a cached style can finish loading
  /// before `create` has even returned — before the app has been handed its
  /// map. Delivered then, the app's style-loaded handler runs against a null
  /// map, adds no layers, and the style never loads again to give it a
  /// second chance. The platform view calls onMapCreated first; this keeps
  /// that order. Null once the map has been handed over.
  List<VoidCallback>? _earlyEvents = [];

  void _deliver(VoidCallback event) {
    final early = _earlyEvents;
    if (early != null) {
      early.add(event);
    } else {
      event();
    }
  }

  void _updateEventListeners() {
    final events = _events;
    if (events == null) return;
    // Null stays null: which listeners exist decides what the host sends.
    final onStyleLoaded = widget.onStyleLoadedListener;
    final onCameraChange = widget.onCameraChangeListener;
    final onMapIdle = widget.onMapIdleListener;
    final onMapLoaded = widget.onMapLoadedListener;
    events._onStyleLoadedListener = onStyleLoaded == null
        ? null
        : (data) => _deliver(() => onStyleLoaded(data));
    events._onCameraChangeListener = onCameraChange == null
        ? null
        : (data) => _deliver(() => onCameraChange(data));
    events._onMapIdleListener =
        onMapIdle == null ? null : (data) => _deliver(() => onMapIdle(data));
    events._onMapLoadedListener = onMapLoaded == null
        ? null
        : (data) => _deliver(() => onMapLoaded(data));
  }

  @override
  void dispose() {
    _longPress?.cancel();
    _events?.dispose();
    final id = _textureId;
    if (id != null) {
      _channel.invokeMethod<void>('dispose', {'textureId': id});
    }
    super.dispose();
  }

  Future<void> _create(ui.Size size) async {
    _creating = true;
    final suffix = _nextSuffix++;
    // the events channel is per suffix and the host subscribes at creation,
    // exactly as the platform view does, so nothing can fire unheard.
    final events = _MapEvents(channelSuffix: suffix.toString());
    _events = events;
    _updateEventListeners();
    final eventTypes = events.eventTypes;
    events.subscribedEventTypes = eventTypes;
    final camera = widget.cameraOptions;
    final id = await _channel.invokeMethod<int>('create', {
      'width': size.width,
      'height': size.height,
      'styleUri': widget.styleUri,
      'channelSuffix': suffix,
      'eventTypes': eventTypes.map((e) => e.index).toList(),
      if (camera != null)
        'camera': {
          'lng': camera.center?.coordinates.lng.toDouble(),
          'lat': camera.center?.coordinates.lat.toDouble(),
          'zoom': camera.zoom,
          'bearing': camera.bearing,
          'pitch': camera.pitch,
        },
    });
    if (!mounted || id == null || id < 0) return;
    setState(() {
      _textureId = id;
      _size = size;
    });
    final map = MapboxMap.headless(channelSuffix: suffix);
    _map = map;
    widget.onMapCreated?.call(map);
    final early = _earlyEvents;
    _earlyEvents = null;
    for (final event in early ?? const <VoidCallback>[]) {
      event();
    }
    // NO repaint timer. Every camera change renders on its own, and a 30fps
    // pump with the map standing still is a perpetual animation: under glass
    // it redraws every surface on the screen thirty times a second. One frame
    // is drawn after a resize instead, where flutter genuinely knows better
    // than the map that something moved.
  }

  void _resize(ui.Size size) {
    _size = size;
    // resize repaints on the host, so the texture never shows the old size
    // stretched to the new one.
    _channel.invokeMethod<void>('resize', {
      'textureId': _textureId,
      'width': size.width,
      'height': size.height,
    });
  }

  void _send(String method, [Map<String, Object?> extra = const {}]) {
    _channel.invokeMethod<void>(method, {'textureId': _textureId, ...extra});
  }

  /// Double tap and long press are detected here rather than handed to
  /// `GestureDetector`.
  ///
  /// Its recognisers for those hold the gesture arena open while they wait,
  /// and this detector is full-screen and opaque, so everything floating over
  /// the map — the recentre button, the search pill, the filter chips — ends
  /// up in the same arena and stops responding to taps. Two timers here cost
  /// nothing and leave those controls alone.
  static const _doubleTapWindow = Duration(milliseconds: 300);
  static const _doubleTapSlop = 40.0;
  static const _longPressDelay = Duration(milliseconds: 500);

  /// Points of vertical drag per zoom level in a quick zoom, the sdk's own.
  static const _quickZoomPointsPerLevel = 75.0;

  /// Whether a touch at [position] is the second of a double tap.
  bool _isSecondTap(Offset position) {
    final previous = _lastTap;
    final at = _lastTapAt;
    return previous != null &&
        at != null &&
        DateTime.now().difference(at) < _doubleTapWindow &&
        (previous - position).distance < _doubleTapSlop;
  }

  Future<void> _tap(Offset position, {bool long = false}) async {
    _longPress?.cancel();
    if (!long) {
      final isSecond = _isSecondTap(position);
      _lastTap = position;
      _lastTapAt = DateTime.now();
      if (isSecond) {
        _lastTap = null;
        _lastTapAt = null;
        _send('zoomStep', {'delta': 1.0, 'x': position.dx, 'y': position.dy});
        return;
      }
    }
    final args = {'textureId': _textureId, 'x': position.dx, 'y': position.dy};
    if (long) {
      _channel.invokeMethod<void>('longPress', args);
    } else {
      // True when a view annotation took the tap. On the platform view the
      // map's own tap waits for that recogniser to fail, so a pin tap is
      // never also a map tap; this keeps it that way.
      final taken = await _channel.invokeMethod<bool>('tap', args) ?? false;
      if (taken) return;
    }
    final listener = long ? widget.onLongTapListener : widget.onTapListener;
    final map = _map;
    if (listener == null || map == null) return;
    final touch = ScreenCoordinate(x: position.dx, y: position.dy);
    final point = await map.coordinateForPixel(touch);
    if (!mounted) return;
    listener(MapContentGestureContext(
      touchPosition: touch,
      point: point,
      gestureState: GestureState.ended,
    ));
  }

  void _pointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _hadMultiplePointers = false;
      _cancelled = false;
      _lastPanMoveTimestamp = null;
      _releaseTimestamp = null;
    }
    _pointers[event.pointer] = event.localPosition;
    _hadMultiplePointers |= _pointers.length > 1;
    _panOrigin = _pointerCenter;
    _secondTouchDown =
        _pointers.length == 1 && _isSecondTap(event.localPosition)
            ? event.localPosition
            : null;
    // Interrupt both our deceleration and SDK camera animations immediately;
    // waiting for onScaleStart lets the map run away beneath a resting finger.
    _send('touchDown');
  }

  Offset? get _pointerCenter => _pointers.isEmpty
      ? null
      : _pointers.values.reduce((a, b) => a + b) / _pointers.length.toDouble();

  void _pointerMove(PointerMoveEvent event) {
    if (event.delta != Offset.zero) {
      _lastPanMoveTimestamp = event.timeStamp;
    }
    _pointers[event.pointer] = event.localPosition;
  }

  void _pointerUp(PointerEvent event) {
    _releaseTimestamp = event.timeStamp;
    _cancelled |= event is PointerCancelEvent;
    _pointers.remove(event.pointer);
    // A change in the finger count starts a new scale segment. Rebase its
    // pan origin so lifting or adding a finger cannot jump the camera.
    _panOrigin = _pointerCenter;
  }

  void _rotate(ScaleUpdateDetails details) {
    final timestamp = details.sourceTimeStamp;
    final previous = _rotationTimestamp;
    // atan2 can cross its +/- pi boundary while the fingers barely move.
    final rawDelta = details.rotation - _lastRotation;
    final delta = math.atan2(math.sin(rawDelta), math.cos(rawDelta));
    _lastRotation = details.rotation;
    _rotationTimestamp = timestamp;
    if (details.pointerCount < 2) return;
    if (!_rotating) {
      _discardedRotation += delta.abs();
      if (timestamp == null || previous == null || timestamp <= previous) {
        return;
      }
      final angle = _discardedRotation * 180 / math.pi;
      final speed = delta.abs() *
          180 /
          math.pi /
          ((timestamp - previous).inMicroseconds / 1000);
      // Mapbox iOS RotateGestureHandler's angle/velocity gate. Discard the
      // pre-recognition angle rather than snapping it into the first update.
      if (angle < 3 ||
          speed < 0.04 ||
          (speed > 0.07 && angle < 5) ||
          (speed > 0.15 && angle < 7) ||
          (speed > 0.5 && angle < 15)) {
        return;
      }
      _rotating = true;
    }
    if (delta != 0) {
      _send('rotateBy', {
        'radians': delta,
        'x': details.localFocalPoint.dx,
        'y': details.localFocalPoint.dy,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = ui.Size(constraints.maxWidth, constraints.maxHeight);
        if (_textureId == null) {
          if (!_creating && size.width > 0 && size.height > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _create(size));
          }
          return const SizedBox.expand();
        }
        if (_size != size) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _resize(size));
        }
        // The logo and attribution are composited into the texture by the
        // host, along with any view annotation, so there is nothing to stack
        // over it here.
        final texture = Texture(textureId: _textureId!);
        if (!widget.gesturesEnabled) return texture;
        // Observe touch-down without claiming the gesture arena: stop motion
        // immediately and retain the origin until the scale recogniser wins.
        // Buttons painted above the map still own their own hit tests.
        return Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _tap(d.localPosition),
            onScaleStart: (d) {
              _lastRotation = 0;
              _discardedRotation = 0;
              _rotating = false;
              _rotationTimestamp = d.sourceTimeStamp;
              _lastScale = 1;
              _lastFocal = d.localFocalPoint;
              _longPress?.cancel();
              // Double tap and hold, then drag: the sdk's one-finger quick
              // zoom. Down zooms in, up zooms out, about the first touch.
              final down = _secondTouchDown;
              if (down != null && d.pointerCount == 1) {
                _secondTouchDown = null;
                _lastTap = null;
                _lastTapAt = null;
                _quickZoomAnchor = down;
                _quickZoomY = down.dy;
                return;
              }
              final origin = d.localFocalPoint;
              _longPress =
                  Timer(_longPressDelay, () => _tap(origin, long: true));
              final panOrigin = _panOrigin ?? d.localFocalPoint;
              _send('panBegin', {'x': panOrigin.dx, 'y': panOrigin.dy});
              // onScaleStart reports the recognition point, not touch-down.
              // Keep the displacement that crossed slop, including a quick
              // swipe with only one move event before release.
              _send('panUpdate', {
                'x': d.localFocalPoint.dx,
                'y': d.localFocalPoint.dy,
              });
            },
            onScaleUpdate: (d) {
              final anchor = _quickZoomAnchor;
              final lastY = _quickZoomY;
              if (anchor != null && lastY != null) {
                final dy = d.localFocalPoint.dy - lastY;
                _quickZoomY = d.localFocalPoint.dy;
                _send('zoomBy', {
                  'delta': dy / _quickZoomPointsPerLevel,
                  'x': anchor.dx,
                  'y': anchor.dy,
                });
                return;
              }
              final x = d.localFocalPoint.dx;
              final y = d.localFocalPoint.dy;
              final start = _lastFocal;
              if (_longPress != null &&
                  (start == null ||
                      (start - d.localFocalPoint).distance > 10)) {
                _longPress?.cancel();
                _longPress = null;
              }

              // two fingers moving together, vertically, with no spread and no
              // twist, is the sdk's pitch gesture. checked first because the
              // same fingers would otherwise read as an ordinary pan.
              final twoFingers = d.pointerCount >= 2;
              final still =
                  (d.scale - 1).abs() < 0.02 && d.rotation.abs() < 0.02;
              if (twoFingers && still && _lastFocal != null) {
                final dy = y - _lastFocal!.dy;
                if (dy.abs() > 0.5) {
                  _send('pitchBy', {'delta': -dy * 0.25});
                  _lastFocal = Offset(x, y);
                  return;
                }
              }
              _lastFocal = Offset(x, y);

              _send('panUpdate', {'x': x, 'y': y});
              // The gesture's scale is cumulative from its start and zoom is
              // log2 of scale, so the step is the ratio since the last update:
              // spreading the fingers to twice the distance is exactly one
              // zoom level, however many updates it took.
              if (d.scale > 0 && d.scale != _lastScale) {
                final delta = math.log(d.scale / _lastScale) / math.ln2;
                _send('zoomBy', {'delta': delta, 'x': x, 'y': y});
                _lastScale = d.scale;
              }
              _rotate(d);
            },
            onScaleEnd: (d) {
              _longPress?.cancel();
              _longPress = null;
              _send('panEnd');
              if (_quickZoomAnchor != null) {
                // A quick zoom stops where it is let go; it never flings.
                _quickZoomAnchor = null;
                _quickZoomY = null;
                return;
              }
              // A flick should keep going. The host decays it with the sdk's
              // own physics; below its floor this is a no-op.
              final focal = _lastFocal;
              if (focal == null ||
                  d.pointerCount != 0 ||
                  _hadMultiplePointers ||
                  _cancelled) {
                return;
              }
              // Match the native pan handler: a pause before release is not
              // a flick, even if Flutter retains velocity from the last move.
              final lastMove = _lastPanMoveTimestamp;
              final release = _releaseTimestamp;
              if (lastMove == null ||
                  release == null ||
                  release < lastMove ||
                  (release - lastMove).inMicroseconds >= 1000000 / 30) {
                return;
              }
              final v = d.velocity.pixelsPerSecond;
              _send('fling', {
                'vx': v.dx,
                'vy': v.dy,
                'x': focal.dx,
                'y': focal.dy,
              });
            },
            child: texture,
          ),
        );
      },
    );
  }
}
