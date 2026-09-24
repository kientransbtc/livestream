import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
// 2.13.0 exposes broadcast controls through this SDK module.
// ignore: implementation_imports
import 'package:livekit_client/src/managers/broadcast_manager.dart';

/// Native capture is separate from the UI so cancellation/cleanup can be tested.
abstract class ScreenShareBackend {
  bool get active;
  bool get capturing;
  Future<bool> prepare();
  Future<void> publish();
  Future<void> stop();
  void preventNewCapture();
}

class ScreenShareController extends ChangeNotifier {
  ScreenShareController(this.backend);

  factory ScreenShareController.forRoom(Room room) {
    final controller = ScreenShareController(_LiveKitScreenShareBackend(room));
    final local = room.localParticipant!;
    local.addListener(controller.refresh);
    controller._detach = () => local.removeListener(controller.refresh);
    return controller;
  }

  final ScreenShareBackend backend;
  VoidCallback? _detach;
  Future<void>? _operation;
  Future<void>? _closing;
  bool _closed = false;
  bool _disposed = false;
  bool _wasActive = false;
  bool _busy = false;
  String? _error;

  bool get active => backend.active;
  bool get busy => _busy;
  String? get error => _error;

  void refresh() {
    if (_disposed || _closed) return;
    final activeNow = active;
    final ended = _wasActive && !activeNow;
    final changed = activeNow != _wasActive;
    _wasActive = activeNow;
    // Room/local-participant events can arrive several times for one capture
    // transition. Only rebuild the toolbar when the effective state changed.
    if (changed) notifyListeners();
    // Android's system Stop button ends the track; release our service as well.
    if (ended && !_busy) unawaited(stop());
  }

  Future<void> toggle() {
    if (_closed || _busy) return Future.value();
    return backend.capturing ? stop() : _run(start: true);
  }

  Future<void> stop() {
    if (_closed || _busy) return Future.value();
    return _run(start: false);
  }

  Future<void> _run({required bool start}) {
    _busy = true;
    _error = null;
    notifyListeners();
    return _operation = _perform(start: start);
  }

  Future<void> _perform({required bool start}) async {
    try {
      if (start) {
        final allowed = await backend.prepare();
        if (!allowed || _closed) {
          await backend.stop();
          return;
        }
        await backend.publish();
      } else {
        await backend.stop();
      }
    } catch (e) {
      _error = e is ScreenShareException
          ? e.message
          : 'Không thể chia sẻ màn hình. Kiểm tra kết nối và thử lại.';
      try {
        await backend.stop();
      } catch (_) {
        _error =
            'Chưa dừng được chia sẻ. Hãy bấm Dừng trên thông báo hệ thống.';
      }
    } finally {
      _busy = false;
      _wasActive = active;
      if (!_disposed && !_closed) notifyListeners();
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    backend.preventNewCapture();
    _detach?.call();
    // In-flight permission/service requests must finish before final cleanup.
    await _operation;
    try {
      await backend.stop();
    } finally {
      if (!_disposed) {
        _disposed = true;
        super.dispose();
      }
    }
  }
}

class ScreenShareException implements Exception {
  const ScreenShareException(this.message);
  final String message;
}

class _LiveKitScreenShareBackend implements ScreenShareBackend {
  _LiveKitScreenShareBackend(this.room);

  final Room room;
  bool _ownsService = false;
  bool _capturePrevented = false;
  bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  bool get active => room.localParticipant?.isScreenShareEnabled() ?? false;

  @override
  bool get capturing => active || (_ios && BroadcastManager().isBroadcasting);

  @override
  Future<bool> prepare() async {
    _capturePrevented = false;
    final permissions = room.localParticipant?.permissions;
    if (permissions == null ||
        !permissions.canPublish ||
        (permissions.canPublishSources.isNotEmpty &&
            !permissions.canPublishSources.any(
              (source) => source.name == 'SCREEN_SHARE',
            ))) {
      throw const ScreenShareException(
        'Bạn chưa có quyền chia sẻ màn hình trong phòng.',
      );
    }
    if (_ios) {
      if (!(await DeviceInfoPlugin().iosInfo).isPhysicalDevice) {
        throw const ScreenShareException(
          'Hãy dùng iPhone thật để chia sẻ màn hình.',
        );
      }
      BroadcastManager().shouldPublishTrack = true;
      return true;
    }
    if (!_android) {
      throw const ScreenShareException(
        'Tính năng này hiện hỗ trợ app iOS và Android.',
      );
    }
    // Fresh MediaProjection consent on every start, before starting the service.
    if (!await rtc.Helper.requestCapturePermission()) return false;
    final initialized = await FlutterBackground.initialize(
      androidConfig: const FlutterBackgroundAndroidConfig(
        notificationTitle: 'hisale live',
        notificationText: 'Đang chia sẻ màn hình. Mở ứng dụng để dừng.',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(
          name: 'ic_screen_share',
          defType: 'drawable',
        ),
        shouldRequestBatteryOptimizationsOff: false,
        enableWifiLock: false,
      ),
    );
    if (!initialized) {
      throw const ScreenShareException(
        'Chưa khởi tạo được dịch vụ chia sẻ màn hình.',
      );
    }
    if (!FlutterBackground.isBackgroundExecutionEnabled) {
      // Own the cleanup even if native startup throws after partially starting.
      _ownsService = true;
      if (!await FlutterBackground.enableBackgroundExecution()) {
        throw const ScreenShareException(
          'Chưa khởi động được dịch vụ chia sẻ màn hình.',
        );
      }
    }

    return true;
  }

  @override
  Future<void> publish() async {
    if (room.connectionState != ConnectionState.connected) {
      throw const ScreenShareException(
        'Phòng đang mất kết nối. Thử lại sau khi kết nối lại.',
      );
    }
    await room.localParticipant!.setScreenShareEnabled(
      true,
      // Only publish the screen video track. Meeting microphone audio remains
      // an independent LiveKit track and is unaffected by screen sharing.
      captureScreenAudio: false,
    );

    // On iOS setScreenShareEnabled opens the ReplayKit picker and returns
    // before the user has made a choice. Wait for the actual broadcast event.
    if (_ios && !BroadcastManager().isBroadcasting) {
      await _waitForIOSBroadcast();
    }
  }

  Future<void> _waitForIOSBroadcast() async {
    final manager = BroadcastManager();
    for (var attempt = 0; attempt < 200; attempt++) {
      if (manager.isBroadcasting) return;
      if (_capturePrevented ||
          room.connectionState != ConnectionState.connected) {
        throw const ScreenShareException(
          'Đã hủy chia sẻ màn hình vì bạn rời phòng.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const ScreenShareException(
      'Bạn đã hủy hộp thoại chia sẻ màn hình hoặc chưa bấm Start Broadcast.',
    );
  }

  @override
  void preventNewCapture() {
    _capturePrevented = true;
    if (_ios) BroadcastManager().shouldPublishTrack = false;
  }

  @override
  Future<void> stop() async {
    try {
      if (_ios) {
        BroadcastManager().shouldPublishTrack = false;
        await BroadcastManager().requestStop();
      }
      await room.localParticipant?.setScreenShareEnabled(false);
    } finally {
      if (_android && _ownsService) {
        await FlutterBackground.disableBackgroundExecution();
        _ownsService = false;
      }
    }
  }
}
