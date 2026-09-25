import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hi_zoom/screen_share.dart';

class FakeCapture extends ScreenShareBackend {
  final calls = <String>[];
  bool allowed = true;
  bool published = false;
  bool service = false;
  bool failPublish = false;
  Completer<bool>? permission;
  Completer<void>? publishGate;

  @override
  bool get active => published;
  @override
  bool get capturing => published;
  @override
  Future<bool> prepare() async {
    calls.add('permission');
    final granted = await (permission?.future ?? Future.value(allowed));
    if (granted) {
      service = true;
      calls.add('service');
    }
    return granted;
  }

  @override
  Future<void> publish() async {
    calls.add('publish');
    published = true;
    await publishGate?.future;
    if (failPublish) throw StateError('cancelled');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    published = false;
    service = false;
  }

  @override
  Future<void> restoreMicrophoneCapture() async {
    calls.add('restore_mic');
  }

  @override
  void preventNewCapture() => calls.add('prevent');
}

void main() {
  test(
    'permission cancel never publishes or leaves a service running',
    () async {
      final native = FakeCapture()..allowed = false;
      final share = ScreenShareController(native);
      await share.toggle();
      expect(native.calls, ['permission', 'stop']);
      expect(share.active, isFalse);
      expect(share.error, isNull);
      expect(native.service, isFalse);
      await share.close();
    },
  );

  test('every new share requests consent and stop releases capture', () async {
    final native = FakeCapture();
    final share = ScreenShareController(native);
    await share.toggle();
    expect(native.calls, ['permission', 'service', 'publish']);
    expect(share.active, isTrue);
    await share.toggle();
    expect(native.service, isFalse);
    expect(native.calls.skip(native.calls.length - 2), ['stop', 'restore_mic']);
    await share.toggle();
    expect(native.calls.where((v) => v == 'permission'), hasLength(2));
    await share.close();
    expect(native.service, isFalse);
  });

  test('share stays inactive while native consent is pending', () async {
    final native = FakeCapture()..publishGate = Completer<void>();
    final share = ScreenShareController(native);
    final start = share.toggle();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(native.published, isTrue);
    expect(share.busy, isTrue);
    expect(share.active, isFalse);

    native.publishGate!.complete();
    await start;
    expect(share.active, isTrue);
    await share.close();
  });

  test(
    'cancelled native consent cleans up and leaves share inactive',
    () async {
      final native = FakeCapture()
        ..publishGate = Completer<void>()
        ..failPublish = true;
      final share = ScreenShareController(native);
      final start = share.toggle();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(share.active, isFalse);
      native.publishGate!.complete();
      await start;

      expect(share.active, isFalse);
      expect(share.busy, isFalse);
      expect(native.published, isFalse);
      await share.close();
    },
  );

  test(
    'leaving during consent prevents publication and cleans the service',
    () async {
      final native = FakeCapture()..permission = Completer<bool>();
      final share = ScreenShareController(native);
      final start = share.toggle();
      final close = share.close();
      native.permission!.complete(true);
      await start;
      await close;
      expect(native.calls, isNot(contains('publish')));
      expect(native.service, isFalse);
      expect(share.active, isFalse);
    },
  );

  test('double tap cannot start two projections; failure cleans up', () async {
    final native = FakeCapture()
      ..permission = Completer<bool>()
      ..failPublish = true;
    final share = ScreenShareController(native);
    final first = share.toggle();
    await share.toggle();
    native.permission!.complete(true);
    await first;
    expect(native.calls.where((v) => v == 'permission'), hasLength(1));
    expect(share.error, isNotNull);
    expect(native.service, isFalse);
    expect(share.busy, isFalse);
    await share.close();
  });

  test('system-ended track stops the owned service', () async {
    final native = FakeCapture();
    final share = ScreenShareController(native);
    await share.toggle();
    native.published = false;
    share.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(native.service, isFalse);
    expect(share.active, isFalse);
    expect(native.calls.skip(native.calls.length - 2), ['stop', 'restore_mic']);
    await share.close();
  });
}
