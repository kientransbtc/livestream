import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum MeetingMedia { microphone, camera }

enum MediaAccessResult { granted, denied, blocked, restricted, simulatorCamera }

/// Device permission is separate from the host allowing a student to speak.
class MediaAccess {
  static const _iosMicrophoneChannel = MethodChannel(
    'hisale.live/microphone_permission',
  );

  Future<bool>? _simulator;

  Future<bool> get isIosSimulator => _simulator ??= _detectIosSimulator();

  Future<bool> _detectIosSimulator() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    return !(await DeviceInfoPlugin().iosInfo).isPhysicalDevice;
  }

  Future<MediaAccessResult> request(MeetingMedia media) async {
    if (media == MeetingMedia.camera && await isIosSimulator) {
      return MediaAccessResult.simulatorCamera;
    }
    // On web/desktop, the capture API handles the platform permission prompt.
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return MediaAccessResult.granted;
    }

    if (media == MeetingMedia.microphone &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final granted = await _iosMicrophoneChannel.invokeMethod<bool>(
          'request',
        );
        return granted == true
            ? MediaAccessResult.granted
            : MediaAccessResult.blocked;
      } on MissingPluginException {
        // Keep compatibility with older app binaries that do not yet include
        // the native channel; use permission_handler as a fallback.
      } on PlatformException {
        return MediaAccessResult.denied;
      }
    }

    final permission = media == MeetingMedia.microphone
        ? Permission.microphone
        : Permission.camera;
    var status = await permission.status;
    if (status.isDenied) status = await permission.request();
    if (status.isGranted) return MediaAccessResult.granted;
    if (status.isPermanentlyDenied) return MediaAccessResult.blocked;
    if (status.isRestricted) return MediaAccessResult.restricted;
    return MediaAccessResult.denied;
  }
}
