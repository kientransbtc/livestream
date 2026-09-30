import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';

import 'media_access.dart';
import 'meeting_audio_session.dart';
import 'microphone_router.dart';

const livestreamChatTopic = 'hisale.livestream.chat';
const livestreamControlTopic = 'hisale.livestream.control';
const _endedSignal = 'ended';
const livestreamChatMaxCharacters = 500;

/// A chat line seen during this connection. LiveKit forwards new messages
/// only, so nothing is kept after leaving the room.
@immutable
class LivestreamChatMessage {
  const LivestreamChatMessage({
    required this.id,
    required this.senderName,
    required this.text,
    required this.sentAt,
    this.isOwn = false,
  });
  final String id;
  final String senderName;
  final String text;
  final DateTime sentAt;
  final bool isOwn;
}

/// The broadcast media path and its chat, both over the LiveKit room.
/// Session state belongs to the application.
class LivestreamMediaController extends ChangeNotifier {
  LivestreamMediaController({this.onMessage, this.onEnded});

  /// Called for every message another participant sends.
  void Function(LivestreamChatMessage message)? onMessage;

  /// Called once the host ends the broadcast or the server deletes the room.
  void Function()? onEnded;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  MicrophoneRouter? _microphones;
  final _access = MediaAccess();
  Future<void> _queue = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  bool _disposed = false;
  bool _holdsAudioSession = false;
  bool _host = false;
  String? _hostIdentity;
  CameraPosition _cameraPosition = CameraPosition.front;
  String? connectionError;
  bool _endedNotified = false;

  bool get connected => _room?.connectionState == ConnectionState.connected;
  bool get reconnecting =>
      _room?.connectionState == ConnectionState.reconnecting;
  bool get microphoneEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get cameraEnabled => _room?.localParticipant?.isCameraEnabled() ?? false;

  /// People watching, excluding the host.
  int get viewerCount {
    final room = _room;
    if (room == null || !connected) return 0;
    final everyone = room.remoteParticipants.length + 1;
    final hostPresent =
        _host || room.remoteParticipants.containsKey(_hostIdentity);
    return hostPresent ? everyone - 1 : everyone;
  }

  String? get microphoneName {
    final router = _microphones;
    if (router == null) return null;
    for (final device in router.inputs) {
      if (device.deviceId == router.selectedId) return device.label;
    }
    return null;
  }

