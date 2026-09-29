// AudioManager session APIs are marked experimental in livekit_client 2.13.
// ignore_for_file: experimental_member_use

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_zoom/meeting_audio_session.dart';
import 'package:livekit_client/livekit_client.dart';

AudioManager get _manager => AudioManager.instance;

Set<AppleAudioCategoryOption>? get _options =>
    _manager.options.apple.categoryOptions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _manager.resetForTest();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a meeting keeps the session LiveKit records with', () async {
    await MeetingAudioSession.acquire();

    expect(_manager.managementMode, AudioSessionManagementMode.manual);
    final apple = _manager.options.apple;
    expect(apple.category, AppleAudioCategory.playAndRecord);
    expect(apple.mode, AppleAudioMode.videoChat);
    expect(_options, {
      AppleAudioCategoryOption.allowBluetooth,
      AppleAudioCategoryOption.allowBluetoothA2DP,
      AppleAudioCategoryOption.allowAirPlay,
    });

    await MeetingAudioSession.release();
    expect(_manager.managementMode, AudioSessionManagementMode.automatic);
  });

  test('screen sharing mixes with other apps only while it lasts', () async {
    expect(await MeetingAudioSession.setMixable(true), isFalse);

    await MeetingAudioSession.acquire();
    expect(await MeetingAudioSession.setMixable(true), isTrue);
    expect(_options, contains(AppleAudioCategoryOption.mixWithOthers));

    expect(await MeetingAudioSession.setMixable(false), isTrue);
    expect(_options, isNot(contains(AppleAudioCategoryOption.mixWithOthers)));
    await MeetingAudioSession.release();
  });

  test(
    'LiveKit gets the session back only when the last meeting closes',
    () async {
      await MeetingAudioSession.acquire();
      await MeetingAudioSession.acquire();

      await MeetingAudioSession.release();
      expect(_manager.managementMode, AudioSessionManagementMode.manual);

      await MeetingAudioSession.release();
      expect(_manager.managementMode, AudioSessionManagementMode.automatic);

      // An extra release does not take a later meeting's session away.
      await MeetingAudioSession.release();
      await MeetingAudioSession.acquire();
      expect(_manager.managementMode, AudioSessionManagementMode.manual);
      await MeetingAudioSession.release();
    },
  );

  test("Android keeps LiveKit's automatic session", () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await MeetingAudioSession.acquire();
    expect(_manager.managementMode, AudioSessionManagementMode.automatic);
    expect(await MeetingAudioSession.setMixable(true), isFalse);
    await MeetingAudioSession.release();
  });
}
