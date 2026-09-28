// AudioManager session APIs are marked experimental in livekit_client 2.13.
// ignore_for_file: experimental_member_use

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
  Future<void> restoreMicrophoneCapture();
  void preventNewCapture();
}

class ScreenShareController extends ChangeNotifier {
  ScreenShareController(this.backend);

  factory ScreenShareController.forRoom(Room room) {
    final controller = ScreenShareController(_LiveKitScreenShareBackend(room));
    final local = room.localParticipant!;
    final observeBroadcast =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    local.addListener(controller.refresh);
    if (observeBroadcast) {
      BroadcastManager().addListener(controller.refresh);
    }
    controller._detach = () {
      local.removeListener(controller.refresh);
      if (observeBroadcast) {
        BroadcastManager().removeListener(controller.refresh);
      }
    };
    return controller;
  }

  final ScreenShareBackend backend;
  VoidCallback? _detach;
  Future<void>? _operation;
  Future<void>? _closing;
  bool _closed = false;
  bool _disposed = false;
  bool _captureWasStarted = false;
  bool _sharingConfirmed = false;
  bool _wasActive = false;
  bool _busy = false;
  String? _error;

  // Some platforms create/enable a publication while the native consent UI is
  // still open. Treat sharing as active only after the capture flow completes.
  bool get active => _sharingConfirmed && backend.active;
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

