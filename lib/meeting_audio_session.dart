// AudioManager session APIs are marked experimental in livekit_client 2.13.
// ignore_for_file: experimental_member_use

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

/// Holds one call audio session on iOS while a meeting is open.
///
/// In automatic mode LiveKit plays remote audio through a `playback` session
/// while the local mic is off, and switches to `playAndRecord` once the mic
/// records. On iPhones that listen-only session could stay silent: the host
/// heard a member only after turning on the host's own mic. This keeps the
/// exact session LiveKit uses while the mic records for the whole meeting, so
/// playout and the external mic route do not depend on the mic being on.
class MeetingAudioSession {
  MeetingAudioSession._();

  static int _holders = 0;
  static bool _holding = false;
  static bool _mixable = false;

  static bool get _ios =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Takes the session for a meeting. Every call needs a matching [release].
  static Future<void> acquire() async {
    if (!_ios || _holders++ > 0) return;
    _mixable = false;
    _holding = await _apply();
  }

  /// Lets media from other apps mix with the meeting while the screen is
  /// shared. Returns false when no meeting holds the session.
  static Future<bool> setMixable(bool mixable) async {
    if (!_holding) return false;
    if (_mixable == mixable) return true;
    _mixable = mixable;
    _holding = await _apply();
    return _holding;
  }

  /// Hands the session back to LiveKit once the last meeting has closed.
  static Future<void> release() async {
    if (!_ios || _holders == 0 || --_holders > 0) return;
    final wasHolding = _holding;
    _holding = false;
    _mixable = false;
    if (!wasHolding) return;
    try {
      await AudioManager.instance.deactivateAudioSession();
    } catch (error) {
      // Audio may still be stopping; automatic mode deactivates it after.
      debugPrint('[Hisale Coaching Hub] Could not end audio session: $error');
    }
    await _returnToLiveKit();
  }

  static Future<bool> _apply() async {
    final manager = AudioManager.instance;
    try {
      await manager.setAudioSessionOptions(
        AudioSessionOptions.communication(
          apple: AppleAudioSessionConfiguration(
            category: AppleAudioCategory.playAndRecord,
            categoryOptions: {
              AppleAudioCategoryOption.allowBluetooth,
              AppleAudioCategoryOption.allowBluetoothA2DP,
              AppleAudioCategoryOption.allowAirPlay,
              if (_mixable) AppleAudioCategoryOption.mixWithOthers,
            },
            // videoChat plays through the speaker, voiceChat the earpiece.
            mode: manager.isSpeakerOutputPreferred
                ? AppleAudioMode.videoChat
                : AppleAudioMode.voiceChat,
          ),
        ),
      );
      return true;
    } catch (error) {
      debugPrint('[Hisale Coaching Hub] Could not hold audio session: $error');
      // LiveKit's own session still carries the meeting.
      await _returnToLiveKit();
      return false;
    }
  }

  static Future<void> _returnToLiveKit() async {
    try {
      await AudioManager.instance.setAudioSessionManagementMode(
        AudioSessionManagementMode.automatic,
      );
    } catch (error) {
      debugPrint(
        '[Hisale Coaching Hub] Could not restore audio session: $error',
      );
    }
  }
}
