import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'empty_map_widget.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Logo settings', (WidgetTester tester) async {
    final mapFuture = app.main();
    await tester.pumpAndSettle();
    final mapboxMap = await mapFuture;
    final logo = mapboxMap.logo;
    var settings = LogoSettings(
        enabled: false,
        position: OrnamentPosition.BOTTOM_LEFT,
        marginLeft: 1,
        marginTop: 2,
        marginRight: 3,
        marginBottom: 4);
    await logo.updateSettings(settings);
    var getSettings = await logo.getSettings();
    expect(getSettings.position, OrnamentPosition.BOTTOM_LEFT);
    expect(getSettings.enabled, isFalse);
    expect(
      getSettings.marginLeft,
      1,
      reason: 'marginLeft should be preserved as it is active in BOTTOM_LEFT',
    );
    expect(
      getSettings.marginBottom,
      4,
      reason: 'marginBottom should be preserved as it is active in BOTTOM_LEFT',
    );
    expect(
      getSettings.marginTop,
      2,
      reason:
          'marginTop should be preserved even though it is not active in BOTTOM_LEFT',
    );
    expect(
      getSettings.marginRight,
      3,
      reason:
          'marginRight should be preserved even though it is not active in BOTTOM_LEFT',
    );
  });

  testWidgets('margins are independently tracked across position changes',
      (WidgetTester tester) async {
    final mapFuture = app.main();
    await tester.pumpAndSettle();
    final mapboxMap = await mapFuture;
    final logo = mapboxMap.logo;

    await logo.updateSettings(LogoSettings(
      position: OrnamentPosition.BOTTOM_LEFT,
      marginLeft: 10,
      marginRight: 20,
      marginTop: 30,
      marginBottom: 40,
    ));

    await logo.updateSettings(
      LogoSettings(position: OrnamentPosition.TOP_RIGHT),
    );

    final settings = await logo.getSettings();
    expect(
      settings.marginLeft,
      10,
      reason:
          'marginLeft should be preserved even though it is not active in TOP_RIGHT',
    );
    expect(
      settings.marginBottom,
      40,
      reason:
          'marginBottom should be preserved even though it is not active in TOP_RIGHT',
    );
    expect(
      settings.marginTop,
      30,
      reason: 'marginTop should be preserved as it is active in TOP_RIGHT',
    );
    expect(
      settings.marginRight,
      20,
      reason: 'marginRight should be preserved as it is active in TOP_RIGHT',
    );
  });

  testWidgets('enabled, position and margins are preserved by an empty update',
      (WidgetTester tester) async {
    final mapFuture = app.main();
    await tester.pumpAndSettle();
    final mapboxMap = await mapFuture;
    final logo = mapboxMap.logo;

    final baseline = LogoSettings(
      enabled: false,
      position: OrnamentPosition.TOP_RIGHT,
      marginRight: 11,
      marginTop: 22,
    );
    await logo.updateSettings(baseline);
    var updatedSettings = await logo.getSettings();
    expect(updatedSettings.enabled, baseline.enabled);
    expect(updatedSettings.position, baseline.position);

    await logo.updateSettings(LogoSettings());
    updatedSettings = await logo.getSettings();
    expect(updatedSettings.enabled, baseline.enabled);
    expect(updatedSettings.position, baseline.position);
    expect(updatedSettings.marginRight, baseline.marginRight);
    expect(updatedSettings.marginTop, baseline.marginTop);
  });

  testWidgets(
      'enabled and position are preserved by a partial update that only changes a margin',
      (WidgetTester tester) async {
    final mapFuture = app.main();
    await tester.pumpAndSettle();
    final mapboxMap = await mapFuture;
    final logo = mapboxMap.logo;

    final baseline = LogoSettings(
      enabled: false,
      position: OrnamentPosition.TOP_RIGHT,
      marginRight: 11,
      marginTop: 22,
    );
    await logo.updateSettings(baseline);

    final partialUpdate = LogoSettings(marginRight: 99);
    await logo.updateSettings(partialUpdate);
    final updatedSettings = await logo.getSettings();
    expect(updatedSettings.marginRight, partialUpdate.marginRight);
    expect(updatedSettings.enabled, baseline.enabled);
    expect(updatedSettings.position, baseline.position);
    expect(updatedSettings.marginTop, baseline.marginTop);
  });
}