  /// Stops sharing after any start or stop in progress, so a share still
  /// waiting for the system consent UI also ends once it starts.
  Future<void> stopWhenIdle() async {
    while (_busy && !_closed) {
      await _operation;
    }
    if (_closed || !backend.capturing) return;
    await stop();
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
        _sharingConfirmed = false;
        final allowed = await backend.prepare();
        if (!allowed || _closed) {
          await backend.stop();
          return;
        }
        await backend.publish();
        _captureWasStarted = true;
        _sharingConfirmed = backend.capturing;
      } else {
        _sharingConfirmed = false;
        await backend.stop();
        final restoreMicrophone = _captureWasStarted;
        _captureWasStarted = false;
        if (restoreMicrophone) {
          await backend.restoreMicrophoneCapture();
        }
      }
    } catch (e) {
      _sharingConfirmed = false;
      if (start) {
        // A native publisher can become active before publish() reports an
        // error. Remember that capture so cleanup can also repair the mic.
        _captureWasStarted = backend.active || backend.capturing;
      }
      _error = e is ScreenShareException
          ? e.message
          : start
          ? 'Không thể chia sẻ màn hình. Kiểm tra kết nối và thử lại.'
          : 'Đã dừng chia sẻ nhưng chưa khôi phục được micro. Hãy thử lại mic.';
      try {
        await backend.stop();
        if (!start && _captureWasStarted) {
          _captureWasStarted = false;
          await backend.restoreMicrophoneCapture();
        }
      } catch (cleanupError) {
        _error = cleanupError is ScreenShareException
            ? cleanupError.message
            : 'Chưa dừng được chia sẻ. Hãy bấm Dừng trên thông báo hệ thống.';
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
  bool _ownsMixableAudioSession = false;
  bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  bool get active {
    final published = room.localParticipant?.isScreenShareEnabled() ?? false;
    // LiveKit may expose the publication while ReplayKit's system picker is
    // still pending. It is not an active share until iOS confirms broadcast.
    return published && (!_ios || BroadcastManager().isBroadcasting);
  }

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
        notificationTitle: 'Hisale Coaching Hub',
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
      // Device playback is mixed natively into the microphone track after
      // voice processing. A second local audio track must not be published:
      // this WebRTC build mutes the shared mic input (ADM) whenever any local
      // audio stream is muted, which silences the presenter's voice too.
      // LiveKit's captureScreenAudio path is for web, not ReplayKit.
      captureScreenAudio: false,
    );

    // On iOS setScreenShareEnabled opens the ReplayKit picker and returns
    // before the user has made a choice. Wait for the actual broadcast event.
    if (_ios && !BroadcastManager().isBroadcasting) {
      await _waitForIOSBroadcast();
    }
    if (_ios) await _enableMixableAudioSession();
  }

  /// LiveKit's automatic iOS session is playAndRecord without mixWithOthers.
  /// While broadcasting, the presenter plays media in another app; that app's
  /// non-mixable session then interrupts ours, which stops the WebRTC mic
  /// capture that ReplayKit app audio is mixed into, so nobody hears it.
  Future<void> _enableMixableAudioSession() async {
    final manager = AudioManager.instance;
    if (_ownsMixableAudioSession ||
        manager.managementMode != AudioSessionManagementMode.automatic) {
      return;
    }
    try {
      await manager.setAudioSessionOptions(
        AudioSessionOptions.communication(
          apple: AppleAudioSessionConfiguration(
            category: AppleAudioCategory.playAndRecord,
            categoryOptions: const {
              AppleAudioCategoryOption.allowBluetooth,
              AppleAudioCategoryOption.allowBluetoothA2DP,
              AppleAudioCategoryOption.allowAirPlay,
              AppleAudioCategoryOption.mixWithOthers,
            },
            // Match the automatic policy so routing does not jump to the
            // earpiece/speaker when the category options change.
            mode: manager.isSpeakerOutputPreferred
                ? AppleAudioMode.videoChat
                : AppleAudioMode.voiceChat,
          ),
        ),
      );
      _ownsMixableAudioSession = true;
    } catch (error) {
      // Video sharing still works; only other-app audio may be interrupted.
      debugPrint(
        '[Hisale Coaching Hub] Could not enable mixable audio session: $error',
      );
      await manager.setAudioSessionManagementMode(
        AudioSessionManagementMode.automatic,
      );
    }
  }

  Future<void> _restoreAudioSession() async {
    if (!_ownsMixableAudioSession) return;
    _ownsMixableAudioSession = false;
    // Hands the session back to LiveKit, which reapplies its managed policy.
    await AudioManager.instance.setAudioSessionManagementMode(
      AudioSessionManagementMode.automatic,
    );
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
      if (_ios && !await _waitForIOSBroadcastToStop()) {
        throw const ScreenShareException(
          'Chưa xác nhận được iOS đã dừng chia sẻ màn hình.',
        );
      }
    } finally {
      if (_android && _ownsService) {
        await FlutterBackground.disableBackgroundExecution();
        _ownsService = false;
      }
      await _restoreAudioSession();
    }
  }

  @override
  Future<void> restoreMicrophoneCapture() async {
    final local = room.localParticipant;
    if (local == null ||
        room.connectionState != ConnectionState.connected ||
        !local.isMicrophoneEnabled()) {
      return;
    }

    final publication = local.getTrackPublicationBySource(
      TrackSource.microphone,
    );
    final track = publication?.track;
    if (publication == null || publication.muted || track is! LocalAudioTrack) {
      return;
    }

    // Let ReplayKit/MediaProjection and their audio services finish releasing
    // the capture session before asking WebRTC to acquire the microphone again.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (room.connectionState != ConnectionState.connected ||
        !local.isMicrophoneEnabled() ||
        !_canPublishMicrophone(local) ||
        publication.muted ||
        publication.track != track) {
      return;
    }

    try {
      // The publication remains unmuted, but the native capture can be stale
      // after screen capture/background transitions. Replace its source while
      // keeping the same LiveKit publication and the user's mic state.
      await track.restartTrack();
      debugPrint(
        '[Hisale Coaching Hub] Microphone capture restored after screen share.',
      );
    } catch (error) {
      debugPrint(
        '[Hisale Coaching Hub] Mic track restart failed; retrying through LiveKit mute/unmute: $error',
      );

      // Fallback to the same SDK mute/unmute cycle that recovers the mic when
      // a user toggles the button manually. Only do this while the room and
      // existing mic publication are still valid.
      if (room.connectionState != ConnectionState.connected ||
          !local.isMicrophoneEnabled() ||
          publication.muted ||
          publication.track != track ||
          !_canPublishMicrophone(local)) {
        return;
      }
      try {
        await local.setMicrophoneEnabled(false);
        await Future<void>.delayed(const Duration(milliseconds: 180));
        if (room.connectionState == ConnectionState.connected &&
            !local.isMicrophoneEnabled() &&
            _canPublishMicrophone(local)) {
          await local.setMicrophoneEnabled(true);
        }
      } catch (retryError) {
        throw ScreenShareException(
          'Đã dừng chia sẻ nhưng chưa khôi phục được micro: $retryError',
        );
      }
    }
  }

  bool _canPublishMicrophone(LocalParticipant local) {
    final permissions = local.permissions;
    return permissions.canPublish &&
        (permissions.canPublishSources.isEmpty ||
            permissions.canPublishSources.any(
              (source) => source.name == 'MICROPHONE',
            ));
  }

  Future<bool> _waitForIOSBroadcastToStop() async {
    final manager = BroadcastManager();
    for (var attempt = 0; attempt < 40; attempt++) {
      if (!manager.isBroadcasting) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return !manager.isBroadcasting;
  }
}
