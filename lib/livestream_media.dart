import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import 'media_access.dart';
import 'meeting_audio_session.dart';
import 'microphone_router.dart';

const livestreamChatTopic = 'hisale.livestream.chat';
const livestreamControlTopic = 'hisale.livestream.control';
const _endedSignal = 'ended';
const livestreamChatMaxCharacters = 500;
const livestreamReactionTopic = 'hisale.livestream.reaction';

/// Viewer-side boost on the host's voice. WebRTC accepts 0–10, but past 3x
/// the limiter starts squashing loud syllables and the voice turns harsh.
/// Viewers never open their mic, so the boost cannot echo back.
const livestreamMinSpeakerGain = 1.0;
const livestreamMaxSpeakerGain = 3.0;

/// Taps each participant gets per reaction in one broadcast.
const livestreamReactionLimit = 5;

enum LivestreamReaction { heart, like }

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
    this.isHost = false,
  });
  final String id;
  final String senderName;
  final String text;
  final DateTime sentAt;
  final bool isOwn;

  /// Sent by the broadcaster, judged by room identity and never by what the
  /// sender claims.
  final bool isHost;
}

/// The broadcast media path and its chat, both over the LiveKit room.
/// Session state belongs to the application.
class LivestreamMediaController extends ChangeNotifier {
  LivestreamMediaController({this.onMessage, this.onEnded});

  /// Called for every message another participant sends.
  void Function(LivestreamChatMessage message)? onMessage;

  /// Called once the host ends the broadcast or the server deletes the room.
  void Function()? onEnded;

  /// Called for every reaction another participant sends, at most
  /// [livestreamReactionLimit] per sender and kind.
  void Function(LivestreamReaction reaction)? onReaction;

  /// The name shown on this device's chat. It travels with every message
  /// because the backend's LiveKit name can be empty or an id.
  String? displayName;

  /// Reactions counted per `identity/kind` so a modified client cannot
  /// flood everyone's screen.
  final _reactionsBySender = <String, int>{};

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

  /// Everyone in the room, the host and this device included.
  int get viewerCount {
    final room = _room;
    if (room == null || !connected) return 0;
    return room.remoteParticipants.length + 1;
  }

  /// Kept while the app runs so every broadcast opens at the chosen level.
  static double _speakerGain = 2.0;
  double get speakerGain => _speakerGain;

