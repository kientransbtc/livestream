import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hi_zoom/microphone_router.dart';
import 'package:livekit_client/livekit_client.dart';

MediaDevice mic(String id, String group) =>
    MediaDevice(id, id, 'audioinput', group);

void main() {
  late List<MediaDevice> inputs;
  late List<String> selected;
  late StreamController<Object?> changes;
  late MicrophoneRouter router;

  setUp(() {
    inputs = [mic('built-in', 'microphone')];
    selected = [];
    changes = StreamController<Object?>();
    router = MicrophoneRouter(
      listInputs: () async => List.of(inputs),
      selectInput: (id) async => selected.add(id),
      deviceChanges: changes.stream,
    );
  });

  tearDown(() async {
    router.dispose();
    await changes.close();
  });

  test('keeps the default built-in mic without forcing a route', () async {
    await router.apply();
    expect(selected, isEmpty);
    expect(router.selectedId, 'built-in');
  });

  test('a plugged-in wireless mic receiver wins over the phone', () async {
    inputs.add(mic('usb-rx', 'usb'));
    await router.apply();
    expect(selected, ['usb-rx']);
  });

  test('prefers USB > wired > Bluetooth > built-in (iOS port types)', () async {
    inputs = [
      mic('iphone', 'MicrophoneBuiltIn'),
      mic('airpods', 'BluetoothHFP'),
      mic('headset', 'MicrophoneWired'),
      mic('lav', 'USBAudio'),
    ];
    await router.apply();
    expect(selected, ['lav']);
  });

  test('device changes re-route: plug in, then unplug back to built-in', () async {
    await router.apply();
    inputs.add(mic('usb-rx', 'usb'));
    changes.add(null);
    await pumpEventQueue();
    await router.apply();
    inputs.removeWhere((d) => d.deviceId == 'usb-rx');
    changes.add(null);
    await pumpEventQueue();
    await router.apply();
    expect(selected, ['usb-rx', 'built-in']);
  });

  test('a manual choice sticks until that mic is unplugged', () async {
    inputs.add(mic('usb-rx', 'usb'));
    await router.apply();
    await router.select(inputs.first);
    await router.apply();
    expect(selected, ['usb-rx', 'built-in']);
    expect(router.selectedId, 'built-in');

    // Unplugging the manual choice falls back to the automatic pick.
    inputs = [mic('usb-rx', 'usb')];
    await router.apply();
    expect(router.selectedId, 'usb-rx');
  });

  test('starting the mic routes to the external mic again', () async {
    inputs.add(mic('usb-rx', 'usb'));
    await router.apply();
    await router.apply();
    expect(selected, ['usb-rx']);

    await router.apply(reselect: true);
    expect(selected, ['usb-rx', 'usb-rx']);
  });

  test('reselecting leaves the built-in mic alone', () async {
    await router.apply(reselect: true);
    expect(selected, isEmpty);
  });

  test('knows when the mic in use is not the phone', () async {
    await router.apply();
    expect(router.usesExternalInput, isFalse);

    inputs.add(mic('usb-rx', 'usb'));
    await router.apply();
    expect(router.usesExternalInput, isTrue);
  });

  test('a new built-in mic id once recording starts is not re-routed', () async {
    await router.apply();
    inputs = [mic('built-in-front', 'MicrophoneBuiltIn')];
    await router.apply(reselect: true);
    expect(selected, isEmpty);
    expect(router.selectedId, 'built-in-front');
  });
}
