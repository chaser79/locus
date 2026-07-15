@TestOn('vm')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locus/src/core/locus_streams.dart';
import 'package:locus/src/core/method_channel_locus.dart';
import 'package:locus/src/features/privacy/models/privacy_zone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('locus/methods'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
  });

  tearDown(() async {
    await LocusStreams.setPrivacyZoneService(
      null,
      synchronizeInitialState: false,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('locus/methods'),
      null,
    );
  });

  test('cold construction preserves native guard until an explicit mutation',
      () async {
    final locus = MethodChannelLocus();
    await pumpEventQueue();

    expect(
      calls.where((call) => call.method == 'setPrivacyMode'),
      isEmpty,
      reason: 'a newly-created empty service is not hydrated state',
    );

    await locus.addPrivacyZone(_enabledZone());
    await pumpEventQueue();

    expect(_privacyModeValues(calls), isNotEmpty);
    expect(_privacyModeValues(calls).last, isTrue);

    await locus.removeAllPrivacyZones();
    await pumpEventQueue();

    expect(_privacyModeValues(calls).last, isFalse);
  });

  test('native guard failure prevents an enabled zone from becoming active',
      () async {
    final locus = MethodChannelLocus();
    await pumpEventQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('locus/methods'),
      (call) async {
        calls.add(call);
        if (call.method == 'setPrivacyMode' && call.arguments == true) {
          throw PlatformException(
            code: 'CONFIG_PERSISTENCE_ERROR',
            message: 'Unable to persist privacy mode',
          );
        }
        return true;
      },
    );

    await expectLater(
      locus.addPrivacyZone(_enabledZone()),
      throwsA(isA<PlatformException>()),
    );

    expect(await locus.getPrivacyZones(), isEmpty);
  });

  test('explicitly removing an already-empty set releases a retained guard',
      () async {
    final locus = MethodChannelLocus();
    await pumpEventQueue();

    await locus.removeAllPrivacyZones();

    expect(_privacyModeValues(calls), <bool>[false]);
  });

  test('invalid zone fails validation without changing native privacy state',
      () async {
    final locus = MethodChannelLocus();
    await pumpEventQueue();

    await expectLater(
      locus.addPrivacyZone(PrivacyZone.create(
        identifier: '',
        latitude: 37.7749,
        longitude: -122.4194,
        radius: 100,
      )),
      throwsArgumentError,
    );

    expect(_privacyModeValues(calls), isEmpty);
  });
}

PrivacyZone _enabledZone() => PrivacyZone.create(
      identifier: 'home',
      latitude: 37.7749,
      longitude: -122.4194,
      radius: 100,
    );

List<bool> _privacyModeValues(List<MethodCall> calls) => calls
    .where((call) => call.method == 'setPrivacyMode')
    .map((call) => call.arguments as bool)
    .toList();
