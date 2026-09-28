import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

/// Microphone types, in increasing order of preference.
enum MicrophoneKind { builtIn, other, bluetooth, wired, usb }

/// Routes the meeting microphone to an external mic whenever one is attached.
///
/// LiveKit 2.13 refuses to select audio inputs on mobile, so iOS and Android
/// kept recording from the phone even with a wireless mic receiver plugged in:
/// the presenter could not be heard once they walked away from the phone.
/// This picks the best input on join, when the mic starts and whenever
/// devices change, unless the user chose one manually.
class MicrophoneRouter extends ChangeNotifier {
  MicrophoneRouter({
    Future<List<MediaDevice>> Function()? listInputs,
    Future<void> Function(String deviceId)? selectInput,
    Stream<Object?>? deviceChanges,
  }) : _listInputs = listInputs ?? Hardware.instance.audioInputs,
       // Bypasses Hardware.selectAudioInput, which is a no-op on mobile.
       _selectInput = selectInput ?? rtc.Helper.selectAudioInput {
    _deviceChanges =
        (deviceChanges ?? Hardware.instance.onDeviceChange.stream).listen(
          (_) => unawaited(apply()),
        );
  }

  final Future<List<MediaDevice>> Function() _listInputs;
  final Future<void> Function(String deviceId) _selectInput;
  late final StreamSubscription<Object?> _deviceChanges;
  Future<void> _queue = Future.value();
  List<MediaDevice> _inputs = const [];
  String? _selectedId;
  String? _manualId;
  bool _disposed = false;

  List<MediaDevice> get inputs => _inputs;
  String? get selectedId => _selectedId;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// [MediaDevice.groupId] is the AVAudioSession port type on iOS and the
  /// flutter_webrtc device group on Android.
  static MicrophoneKind kindOf(MediaDevice device) {
    switch (device.groupId) {
      case 'USBAudio':
      case 'usb':
        return MicrophoneKind.usb;
      case 'MicrophoneWired':
      case 'wired-headset':
        return MicrophoneKind.wired;
      case 'BluetoothHFP':
      case 'bluetooth':
      case 'bluetooth-le':
        return MicrophoneKind.bluetooth;
      case 'MicrophoneBuiltIn':
      case 'microphone':
        return MicrophoneKind.builtIn;
      default:
        return MicrophoneKind.other;
    }
  }

  /// Re-evaluates the inputs; serialized so device events cannot interleave.
  Future<void> apply() => _queue = _queue.then((_) => _apply());

  /// Keeps [device] until it is unplugged, then returns to automatic choice.
  Future<void> select(MediaDevice device) {
    _manualId = device.deviceId;
    return apply();
  }

  Future<void> _apply() async {
    if (!_supported || _disposed) return;
    try {
      final inputs = await _listInputs();
      if (_disposed) return;
      _inputs = inputs;
      final target = _pick(inputs);
      if (target != null && target.deviceId != _selectedId) {
        // The OS already records from the built-in mic by default.
        final needsSwitch =
            _selectedId != null ||
            _manualId != null ||
            kindOf(target) != MicrophoneKind.builtIn;
        if (needsSwitch) {
          await _selectInput(target.deviceId);
          debugPrint(
            '[Hisale Coaching Hub] Microphone input: '
            '${target.label} (${target.groupId})',
          );
        }
        _selectedId = target.deviceId;
      }
      if (!_disposed) notifyListeners();
    } catch (error) {
      debugPrint('[Hisale Coaching Hub] Microphone selection failed: $error');
    }
  }

  MediaDevice? _pick(List<MediaDevice> inputs) {
    MediaDevice? best;
    for (final device in inputs) {
      if (device.deviceId == _manualId) return device;
      if (best == null || kindOf(device).index > kindOf(best).index) {
        best = device;
      }
    }
    // The manually chosen mic is gone; fall back to the automatic choice.
    _manualId = null;
    return best;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_deviceChanges.cancel());
    super.dispose();
  }
}
