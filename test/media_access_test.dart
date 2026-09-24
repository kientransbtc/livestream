import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_zoom/media_access.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const deviceInfo = MethodChannel('dev.fluttercommunity.plus/device_info');
  const iosMicrophone = MethodChannel('hisale.live/microphone_permission');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<int, int> statuses;
  late List<int> requested;
  late bool iosMicGranted;
  late int iosMicRequestCount;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    statuses = {};
    requested = [];
    iosMicGranted = true;
    iosMicRequestCount = 0;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'checkPermissionStatus') {
        return statuses[call.arguments] ?? PermissionStatus.denied.index;
      }
      if (call.method == 'requestPermissions') {
        final values = List<int>.from(call.arguments);
        requested.addAll(values);
        return {
          for (final value in values) value: PermissionStatus.granted.index,
        };
      }
      throw StateError('Unexpected permission operation: ${call.method}');
    });
    messenger.setMockMethodCallHandler(iosMicrophone, (call) async {
      if (call.method != 'request') {
        throw StateError('Unexpected microphone operation: ${call.method}');
      }
      iosMicRequestCount++;
      return iosMicGranted;
    });
    messenger.setMockMethodCallHandler(
      deviceInfo,
      (_) async => {
        'name': 'Test simulator',
        'systemName': 'iOS',
        'systemVersion': '17.5',
        'model': 'iPhone',
        'modelName': 'iPhone',
        'localizedModel': 'iPhone',
        'identifierForVendor': 'test-device',
        'isPhysicalDevice': false,
        'isiOSAppOnMac': false,
        'isiOSAppOnVision': false,
        'freeDiskSize': 1000000,
        'totalDiskSize': 2000000,
        'physicalRamSize': 4096,
        'availableRamSize': 2048,
        'utsname': {
          'sysname': 'Darwin',
          'nodename': 'test',
          'release': '23',
          'version': 'test',
          'machine': 'arm64',
        },
      },
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(permissions, null);
    messenger.setMockMethodCallHandler(deviceInfo, null);
    messenger.setMockMethodCallHandler(iosMicrophone, null);
  });

  test(
    'first mic use waits for the OS permission request to succeed',
    () async {
      expect(
        await MediaAccess().request(MeetingMedia.microphone),
        MediaAccessResult.granted,
      );
      expect(iosMicRequestCount, 1);
      expect(requested, isEmpty);
    },
  );

  test('denied iOS mic directs the user to settings', () async {
    iosMicGranted = false;
    expect(
      await MediaAccess().request(MeetingMedia.microphone),
      MediaAccessResult.blocked,
    );
    expect(iosMicRequestCount, 1);
    expect(requested, isEmpty);
  });

  test(
    'simulator camera unavailability does not block a separate mic request',
    () async {
      final access = MediaAccess();
      expect(
        await access.request(MeetingMedia.camera),
        MediaAccessResult.simulatorCamera,
      );
      expect(requested, isEmpty);
      expect(
        await access.request(MeetingMedia.microphone),
        MediaAccessResult.granted,
      );
      expect(iosMicRequestCount, 1);
      expect(requested, isEmpty);
    },
  );

  test(
    'a granted mic does not ask for camera or another permission prompt',
    () async {
      statuses[Permission.microphone.value] = PermissionStatus.granted.index;
      expect(
        await MediaAccess().request(MeetingMedia.microphone),
        MediaAccessResult.granted,
      );
      expect(iosMicRequestCount, 1);
      expect(requested, isEmpty);
    },
  );

  test('a denied camera does not revoke the microphone on Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    statuses[Permission.camera.value] =
        PermissionStatus.permanentlyDenied.index;
    statuses[Permission.microphone.value] = PermissionStatus.granted.index;
    final access = MediaAccess();
    expect(
      await access.request(MeetingMedia.camera),
      MediaAccessResult.blocked,
    );
    expect(
      await access.request(MeetingMedia.microphone),
      MediaAccessResult.granted,
    );
    expect(requested, isEmpty);
  });
}