  void _changed() {
    if (!_disposed && !_closed) notifyListeners();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Phiên video đã đóng.');
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _queue.then((_) async {
      _checkOpen();
      await operation();
    });
    // A failed capture must not prevent a later retry or cleanup.
    _queue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<void> connect({
    required String serverUrl,
    required String token,
    required String hostIdentity,
    required bool isHost,
  }) => _serialize(() async {
    await _tearDown();
    _checkOpen();
    _host = isHost;
    _hostIdentity = hostIdentity;
    connectionError = null;
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: CameraCaptureOptions(
          params: VideoParametersPresets.h720_169,
        ),
      ),
    );
    _room = room;
    _listener = room.createListener()
      ..on<RoomDisconnectedEvent>((event) {
        connectionError = 'Kết nối video bị ngắt. Hãy kết nối lại.';
        if (event.reason == DisconnectReason.roomDeleted) _notifyEnded();
        _changed();
      })
      ..on<ParticipantConnectedEvent>((_) => _changed())
      ..on<ParticipantDisconnectedEvent>((_) => _changed())
      ..on<RoomReconnectingEvent>((_) => _changed())
      ..on<RoomReconnectedEvent>((_) {
        connectionError = null;
        if (_host) unawaited(_microphones?.apply(reselect: true));
        _changed();
      })
      ..on<TrackSubscribedEvent>((_) => _changed())
      ..on<TrackUnsubscribedEvent>((_) => _changed())
      ..on<TrackMutedEvent>((_) => _changed())
      ..on<TrackUnmutedEvent>((_) => _changed())
      ..on<LocalTrackPublishedEvent>((_) => _changed())
      ..on<LocalTrackUnpublishedEvent>((_) => _changed());
    room.addListener(_changed);
    room.registerTextStreamHandler(livestreamChatTopic, (reader, identity) {
      unawaited(_receiveChat(room, reader, identity));
    });
    room.registerTextStreamHandler(livestreamControlTopic, (reader, identity) {
      unawaited(_receiveControl(reader, identity));
    });
    try {
      await MeetingAudioSession.acquire();
      _holdsAudioSession = true;
      _checkOpen();
      await room.connect(serverUrl, token);
      _checkOpen();
      final local = room.localParticipant;
      if (local == null ||
          !local.permissions.canSubscribe ||
          (isHost &&
              (!local.permissions.canPublish ||
                  local.identity != hostIdentity)) ||
          (!isHost && local.permissions.canPublish)) {
        throw StateError('Quyền kết nối livestream không hợp lệ.');
      }
      if (isHost) {
        _microphones = MicrophoneRouter()..addListener(_changed);
        await _microphones!.apply();
      }
      _changed();
    } catch (_) {
      await _tearDown();
      rethrow;
    }
  });

  void _notifyEnded() {
    if (_endedNotified || _disposed) return;
    _endedNotified = true;
    onEnded?.call();
  }

  Future<void> _receiveChat(
    Room room,
    TextStreamReader reader,
    String identity,
  ) async {
    try {
      final text = (await reader.readAll()).trim();
      if (text.isEmpty || _room != room || _closed) return;
      final name = room.remoteParticipants[identity]?.name.trim();
      onMessage?.call(
        LivestreamChatMessage(
          id:
              reader.info?.id ??
              '$identity-${DateTime.now().microsecondsSinceEpoch}',
          senderName: name?.isNotEmpty == true ? name! : 'Người xem',
          text: text.characters.take(livestreamChatMaxCharacters).toString(),
          sentAt: _sentAt(reader.info?.timestamp ?? 0),
        ),
      );
    } catch (_) {
      // A broken stream loses one message, never the room.
    }
  }

  Future<void> _receiveControl(TextStreamReader reader, String identity) async {
    try {
      final signal = await reader.readAll();
      // Only the host can end the broadcast for everyone.
      if (signal == _endedSignal && identity == _hostIdentity) _notifyEnded();
    } catch (_) {}
  }

  static DateTime _sentAt(int milliseconds) =>
      milliseconds <= 0 || milliseconds > 8640000000000000
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(milliseconds);

  Future<LivestreamChatMessage> sendChat(String text) async {
    _checkOpen();
    final local = _room?.localParticipant;
    if (!connected || local == null || !local.permissions.canPublishData) {
      throw StateError('Chat chưa kết nối. Hãy thử lại.');
    }
    final info = await local.sendText(
      text,
      options: SendTextOptions(topic: livestreamChatTopic),
    );
    final name = local.name.trim();
    return LivestreamChatMessage(
      id: info.id,
      senderName: name.isNotEmpty ? name : 'Bạn',
      text: text,
      sentAt: _sentAt(info.timestamp),
      isOwn: true,
    );
  }

  /// Tells viewers the host ended the broadcast. Best effort: viewers also
  /// learn it when the backend deletes the room.
  Future<void> announceEnded() async {
    final local = _room?.localParticipant;
    if (!_host || !connected || local == null) return;
    try {
      await local.sendText(
        _endedSignal,
        options: SendTextOptions(topic: livestreamControlTopic),
      );
    } catch (_) {}
  }

  LocalParticipant get _publisher {
    if (!_host || !connected || _room?.localParticipant == null) {
      throw StateError('Chỉ chủ phiên đang kết nối được phát video.');
    }
    return _room!.localParticipant!;
  }

  Future<void> _request(MeetingMedia media) async {
    final result = await _access.request(media);
    _checkOpen();
    if (result == MediaAccessResult.granted) return;
    if (result == MediaAccessResult.simulatorCamera) {
      throw StateError('Hãy dùng điện thoại thật để phát camera.');
    }
    final label = media == MeetingMedia.camera ? 'camera' : 'micro';
    throw StateError(
      'Cần quyền $label để phát live. Hãy cấp quyền trong Cài đặt.',
    );
  }

  Future<void> startBroadcast() => _serialize(() async {
    final local = _publisher;
    await _request(MeetingMedia.camera);
    await _request(MeetingMedia.microphone);
    try {
      await local.setCameraEnabled(true);
      _checkOpen();
      await local.setMicrophoneEnabled(true);
      _checkOpen();
      await _microphones?.apply(reselect: true);
      _changed();
    } catch (_) {
      await _stopTracks();
      rethrow;
    }
  });

  Future<void> stopBroadcast() => _serialize(_stopTracks);

  Future<void> _stopTracks() async {
    final local = _room?.localParticipant;
    if (local == null || !_host) return;
    try {
      await local.setCameraEnabled(false);
    } finally {
      await local.setMicrophoneEnabled(false);
      _changed();
    }
  }

  Future<void> toggleMicrophone() => _serialize(() async {
    final local = _publisher;
    final enable = !microphoneEnabled;
    if (enable) await _request(MeetingMedia.microphone);
    await local.setMicrophoneEnabled(enable);
    if (enable) await _microphones?.apply(reselect: true);
    _changed();
  });

  Future<void> toggleCamera() => _serialize(() async {
    final local = _publisher;
    final enable = !cameraEnabled;
    if (enable) await _request(MeetingMedia.camera);
    await local.setCameraEnabled(enable);
    _changed();
  });

  Future<void> switchCamera() => _serialize(() async {
    _publisher;
    final track = _videoTrack;
    if (track is! LocalVideoTrack) return;
    final next = _cameraPosition == CameraPosition.front
        ? CameraPosition.back
        : CameraPosition.front;
    await track.setCameraPosition(next);
    _cameraPosition = next;
    _changed();
  });

  VideoTrack? get _videoTrack {
    final room = _room;
    if (room == null) return null;
    final Participant? host = _host
        ? room.localParticipant
        : room.remoteParticipants[_hostIdentity];
    if (host == null) return null;
    for (final publication in host.videoTrackPublications) {
      if (publication.source == TrackSource.camera && !publication.muted) {
        final track = publication.track;
        if (track is VideoTrack) return track;
      }
    }
    return null;
  }

  Future<void> _tearDown() async {
    final room = _room;
    _room = null;
    _microphones?.dispose();
    _microphones = null;
    await _listener?.dispose();
    _listener = null;
    room?.removeListener(_changed);
    room?.unregisterTextStreamHandler(livestreamChatTopic);
    room?.unregisterTextStreamHandler(livestreamControlTopic);
    try {
      await room?.dispose();
    } finally {
      if (_holdsAudioSession) {
        _holdsAudioSession = false;
        await MeetingAudioSession.release();
      }
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _queue.then((_) => _tearDown());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}

class LivestreamVideo extends StatelessWidget {
  const LivestreamVideo({
    super.key,
    required this.controller,
    required this.placeholder,
  });
  final LivestreamMediaController controller;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final track = controller._videoTrack;
      return track == null
          ? placeholder
          : VideoTrackRenderer(
              track,
              fit: VideoViewFit.contain,
              mirrorMode:
                  controller._host &&
                      controller._cameraPosition == CameraPosition.front
                  ? VideoViewMirrorMode.mirror
                  : VideoViewMirrorMode.off,
            );
    },
  );
}