  Future<void> setSpeakerGain(double gain) async {
    _speakerGain = gain.clamp(
      livestreamMinSpeakerGain,
      livestreamMaxSpeakerGain,
    );
    _changed();
    final participants = _room?.remoteParticipants.values;
    for (final participant in participants ?? const <RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        await _applySpeakerGain(publication.track);
      }
    }
  }

  Future<void> _applySpeakerGain(Track? track) async {
    if (track is! RemoteAudioTrack) return;
    try {
      await rtc.Helper.setVolume(_speakerGain, track.mediaStreamTrack);
    } catch (error) {
      debugPrint('[HiSale Livestream] Could not set speaker volume: $error');
    }
  }

  /// The broadcaster's name as the room knows it, once it is present.
  String? get hostName {
    final room = _room;
    if (room == null) return null;
    final name = _host
        ? (displayName ?? room.localParticipant?.name)
        : room.remoteParticipants[_currentHostIdentity]?.name;
    final value = name?.trim() ?? '';
    return value.isEmpty ? null : value;
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

  /// [hostIdentity] may be null while rooms come from the meeting API, which
  /// does not say who broadcasts: the host then announces itself through its
  /// metadata and viewers follow whoever does (or whoever shows a camera).
  Future<void> connect({
    required String serverUrl,
    required String token,
    required String? hostIdentity,
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
        // Same voice processing as the meeting: echo cancellation, noise
        // suppression and voice isolation clean the room; the high-pass
        // filter (off by default) drops rumble and hum; AGC keeps the level
        // steady so loud speech does not clip.
        defaultAudioCaptureOptions: AudioCaptureOptions(
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          highPassFilter: true,
          voiceIsolation: true,
        ),
        // A broadcast is listened to closely: the music preset (48 kbps)
        // keeps the voice clear, and without DTX quiet passages are not
        // replaced by comfort noise that sounds like crackle.
        defaultAudioPublishOptions: AudioPublishOptions(
          encoding: AudioEncoding.presetMusic,
          dtx: false,
        ),
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
      ..on<ParticipantMetadataUpdatedEvent>((_) => _changed())
      ..on<RoomReconnectingEvent>((_) => _changed())
      ..on<RoomReconnectedEvent>((_) {
        connectionError = null;
        if (_host) unawaited(_microphones?.apply(reselect: true));
        _changed();
      })
      ..on<TrackSubscribedEvent>((event) {
        unawaited(_applySpeakerGain(event.track));
        _changed();
      })
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
    _reactionsBySender.clear();
    room.registerTextStreamHandler(livestreamReactionTopic, (reader, identity) {
      unawaited(_receiveReaction(room, reader, identity));
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
                  hostIdentity != null && local.identity != hostIdentity)) ||
          // Meeting tokens let everyone publish; only a viewer never does.
          (!isHost && hostIdentity != null && local.permissions.canPublish)) {
        throw StateError('Quyền kết nối livestream không hợp lệ.');
      }
      if (isHost && hostIdentity == null) {
        _hostIdentity = local.identity;
        try {
          await local.setMetadata(jsonEncode({'role': 'host'}));
        } catch (_) {
          // Viewers still find the host by its camera.
        }
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
      onMessage?.call(
        LivestreamChatMessage(
          id:
              reader.info?.id ??
              '$identity-${DateTime.now().microsecondsSinceEpoch}',
          senderName: _senderName(
            reader.info?.attributes[_nameAttribute],
            room.remoteParticipants[identity]?.name,
            identity,
          ),
          isHost: identity == _currentHostIdentity,
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
      if (signal == _endedSignal && identity == _currentHostIdentity) {
        _notifyEnded();
      }
    } catch (_) {}
  }

  static DateTime _sentAt(int milliseconds) =>
      milliseconds <= 0 || milliseconds > 8640000000000000
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(milliseconds);

  Future<void> _receiveReaction(
    Room room,
    TextStreamReader reader,
    String identity,
  ) async {
    try {
      final name = (await reader.readAll()).trim();
      if (_room != room || _closed) return;
      final reaction = LivestreamReaction.values
          .where((value) => value.name == name)
          .firstOrNull;
      if (reaction == null) return;
      final key = '$identity/${reaction.name}';
      final count = _reactionsBySender[key] ?? 0;
      if (count >= livestreamReactionLimit) return;
      _reactionsBySender[key] = count + 1;
      onReaction?.call(reaction);
    } catch (_) {}
  }

  Future<void> sendReaction(LivestreamReaction reaction) async {
    _checkOpen();
    final local = _room?.localParticipant;
    if (!connected || local == null || !local.permissions.canPublishData) {
      throw StateError('Chưa kết nối livestream. Hãy thử lại.');
    }
    await local.sendText(
      reaction.name,
      options: SendTextOptions(topic: livestreamReactionTopic),
    );
  }

  Future<LivestreamChatMessage> sendChat(String text) async {
    _checkOpen();
    final local = _room?.localParticipant;
    if (!connected || local == null || !local.permissions.canPublishData) {
      throw StateError('Chat chưa kết nối. Hãy thử lại.');
    }
    final name = _senderName(displayName, local.name, local.identity);
    final info = await local.sendText(
      text,
      options: SendTextOptions(
        topic: livestreamChatTopic,
        attributes: {_nameAttribute: name},
      ),
    );
    return LivestreamChatMessage(
      id: info.id,
      senderName: name,
      text: text,
      sentAt: _sentAt(info.timestamp),
      isOwn: true,
      isHost: _host,
    );
  }

  static const _nameAttribute = 'name';

  /// Like the meeting: the announced name, then LiveKit's, then the identity.
  static String _senderName(String? announced, String? liveKit, String id) {
    for (final value in [announced, liveKit, id]) {
      final name = value?.trim() ?? '';
      if (name.isNotEmpty) return name.characters.take(60).toString();
    }
    return 'Người xem';
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

  String? get _currentHostIdentity {
    final known = _hostIdentity;
    final room = _room;
    if (known != null || room == null) return known;
    final remotes = room.remoteParticipants.values;
    for (final participant in remotes) {
      if (_role(participant) == 'host') return participant.identity;
    }
    for (final participant in remotes) {
      if (participant.videoTrackPublications.any(
        (publication) => publication.source == TrackSource.camera,
      )) {
        return participant.identity;
      }
    }
    return null;
  }

  static String? _role(Participant participant) {
    try {
      final value = jsonDecode(participant.metadata ?? '');
      return value is Map ? value['role']?.toString() : null;
    } on FormatException {
      return null;
    }
  }

  VideoTrack? get _videoTrack {
    final room = _room;
    if (room == null) return null;
    final Participant? host = _host
        ? room.localParticipant
        : room.remoteParticipants[_currentHostIdentity];
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
    room?.unregisterTextStreamHandler(livestreamReactionTopic);
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
    this.fit = VideoViewFit.contain,
  });
  final LivestreamMediaController controller;
  final Widget placeholder;

  /// Cover fills the screen edge to edge, as on TikTok.
  final VideoViewFit fit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final track = controller._videoTrack;
      return track == null
          ? placeholder
          : VideoTrackRenderer(
              track,
              fit: fit,
              mirrorMode:
                  controller._host &&
                      controller._cameraPosition == CameraPosition.front
                  ? VideoViewMirrorMode.mirror
                  : VideoViewMirrorMode.off,
            );
    },
  );
}
