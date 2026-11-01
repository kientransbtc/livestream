import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

// LiveKit 2.13.0 does not export its broadcast controls from the main library.
// ignore: implementation_imports
import 'package:livekit_client/src/managers/broadcast_manager.dart';
import 'package:permission_handler/permission_handler.dart';

import 'demo_livekit_token.dart';
import 'live_chat.dart';
import 'live_chat_overlay.dart';
import 'media_access.dart';
import 'meeting_audio_session.dart';
import 'microphone_router.dart';
import 'screen_share.dart';

void main() {
  BroadcastManager().shouldPublishTrack = false;
  runApp(const LiveKitDemoApp());
}

class LiveKitDemoApp extends StatelessWidget {
  const LiveKitDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hisale Coaching Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF168BE7)),
      ),
      home: const LiveKitDemoPage(),
    );
  }
}

///
/// Demo này dùng data packet để mô phỏng việc host duyệt giơ tay, bật/tắt mic,
/// camera và chia sẻ màn hình của thành viên. Khi làm thật, BE phải kiểm quyền
/// và gọi UpdateParticipant/MutePublishedTrack của LiveKit; không tin quyết
/// định approve từ một client khác.
class LiveKitDemoPage extends StatefulWidget {
  const LiveKitDemoPage({
    super.key,
    this.initialRoomName,
    this.initialRoomTitle,
    this.initialParticipantName,
    this.serverUrl,
    this.participantToken,
    this.initialRole,
    this.autoConnect = false,
    this.appBarAction,
  });

  /// Optional values used by the HiSale host app. When omitted, the page
  /// keeps the standalone demo flow and creates a local demo token.
  final String? initialRoomName;
  final String? initialRoomTitle;
  final String? initialParticipantName;
  final String? serverUrl;
  final String? participantToken;
  final String? initialRole;
  final bool autoConnect;
  final Widget? appBarAction;

  @override
  State<LiveKitDemoPage> createState() => _LiveKitDemoPageState();
}

class _LiveKitDemoPageState extends State<LiveKitDemoPage> {
  final _roomController = TextEditingController();
  final _nameController = TextEditingController();
  final _joinFormKey = GlobalKey<FormState>();
  final _mediaAccess = MediaAccess();
  final ValueNotifier<Room?> _roomNotifier = ValueNotifier(null);
  final ValueNotifier<int> _preJoinRevision = ValueNotifier(0);
  final ValueNotifier<int> _meetingRevision = ValueNotifier(0);

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  LiveChatController? _chat;
  ScreenShareController? _screenShare;
  MicrophoneRouter? _microphoneRouter;
  bool _focusedScreen = false;
  String? _connectedRoomName;
  String? _knownHostIdentity;
  bool _roomRefreshScheduled = false;
  Timer? _roomChangeTimer;
  bool _roomRefreshNeedsHostResolve = false;
  bool _connecting = false;
  bool _handRaised = false;
  bool _approved = false;
  bool _screenShareApproved = false;

  // Members may use the camera freely until the host turns it off without
  // allowing it back; only a host invite unblocks it.
  bool _cameraBlocked = false;
  bool _changingMic = false;
  bool _changingCamera = false;
  bool _turningCameraOff = false;
  String? _lastScreenShareError;
  CameraPosition _cameraPosition = CameraPosition.front;
  bool _resolvingHost = false;
  bool _fullScreen = false;
  String? _focusedIdentity;
  String? _hostNotice;
  String? _error;
  final Set<String> _waitingIdentities = <String>{};
  final Set<_MemberMedia> _openHostInvites = <_MemberMedia>{};

  // Waiting room. The host's metadata carries `lobby`; while it is on, a
  // member who was not already inside waits, subscribed to nothing, until
  // the host lets them in.
  // ponytail: enforced by the clients only, like hand raising. The backend
  // should mint waiting members a canSubscribe=false token and grant it on
  // admission (UpdateParticipant) so a modified client cannot watch.
  // Rooms whose host turned the waiting room on, kept for the app run so a
  // host who rejoins does not open the doors by accident.
  static final _lobbyRooms = <String>{};
  bool _lobbyEnabled = false;
  bool _knownLobby = false;
  bool _admitted = false;
  String? _joinRequestedFrom;
  final Set<String> _joinRequests = <String>{};

  bool get _inLobby => _role != _DemoRole.host && !_admitted && _knownLobby;

  // The host's pin rides in its metadata, so members who join later see it
  // too. A member may stop following it; a new pin shows again.
  String? _pinnedIdentity;
  String? _dismissedPin;
  String? _seenPin;

  String? get _roomPin {
    if (_isHost) return _pinnedIdentity;
    final host = _hostParticipant;
    final pin = host == null ? null : _participantMetadata(host)['pinned'];
    return pin is String ? pin : null;
  }

  /// The pinned participant this viewer follows, while they are in the room.
  Participant? get _pinnedParticipant {
    final pin = _roomPin;
    if (pin == null || pin == _dismissedPin) return null;
    return _participants.where((p) => p.identity == pin).firstOrNull;
  }

  bool _holdsAudioSession = false;
  DateTime? _weakNetworkWarnedAt;

  // Names members announce over the control channel. The backend's LiveKit
  // name can carry an id, and not every token lets a member rename itself.
  final Map<String, String> _announcedNames = <String, String>{};

  void _refreshPreJoin() => _preJoinRevision.value++;

  void _refreshMeeting() => _meetingRevision.value++;

  void _dismissHostNotice() {
    _hostNotice = null;
    _refreshMeeting();
  }

  static bool _isLandscape(BuildContext context) =>
      MediaQuery.orientationOf(context) == Orientation.landscape;

  /// Gain on everyone else's voice; WebRTC accepts 0–10 and limits peaks
  /// after mixing. Phones play calls through the quieter voice-processing
  /// path, where unity gain sounded too soft. Kept while the app runs.
  static final _speakerGain = ValueNotifier<double>(3.0);

  /// The most the boost reaches while the phone's own mic is open. That mic
  /// sits next to the speaker: at 300% the voices came back into it as echo,
  /// and the echo canceller then cut the speaker's own voice. An external
  /// mic or a headset is far enough from the speaker for the full boost.
  static const _openPhoneMicGain = 1.5;

  bool _openingMic = false;
  double? _appliedGain;

  double get _remoteGain {
    final gain = _speakerGain.value;
    final phoneMicOpen =
        (_openingMic || _micEnabled) &&
        !(_microphoneRouter?.usesExternalInput ?? false);
    return phoneMicOpen && gain > _openPhoneMicGain ? _openPhoneMicGain : gain;
  }

  Future<void> _applySpeakerGain(Track? track) async {
    if (track is! RemoteAudioTrack) return;
    try {
      await rtc.Helper.setVolume(_remoteGain, track.mediaStreamTrack);
    } catch (error) {
      debugPrint('[Hisale Coaching Hub] Could not set speaker volume: $error');
    }
  }

  /// Re-applies the gain when the slider, the mic state or the mic in use
  /// changes it.
  void _syncSpeakerGain() {
    final gain = _remoteGain;
    if (gain == _appliedGain) return;
    _appliedGain = gain;
    final participants = _room?.remoteParticipants.values;
    for (final participant in participants ?? const <RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        unawaited(_applySpeakerGain(publication.track));
      }
    }
  }

  bool get _isBackendAutoConnect =>
      widget.autoConnect && widget.participantToken?.trim().isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _speakerGain.addListener(_syncSpeakerGain);
    _roomController.text = widget.initialRoomName ?? '';
    _nameController.text = widget.initialParticipantName ?? '';
    if (widget.initialRole?.toLowerCase() == _DemoRole.host.name) {
      _role = _DemoRole.host;
    }
    if (widget.autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_connect());
      });
    }
  }

  bool get _isHost => (_connectedRole ?? _role) == _DemoRole.host;
  _DemoRole _role = _DemoRole.audience;
  _DemoRole? _connectedRole;

  bool get _micEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;

  bool get _cameraEnabled =>
      _room?.localParticipant?.isCameraEnabled() ?? false;

  bool get _canUseMicrophone => _isHost || _approved;

  bool get _canShareScreen => _isHost || _screenShareApproved;

  bool get _canUseCamera => _isHost || !_cameraBlocked;

  bool get _needsHostApproval => !_canUseMicrophone || !_canShareScreen;

  List<Participant> get _participants => [
    if (_room?.localParticipant != null) _room!.localParticipant!,
    ...?_room?.remoteParticipants.values,
  ];

  Map<String, dynamic> _participantMetadata(Participant participant) {
    try {
      final value = jsonDecode(participant.metadata ?? '{}');
      return value is Map<String, dynamic> ? value : {};
    } on FormatException {
      return {};
    }
  }

  Participant? get _hostParticipant {
    final candidates = _participants.where((participant) {
      if (participant == _room?.localParticipant &&
          _connectedRole != _DemoRole.host) {
        return false;
      }
      return _participantMetadata(participant)['role'] == 'host';
    }).toList();
    candidates.sort((a, b) {
      // An established host keeps the room when another host joins. Concurrent
      // claims use the same server join time + identity ordering on every client.
      final aClaiming = _participantMetadata(a)['host_state'] == 'claiming';
      final bClaiming = _participantMetadata(b)['host_state'] == 'claiming';
      if (aClaiming != bClaiming) return aClaiming ? 1 : -1;
      return _byJoinOrder(a, b);
    });
    return candidates.firstOrNull;
  }

  /// Hosts who joined while another host held the room wait as members. When
  /// the room has no host left, the one that joined first takes it back.
  Participant? get _hostSuccessor {
    final local = _room?.localParticipant;
    final candidates = _participants.where((participant) {
      if (participant == local) return _role == _DemoRole.host;
      return _participantMetadata(participant)['host_eligible'] == true;
    }).toList()..sort(_byJoinOrder);
    return candidates.firstOrNull;
  }

  static int _byJoinOrder(Participant a, Participant b) {
    final joinedOrder = a.joinedAt.compareTo(b.joinedAt);
    return joinedOrder != 0 ? joinedOrder : a.identity.compareTo(b.identity);
  }

  Future<void> _resolveHost() async {
    final room = _room;
    final local = room?.localParticipant;
    if (room == null || local == null || _resolvingHost) return;
    if (!_isHost) return _takeOverHost(room, local);
    final host = _hostParticipant;
    if (host == null) return;
    _resolvingHost = true;
    var acted = false;
    try {
      if (host.identity != local.identity) {
        if (!mounted) return;
        acted = true;
        _connectedRole = _DemoRole.audience;
        _approved = false;
        _screenShareApproved = false;
        _hostNotice =
            'Phòng đã có host. Bạn chỉ tham gia với tư cách thành viên.';
        _refreshMeeting();
        await local.setMicrophoneEnabled(false);
        // Others read the flag to hand the room back when the host leaves.
        await local.setMetadata(
          jsonEncode({'role': 'audience', 'host_eligible': true}),
        );
      } else if (_participantMetadata(local)['host_state'] == 'claiming') {
        acted = true;
        await local.setMetadata(_hostMetadata);
      }
    } catch (_) {
      if (_room == room) {
        await _disconnect(
          message:
              'Chưa đồng bộ được vai trò trong phòng. Bấm Vào phòng để thử lại.',
        );
      }
    } finally {
      _resolvingHost = false;
      if (mounted && _room == room) {
        // This runs after every room event; most of the time nothing changes.
        if (acted) _refreshMeeting();
        if (_isHost && _hostParticipant?.identity != local.identity) {
          unawaited(_resolveHost());
        }
      }
    }
  }

  /// Every client picks the same successor, so only one claims the room. If
  /// two still claim at once, [_resolveHost] keeps the earlier join.
  Future<void> _takeOverHost(Room room, LocalParticipant local) async {
    if (_role != _DemoRole.host || _hostParticipant != null) return;
    if (_hostSuccessor?.identity != local.identity) return;
    _resolvingHost = true;
    try {
      _connectedRole = _DemoRole.host;
      _handRaised = false;
      // Keep the previous host's waiting room and pin.
      _lobbyEnabled = _knownLobby || _lobbyRooms.contains(_connectedRoomName);
      _pinnedIdentity = _seenPin;
      _hostNotice = 'Host trước đã rời phòng. Bạn đã trở thành host.';
      _refreshMeeting();
      await local.setMetadata(_hostMetadata);
    } catch (_) {
      if (_room == room) {
        await _disconnect(
          message:
              'Chưa đồng bộ được vai trò trong phòng. Bấm Vào phòng để thử lại.',
        );
      }
    } finally {
      _resolvingHost = false;
      if (mounted && _room == room) {
        _refreshMeeting();
        unawaited(_resolveHost());
      }
    }
  }

  /// The room notifies on every event, including the speaker levels LiveKit
  /// sends several times a second while someone talks. Rebuilding the whole
  /// meeting for each kept the Dart GC busy (half the app's CPU on an iPhone
  /// 16). Events that change the layout have their own listeners, so this
  /// catch-all only needs to run a few times a second.
  void _onRoomChanged() {
    if (_roomChangeTimer?.isActive ?? false) return;
    _roomChangeTimer = Timer(
      const Duration(milliseconds: 250),
      _refreshParticipants,
    );
  }

  void _refreshParticipants() {
    if (!mounted || _room == null) return;
    _syncSpeakerGain();
    final host = _hostParticipant;
    if (host != null) _knownHostIdentity = host.identity;
    _followLobby();
    final pin = _roomPin;
    // While the room has no host the last pin is kept for whoever takes over.
    if ((_isHost || host != null) && pin != _seenPin) {
      _seenPin = pin;
      _dismissedPin = null;
      // A new pin takes the stage from whatever this viewer picked.
      if (pin != null) _clearFocus();
    }
    // Room events can arrive while no Flutter frame is scheduled (for example,
    // when a participant joins without publishing video). Notify the meeting
    // builder immediately, then reconcile focus and host state after this frame.
    _refreshMeeting();
    _scheduleRoomRefresh(resolveHost: true);
  }

  String get _hostMetadata => jsonEncode({
    'role': 'host',
    'host_state': 'active',
    if (_lobbyEnabled) 'lobby': true,
    if (_pinnedIdentity != null) 'pinned': _pinnedIdentity,
  });

  Future<void> _setPin(String? identity) async {
    final local = _room?.localParticipant;
    if (!_isHost || local == null) return;
    final previous = _pinnedIdentity;
    _pinnedIdentity = identity;
    _clearFocus();
    _refreshMeeting();
    try {
      await local.setMetadata(_hostMetadata);
    } catch (_) {
      if (!mounted || _room?.localParticipant != local) return;
      _pinnedIdentity = previous;
      _refreshMeeting();
      _showMediaError('Chưa ghim được. Vui lòng thử lại.');
    }
  }

  void _togglePin(Participant participant) {
    final pinned = _pinnedIdentity == participant.identity;
    unawaited(_setPin(pinned ? null : participant.identity));
    _showMediaError(
      pinned
          ? 'Đã bỏ ghim. Màn hình chính trở về mặc định.'
          : 'Đã ghim ${_participantDisplayName(participant)} lên màn hình chính của cả phòng.',
    );
  }

  /// Follows the host's waiting room. A host still claiming the room has
  /// not published it yet. Hosts waiting as members follow it too, to keep
  /// it if they take the room over, but never wait themselves.
  void _followLobby() {
    if (_isHost) return;
    final host = _hostParticipant;
    final wasInLobby = _inLobby;
    final metadata = host == null ? null : _participantMetadata(host);
    if (metadata != null && metadata['host_state'] != 'claiming') {
      _knownLobby = metadata['lobby'] == true;
      // Whoever is inside while the doors are open stays in.
      if (!_knownLobby) _admitted = true;
    }
    if (_inLobby != wasInLobby) _syncSubscriptions();
    // Asks each new host once: a host who joins later never saw the request.
    if (_inLobby && host != null && _joinRequestedFrom != host.identity) {
      unawaited(_requestToJoin(host.identity));
    }
  }

  /// Members join with autoSubscribe off: nothing plays until they are in.
  void _syncSubscriptions() {
    if (_role == _DemoRole.host) return;
    final participants = _room?.remoteParticipants.values;
    for (final participant in participants ?? const <RemoteParticipant>[]) {
      for (final publication in participant.trackPublications.values) {
        unawaited(
          _inLobby ? publication.unsubscribe() : publication.subscribe(),
        );
      }
    }
  }

  Future<void> _requestToJoin(String hostIdentity) async {
    _joinRequestedFrom = hostIdentity;
    try {
      await _send({'type': 'join_request'}, destination: hostIdentity);
    } catch (_) {
      // Asked again on the next room event.
      if (_joinRequestedFrom == hostIdentity) _joinRequestedFrom = null;
    }
  }

  Future<void> _setLobby(bool enabled) async {
    final room = _room;
    final local = room?.localParticipant;
    final roomName = _connectedRoomName;
    if (!_isHost || local == null || roomName == null) return;
    void apply(bool value) {
      _lobbyEnabled = value;
      value ? _lobbyRooms.add(roomName) : _lobbyRooms.remove(roomName);
      // Members read the flag off: everyone waiting gets in on their own.
      if (!value) _joinRequests.clear();
      _refreshMeeting();
    }

    apply(enabled);
    try {
      await local.setMetadata(_hostMetadata);
    } catch (_) {
      if (!mounted || _room != room) return;
      apply(!enabled);
      _showMediaError('Chưa đổi được phòng chờ. Vui lòng thử lại.');
    }
  }

  Future<void> _answerJoin(String identity, {required bool admit}) async {
    if (!_isHost || _room == null) return;
    _joinRequests.remove(identity);
    _refreshMeeting();
    try {
      await _send({
        'type': admit ? 'join_admitted' : 'join_rejected',
      }, destination: identity);
    } catch (_) {
      if (!mounted || _room == null) return;
      _joinRequests.add(identity);
      _refreshMeeting();
      _showMediaError('Chưa gửi được. Vui lòng thử lại.');
    }
  }

  void _scheduleRoomRefresh({required bool resolveHost}) {
    if (!mounted || _room == null) return;
    _roomRefreshNeedsHostResolve = _roomRefreshNeedsHostResolve || resolveHost;
    if (_roomRefreshScheduled) return;
    _roomRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final shouldResolveHost = _roomRefreshNeedsHostResolve;
      _roomRefreshNeedsHostResolve = false;
      _roomRefreshScheduled = false;
      if (!mounted || _room == null) return;
      final participants = _participants;
      final identities = participants.map((p) => p.identity).toSet();
      final waiting = _waitingIdentities.length;
      _waitingIdentities.removeWhere(
        (identity) => !identities.contains(identity),
      );
      final joining = _joinRequests.length;
      _joinRequests.removeWhere((identity) => !identities.contains(identity));
      var changed =
          _waitingIdentities.length != waiting ||
          _joinRequests.length != joining;
      if (_focusedIdentity != null && !identities.contains(_focusedIdentity)) {
        _focusedIdentity = null;
        _focusedScreen = false;
        _fullScreen = false;
        changed = true;
      }
      if (_focusedScreen &&
          !participants.any(
            (p) => p.identity == _focusedIdentity && p.isScreenShareEnabled(),
          )) {
        _focusedIdentity = null;
        _focusedScreen = false;
        _fullScreen = false;
        changed = true;
      }
      // The event itself was already shown by the immediate refresh.
      if (changed) _refreshMeeting();
      if (shouldResolveHost) unawaited(_resolveHost());
    });
  }

  @override
  void dispose() {
    final room = _room;
    final listener = _listener;
    final chat = _chat;
    final share = _screenShare;
    final holdsAudioSession = _holdsAudioSession;
    _room = null;
    _listener = null;
    _chat = null;
    _screenShare = null;
    _holdsAudioSession = false;
    _microphoneRouter?.dispose();
    _microphoneRouter = null;
    // Start the LiveKit leave signal before awaiting screen-share cleanup.
    // iOS can still be waiting for the ReplayKit picker/broadcast callback.
    final disconnection = room?.disconnect();
    chat?.dispose();
    listener?.dispose();
    room?.removeListener(_onRoomChanged);
    _roomChangeTimer?.cancel();
    unawaited(() async {
      try {
        await share?.close();
      } catch (_) {}
      try {
        await disconnection;
      } catch (_) {}
      try {
        await room?.dispose();
      } catch (_) {}
      if (holdsAudioSession) await MeetingAudioSession.release();
    }());
    _roomController.dispose();
    _nameController.dispose();
    _roomNotifier.dispose();
    _preJoinRevision.dispose();
    _meetingRevision.dispose();
    _speakerGain.removeListener(_syncSpeakerGain);
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting || _room != null) return;
    final usesBackendToken = widget.participantToken?.trim().isNotEmpty == true;
    if (!usesBackendToken &&
        !(_joinFormKey.currentState?.validate() ?? false)) {
      return;
    }
    final roomName =
        (widget.initialRoomName?.trim().isNotEmpty == true
                ? widget.initialRoomName
                : _roomController.text)
            .toString()
            .trim();
    final participantName =
        (widget.initialParticipantName?.trim().isNotEmpty == true
                ? widget.initialParticipantName
                : _nameController.text)
            .toString()
            .trim();
    if (roomName.isEmpty || participantName.isEmpty) {
      if (mounted) {
        _error = 'Thiếu thông tin phòng hoặc tên người dùng.';
        _refreshPreJoin();
      }
      return;
    }

    FocusScope.of(context).unfocus();
    final selectedRole = _role;
    Room? pendingRoom;
    EventsListener<RoomEvent>? pendingListener;
    LiveChatController? pendingChat;
    var holdsAudioSession = false;
    _connecting = true;
    _error = null;
    _hostNotice = null;
    _refreshPreJoin();
    try {
      final token = usesBackendToken
          ? widget.participantToken!.trim()
          : createDemoLiveKitToken(
              room: roomName,
              participantName: participantName,
              role: selectedRole.name,
            );
      final serverUrl = widget.serverUrl?.trim().isNotEmpty == true
          ? widget.serverUrl!.trim()
          : liveKitDemoUrl;
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // Voice processing runs before screen-share audio is mixed in, so it
          // cleans the presenter's mic without filtering the shared media.
          // The high-pass filter (off by default) removes rumble and hum.
          defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
            highPassFilter: true,
            voiceIsolation: true,
          ),
          defaultCameraCaptureOptions: CameraCaptureOptions(
            cameraPosition: CameraPosition.front,
          ),
          defaultVideoPublishOptions: cameraPublishOptions,
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
            useiOSBroadcastExtension: true,
            maxFrameRate: 30,
            // Keep the 720p share light enough for mobile uplinks while
            // allowing video playback to update at 30 fps instead of the
            // previous 15 fps cap.
            params: VideoParameters(
              dimensions: VideoDimensionsPresets.h720_169,
              encoding: VideoEncoding(maxBitrate: 2_000_000, maxFramerate: 30),
            ),
          ),
        ),
      );
      pendingRoom = room;
      // Register before connecting so chat sent just after joining is received.
      final chat = LiveChatController.forRoom(
        room,
        localDisplayName: widget.initialParticipantName,
        // Members' images go to the room host alone.
        isHost: () => _isHost,
        hostIdentity: () => _hostParticipant?.identity,
        announcedName: (identity) => _announcedNames[identity],
      );
      pendingChat = chat;
      final listener = room.createListener();
      pendingListener = listener;
      listener.on<DataReceivedEvent>(_onDataReceived);
      listener.on<RoomDisconnectedEvent>((event) {
        if (!mounted || _room != room) return;
        unawaited(
          _disconnect(
            message:
                'Đã ngắt kết nối LiveKit (${event.reason ?? 'không rõ nguyên nhân'}). Bấm Vào phòng để thử lại.',
          ),
        );
      });
      listener.on<ParticipantConnectedEvent>((_) {
        _refreshParticipants();
      });
      listener.on<ParticipantDisconnectedEvent>((event) {
        final participantWasHost =
            event.participant.identity == _knownHostIdentity ||
            _participantMetadata(event.participant)['role'] == 'host';
        if (participantWasHost && !_isHost) {
          _knownHostIdentity = null;
          _hostNotice = 'Chủ phòng đã rời khỏi phòng.';
        }
        _announcedNames.remove(event.participant.identity);
        _refreshParticipants();
      });
      listener.on<ParticipantMetadataUpdatedEvent>(
        (_) => _refreshParticipants(),
      );
      listener.on<ParticipantNameUpdatedEvent>((_) => _refreshParticipants());
      listener.on<RoomReconnectedEvent>((_) {
        // Packets sent while the connection was down are lost.
        unawaited(_announceName());
        _refreshParticipants();
      });
      listener.on<TrackMutedEvent>((_) => _refreshParticipants());
      listener.on<TrackUnmutedEvent>((_) => _refreshParticipants());
      listener.on<TrackPublishedEvent>((event) {
        if (selectedRole != _DemoRole.host && !_inLobby) {
          unawaited(event.publication.subscribe());
        }
        _onScreenPublished(event.participant, event.publication.source);
        _refreshParticipants();
      });
      listener.on<TrackUnpublishedEvent>((_) => _refreshParticipants());
      listener.on<TrackSubscribedEvent>((event) {
        unawaited(_applySpeakerGain(event.track));
        if (mounted) _refreshMeeting();
      });
      listener.on<TrackUnsubscribedEvent>((_) {
        if (mounted) _refreshMeeting();
      });
      listener.on<LocalTrackPublishedEvent>((event) {
        _onScreenPublished(event.participant, event.publication.source);
        _refreshParticipants();
      });
      listener.on<LocalTrackUnpublishedEvent>((_) {
        _refreshParticipants();
      });
      listener.on<ParticipantConnectionQualityUpdatedEvent>((event) {
        if (event.participant is LocalParticipant) {
          _warnWeakNetwork(event.connectionQuality);
        }
      });
      // Before connecting, so remote audio never starts in LiveKit's
      // listen-only session.
      await MeetingAudioSession.acquire();
      holdsAudioSession = true;
      // Members subscribe themselves once the waiting room lets them in.
      await room.connect(
        serverUrl,
        token,
        connectOptions: ConnectOptions(
          autoSubscribe: selectedRole == _DemoRole.host,
        ),
      );
      if (!mounted) {
        chat.dispose();
        await listener.dispose();
        await room.dispose();
        await MeetingAudioSession.release();
        return;
      }
      _room = room;
      _holdsAudioSession = true;
      holdsAudioSession = false;
      room.addListener(_onRoomChanged);
      _knownHostIdentity = _hostParticipant?.identity;
      _connectedRoomName = roomName;
      _screenShare = ScreenShareController.forRoom(room)
        ..addListener(_onScreenShareChanged);
      // The full boost is safe with a mic away from the phone's speaker.
      _microphoneRouter = MicrophoneRouter()..addListener(_syncSpeakerGain);
      unawaited(_microphoneRouter!.apply());
      _listener = listener;
      _chat = chat..addListener(_refreshChat);
      _connectedRole = selectedRole;
      _lobbyEnabled =
          selectedRole == _DemoRole.host && _lobbyRooms.contains(roomName);
      // Nobody keeps the doors in an empty room.
      if (_hostParticipant == null) _admitted = true;
      _followLobby();
      _syncSubscriptions();
      _roomNotifier.value = room;
      _syncLocalParticipantName(room);
      unawaited(_announceName());
      _refreshMeeting();
      final permissions = room.localParticipant!.permissions;
      if (!permissions.canSubscribe) {
        _showMediaError(
          'Token LiveKit chưa cấp quyền nghe track. BE cần cấp canSubscribe=true cho thành viên.',
        );
      } else if (!permissions.canPublishData) {
        _showMediaError(_dataPermissionMissing);
      }
      await _resolveHost();
      // A host whose token carries no claim never rewrote its metadata.
      if (_isHost && _lobbyEnabled && _room == room) {
        try {
          await room.localParticipant!.setMetadata(_hostMetadata);
        } catch (_) {}
      }
      if (kDebugMode) {
        debugPrint(
          '[Hisale Coaching Hub] Joined as ${_isHost ? 'host' : 'member'}; '
          'host: ${_hostParticipant?.identity ?? 'none'}; '
          'canPublishData: ${permissions.canPublishData}',
        );
      }
      // Join without capture. Each media button requests its device permission
      // before starting capture; a denied camera never prevents mic access.
    } catch (e) {
      pendingChat?.dispose();
      await pendingListener?.dispose();
      await pendingRoom?.dispose();
      if (holdsAudioSession || _holdsAudioSession) {
        _holdsAudioSession = false;
        await MeetingAudioSession.release();
      }
      if (mounted) {
        _room = null;
        _listener = null;
        _chat = null;
        _screenShare = null;
        _microphoneRouter?.dispose();
        _microphoneRouter = null;
        _connectedRoomName = null;
        _connectedRole = null;
        _error = 'Không kết nối được LiveKit: ${_errorMessage(e)}';
        _roomNotifier.value = null;
        _refreshPreJoin();
      }
    } finally {
      if (mounted) {
        _connecting = false;
        _refreshPreJoin();
      }
    }
  }

  String _errorMessage(Object error) => error
      .toString()
      .replaceAll(
        RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
        '[token]',
      )
      .replaceFirst('Bad state: ', '');

  void _syncLocalParticipantName(Room room) {
    final localParticipant = room.localParticipant;
    final displayName = widget.initialParticipantName?.trim() ?? '';
    if (localParticipant == null ||
        displayName.isEmpty ||
        localParticipant.name.trim() == displayName ||
        !localParticipant.permissions.canUpdateMetadata) {
      return;
    }

    unawaited(() async {
      try {
        await localParticipant.setName(displayName);
      } catch (_) {
        // The token may not allow name updates; local UI still uses displayName.
      }
    }());
  }

  void _showMediaError(String message) {
    if (!mounted || _room == null) return;
    final mediaQuery = MediaQuery.of(context);
    final bottomGap =
        82.0 + mediaQuery.viewPadding.bottom + mediaQuery.viewInsets.bottom;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
          // The content fills the bar, so a tap anywhere closes it.
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF6AA9D8)),
          ),
          backgroundColor: const Color(0xFF1B3047),
          content: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => messenger.hideCurrentSnackBar(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Text(message),
            ),
          ),
        ),
      );
  }

  Future<void> _disconnect({String? message}) async {
    final room = _room;
    final listener = _listener;
    final chat = _chat;
    final share = _screenShare;
    final holdsAudioSession = _holdsAudioSession;
    room?.removeListener(_onRoomChanged);
    _roomChangeTimer?.cancel();
    _screenShare = null;
    _holdsAudioSession = false;
    _microphoneRouter?.dispose();
    _microphoneRouter = null;
    _listener = null;
    _room = null;
    _chat = null;
    _announcedNames.clear();
    _appliedGain = null;
    _openingMic = false;
    _connectedRoomName = null;
    _knownHostIdentity = null;
    _connectedRole = null;
    _weakNetworkWarnedAt = null;
    _lobbyEnabled = false;
    _knownLobby = false;
    _admitted = false;
    _joinRequestedFrom = null;
    _joinRequests.clear();
    _pinnedIdentity = null;
    _dismissedPin = null;
    _seenPin = null;
    // Notify LiveKit immediately. Waiting for a pending screen-share operation
    // first can delay the server's participant-disconnected event by seconds.
    final disconnection = room?.disconnect();
    _roomNotifier.value = null;
    if (mounted) {
      _waitingIdentities.clear();
      _handRaised = false;
      _approved = false;
      _screenShareApproved = false;
      _cameraBlocked = false;
      _changingMic = false;
      _changingCamera = false;
      _turningCameraOff = false;
      _cameraPosition = CameraPosition.front;
      _focusedIdentity = null;
      _fullScreen = false;
      _hostNotice = null;
      _error = message;
      _focusedScreen = false;
      _connecting = true;
      _refreshMeeting();
      _refreshPreJoin();
    }
    chat?.dispose();
    try {
      await listener?.dispose();
    } catch (_) {}
    try {
      await share?.close();
    } catch (_) {}
    try {
      await disconnection;
    } catch (_) {}
    try {
      await room?.dispose();
    } catch (_) {}
    if (holdsAudioSession) await MeetingAudioSession.release();
    if (mounted) {
      _connecting = false;
      _refreshPreJoin();
    }
  }

  /// The camera keeps its resolution, so a weak uplink shows as stutter for
  /// everyone watching. Only the presenter can fix that, so tell them, but no
  /// more than once a minute.
  void _warnWeakNetwork(ConnectionQuality quality) {
    if (quality != ConnectionQuality.poor &&
        quality != ConnectionQuality.lost) {
      return;
    }
    if (!mounted || _room == null || !_cameraEnabled) return;
    final warnedAt = _weakNetworkWarnedAt;
    if (warnedAt != null &&
        DateTime.now().difference(warnedAt) < const Duration(minutes: 1)) {
      return;
    }
    _weakNetworkWarnedAt = DateTime.now();
    _showMediaError(
      'Mạng của bạn đang yếu, mọi người có thể thấy hình bị giật. Hãy chuyển sang Wi-Fi hoặc 4G mạnh hơn.',
    );
  }

  Future<void> _exitApplication() async {
    if (!mounted) return;
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222630),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Colors.white12),
        ),
        icon: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFFFF657A).withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.logout_rounded, color: Color(0xFFFF7184)),
        ),
        title: const Text(
          'Thoát Hisale Coaching Hub?',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          'Bạn sẽ rời khỏi phòng hiện tại.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    minimumSize: const Size(96, 46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Ở lại'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE44F68),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(96, 46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Thoát'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (shouldExit != true || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      // Keep the meeting on screen while the page slides away; dispose()
      // leaves the room once the route is gone. Leaving first swapped in the
      // connecting screen and ran the native teardown during the transition,
      // which made the exit stutter.
      navigator.pop();
      return;
    }
    final cleanup = _disconnect();
    await SystemNavigator.pop();
    await cleanup;
  }

  void _refreshChat() {
    // Chat notifications must rebuild the toolbar immediately. A post-frame
    // participant refresh can otherwise leave the unread badge stale while a
    // native camera platform view is running.
    if (mounted) _refreshMeeting();
  }

  void _onScreenShareChanged() {
    _refreshChat();
    final shareError = _screenShare?.error;
    if (shareError == null) {
      _lastScreenShareError = null;
    } else if (shareError != _lastScreenShareError) {
      _lastScreenShareError = shareError;
      _showMediaError(shareError);
    }
    // Stop the camera only after the screen-share track is really active. This
    // keeps the camera on when the iOS broadcast permission sheet is cancelled.
    if (_screenShare?.active == true && _cameraEnabled && !_turningCameraOff) {
      unawaited(_turnOffLocalCamera());
    }
  }

  /// Used when screen sharing starts and when the host turns the camera off.
  Future<void> _turnOffLocalCamera() async {
    final room = _room;
    final local = room?.localParticipant;
    if (_turningCameraOff ||
        room == null ||
        local == null ||
        !local.isCameraEnabled()) {
      return;
    }

    _turningCameraOff = true;
    try {
      await local.setCameraEnabled(false);
      if (mounted && _room == room) {
        _cameraPosition = CameraPosition.front;
        _refreshMeeting();
      }
    } catch (error) {
      if (mounted && _room == room) {
        _reportMediaFailure(MeetingMedia.camera, error);
      }
    } finally {
      _turningCameraOff = false;
      if (mounted && _room == room) _refreshMeeting();
    }
  }

  void _toggleChat() {
    final chat = _chat;

    if (chat == null) return;

    if (chat.visible) {
      FocusScope.of(context).unfocus();
    }

    chat.toggleVisibility();
  }

  void _onDataReceived(DataReceivedEvent event) {
    if (!mounted || event.topic != 't65-demo-control') return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(utf8.decode(event.data));
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } on FormatException {
      return;
    }
    final type = message['type'];
    final sender = event.participant?.identity;
    if (kDebugMode) {
      debugPrint(
        '[Hisale Coaching Hub] Received $type from ${sender ?? 'unknown'} '
        '(${_isHost ? 'host' : 'member'})',
      );
    }
    if (type == 'display_name' && sender != null) {
      final name = message['name'];
      if (name is! String || name.trim().isEmpty) return;
      // Everyone announces on joining; answer a newcomer, who could not
      // hear the announcements made before it arrived.
      if (!_announcedNames.containsKey(sender)) {
        unawaited(_announceName(identity: sender));
      }
      _announcedNames[sender] = name.trim().characters.take(60).toString();
      _refreshMeeting();
    } else if (type == 'join_request' && _isHost && sender != null) {
      // A request sent just before the host opened the doors.
      if (!_lobbyEnabled) {
        unawaited(_answerJoin(sender, admit: true));
        return;
      }
      _joinRequests.add(sender);
      _refreshMeeting();
    } else if ((type == 'join_admitted' || type == 'join_rejected') &&
        _inLobby &&
        sender == _hostParticipant?.identity) {
      if (type == 'join_rejected') {
        unawaited(_disconnect(message: 'Chủ phòng chưa cho bạn vào phòng.'));
        return;
      }
      _admitted = true;
      _hostNotice = 'Chủ phòng đã cho bạn vào phòng.';
      _syncSubscriptions();
      _refreshMeeting();
    } else if (type == 'hand_raise' && _isHost && sender != null) {
      _waitingIdentities.add(sender);
      _refreshMeeting();
    } else if (type == 'hand_cancel' && _isHost && sender != null) {
      _waitingIdentities.remove(sender);
      _refreshMeeting();
    } else if (type == 'hand_approved' &&
        !_isHost &&
        sender == _hostParticipant?.identity) {
      // Ignore an approval packet already in flight if the member canceled
      // their request before it arrived.
      if (!_handRaised) return;
      // The host explicitly chooses each capability. In a real room the
      // backend must enforce the same grants with LiveKit permissions.
      final allowMic = message['allow_mic'] == true;
      final allowScreenShare = message['allow_screen_share'] == true;
      final micWasApproved = _approved;
      final screenShareWasApproved = _screenShareApproved;
      // Keep previous grants when the host approves another capability later.
      _approved = _approved || allowMic;
      _screenShareApproved = _screenShareApproved || allowScreenShare;
      _handRaised = false;
      _hostNotice = _approved && _screenShareApproved
          ? 'Host đã duyệt mic và chia sẻ màn hình cho bạn.'
          : _approved
          ? 'Host đã duyệt mic cho bạn.'
          : _screenShareApproved
          ? 'Host đã duyệt chia sẻ màn hình cho bạn.'
          : 'Host chưa cấp quyền phát biểu cho bạn.';
      _refreshMeeting();
      if ((!micWasApproved && _approved) ||
          (!screenShareWasApproved && _screenShareApproved)) {
        _showMediaError(
          'Host đã duyệt. Bạn có thể bật mic hoặc chia sẻ màn hình.',
        );
      }
    } else if (type == 'hand_rejected' &&
        !_isHost &&
        sender == _hostParticipant?.identity) {
      if (!_handRaised) return;
      _handRaised = false;
      _hostNotice = _approved || _screenShareApproved
          ? 'Host từ chối yêu cầu quyền bổ sung. Quyền đã duyệt trước đó vẫn được giữ.'
          : 'Host chưa duyệt quyền phát biểu của bạn.';
      _refreshMeeting();
    } else if (type == 'media_stopped' &&
        !_isHost &&
        sender == _hostParticipant?.identity) {
      final keys = message['media'];
      if (keys is! List) return;
      _applyHostStop([
        for (final media in _MemberMedia.values)
          if (keys.contains(media.key)) media,
      ], allowResume: message['allow_resume'] != false);
    } else if (type == 'media_invited' &&
        !_isHost &&
        sender == _hostParticipant?.identity) {
      final media = _MemberMedia.values
          .where((value) => value.key == message['media'])
          .firstOrNull;
      if (media != null) _applyHostInvite(media);
    }
  }

  /// Turns off what the host stopped. Without allow_resume the member also
  /// loses permission: mic and share come back through a raised hand, the
  /// camera through a host invite.
  void _applyHostStop(List<_MemberMedia> media, {required bool allowResume}) {
    final turnedOff = media.where(_isLocalMediaOn).toList();
    final revoked = <_MemberMedia>[];
    if (!allowResume) {
      for (final value in media) {
        if (_canUseMedia(value)) revoked.add(value);
        _setMediaAllowed(value, false);
      }
    }
    // Stopping everyone reaches every member; stay quiet when nothing changed.
    if (turnedOff.isEmpty && revoked.isEmpty) return;
    final list = _MemberMedia.describe(turnedOff.isEmpty ? revoked : turnedOff);
    _hostNotice = turnedOff.isEmpty
        ? 'Host đã thu hồi quyền dùng $list. Bạn cần host cho phép lại mới bật được.'
        : allowResume
        ? 'Host đã tắt $list của bạn. Bạn có thể bật lại khi cần.'
        : 'Host đã tắt $list của bạn. Bạn cần host cho phép lại mới bật được.';
    _refreshMeeting();
    _showMediaError(
      turnedOff.isEmpty
          ? 'Host đã thu hồi quyền dùng $list.'
          : 'Host đã tắt $list của bạn.',
    );
    for (final value in turnedOff) {
      unawaited(_turnOffLocalMedia(value));
    }
  }

  void _applyHostInvite(_MemberMedia media) {
    _setMediaAllowed(media, true);
    // Mic and share invites are approvals, so they answer a raised hand. The
    // camera is not part of hand raising.
    if (media != _MemberMedia.camera) _handRaised = false;
    if (_isLocalMediaOn(media)) {
      _refreshMeeting();
      return;
    }
    _hostNotice = 'Host đã cho phép bạn bật ${media.label}.';
    _refreshMeeting();
    unawaited(_showHostInvite(media));
  }

  bool _isLocalMediaOn(_MemberMedia media) => switch (media) {
    _MemberMedia.microphone => _micEnabled,
    _MemberMedia.camera => _cameraEnabled,
    // iOS publishes a share while the broadcast picker is still open, so the
    // host can stop one that has not finished starting.
    _MemberMedia.screenShare =>
      (_screenShare?.active ?? false) || (_screenShare?.busy ?? false),
  };

  bool _canUseMedia(_MemberMedia media) => switch (media) {
    _MemberMedia.microphone => _canUseMicrophone,
    _MemberMedia.camera => _canUseCamera,
    _MemberMedia.screenShare => _canShareScreen,
  };

  void _setMediaAllowed(_MemberMedia media, bool allowed) {
    switch (media) {
      case _MemberMedia.microphone:
        _approved = allowed;
      case _MemberMedia.camera:
        _cameraBlocked = !allowed;
      case _MemberMedia.screenShare:
        _screenShareApproved = allowed;
    }
  }

  Future<void> _turnOffLocalMedia(_MemberMedia media) async {
    switch (media) {
      case _MemberMedia.microphone:
        await _muteLocalMicrophone();
      case _MemberMedia.camera:
        await _turnOffLocalCamera();
      case _MemberMedia.screenShare:
        await _screenShare?.stopWhenIdle();
    }
  }

  Future<void> _send(
    Map<String, dynamic> message, {
    String? destination,
  }) async {
    final room = _room;
    if (room == null) return;
    await room.localParticipant?.publishData(
      utf8.encode(jsonEncode(message)),
      reliable: true,
      destinationIdentities: destination == null ? null : [destination],
      topic: 't65-demo-control',
    );
  }

  /// Tells [identity], or everyone, the name to show for this device.
  Future<void> _announceName({String? identity}) async {
    final name = widget.initialParticipantName?.trim() ?? '';
    if (name.isEmpty) return;
    try {
      await _send({
        'type': 'display_name',
        'name': name,
      }, destination: identity);
    } catch (_) {
      // Peers keep showing the LiveKit name.
    }
  }

  Future<void> _raiseHand() async {
    final room = _room;
    if (room == null || _isHost || _handRaised || !_needsHostApproval) return;
    // LiveKit sends without this grant, and the server silently drops it.
    if (room.localParticipant?.permissions.canPublishData != true) {
      _showMediaError(_dataPermissionMissing);
      return;
    }
    // Nobody could approve it, and a host who joins later never receives it.
    if (_hostParticipant == null) {
      _showMediaError(
        'Chưa có chủ phòng trong phòng nên chưa duyệt được. Hãy giơ tay lại khi chủ phòng vào.',
      );
      return;
    }

    // Set this before sending: the host can approve immediately, and the
    // response must not be discarded as arriving before the request state.
    _handRaised = true;
    _hostNotice = 'Đã giơ tay. Vui lòng chờ host duyệt quyền cần dùng.';
    _refreshMeeting();
    try {
      await _send({'type': 'hand_raise'});
    } catch (_) {
      if (mounted && _room == room && _handRaised) {
        _handRaised = false;
        _hostNotice = 'Chưa gửi được yêu cầu. Vui lòng thử giơ tay lại.';
        _refreshMeeting();
        _showMediaError('Chưa gửi được yêu cầu giơ tay. Vui lòng thử lại.');
      }
    }
  }

  Future<void> _cancelHandRaise() async {
    final room = _room;
    if (room == null || !_handRaised || _changingMic || _changingCamera) {
      return;
    }

    _changingMic = true;
    _handRaised = false;
    _refreshMeeting();
    try {
      await _send({'type': 'hand_cancel'});
    } catch (error) {
      if (mounted && _room == room) {
        _handRaised = true;
        _refreshMeeting();
        _showMediaError('Chưa hủy được yêu cầu. Vui lòng thử lại.');
      }
    } finally {
      if (mounted && _room == room) {
        _changingMic = false;
        _refreshMeeting();
      }
    }
  }

  Future<void> _approve(
    String identity, {
    required bool allowMic,
    required bool allowScreenShare,
  }) async {
    if (!_isHost || _room == null) return;
    await _send({
      'type': 'hand_approved',
      'allow_mic': allowMic,
      'allow_screen_share': allowScreenShare,
    }, destination: identity);
    if (mounted) {
      _waitingIdentities.remove(identity);
      _refreshMeeting();
    }
  }

  Future<void> _showApprovalDialog([String? identity]) async {
    if (!_isHost || _room == null) return;
    if (identity == null && _waitingIdentities.isEmpty) return;

    final participant = identity == null
        ? null
        : _participants.where((p) => p.identity == identity).firstOrNull;
    final participantName = participant == null
        ? 'tất cả người đang chờ'
        : (participant.name.isEmpty ? 'Thành viên' : participant.name);
    final dialogState = ValueNotifier(const _ApprovalDialogState());
    final choice = await showDialog<_ApprovalChoice>(
      context: context,
      builder: (dialogContext) => ValueListenableBuilder<_ApprovalDialogState>(
        valueListenable: dialogState,
        builder: (context, state, _) => AlertDialog(
          backgroundColor: const Color(0xFF222630),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Colors.white12),
          ),
          titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
          contentPadding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          title: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF43B5FF).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.admin_panel_settings_outlined,
                  color: Color(0xFF70C7FF),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  identity == null ? 'Duyệt người tham gia' : 'Duyệt quyền',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                identity == null
                    ? 'Cấp quyền cho ${_waitingIdentities.length} người đang chờ.'
                    : 'Chọn quyền cho $participantName.',
                style: const TextStyle(color: Colors.white60, height: 1.4),
              ),
              const SizedBox(height: 16),
              _ApprovalPermissionTile(
                icon: Icons.mic_rounded,
                title: 'Micro',
                subtitle: 'Cho phép bật tiếng và phát biểu',
                selected: state.allowMic,
                onChanged: (value) =>
                    dialogState.value = state.copyWith(allowMic: value),
              ),
              const SizedBox(height: 10),
              _ApprovalPermissionTile(
                icon: Icons.screen_share_rounded,
                title: 'Chia sẻ màn hình',
                subtitle: 'Cho phép trình chiếu nội dung',
                selected: state.allowScreenShare,
                onChanged: (value) =>
                    dialogState.value = state.copyWith(allowScreenShare: value),
              ),
            ],
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Hủy'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF168BE7),
                foregroundColor: Colors.white,
                minimumSize: const Size(104, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: !state.allowMic && !state.allowScreenShare
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      _ApprovalChoice(
                        allowMic: state.allowMic,
                        allowScreenShare: state.allowScreenShare,
                      ),
                    ),
              child: const Text('Đồng ý'),
            ),
          ],
        ),
      ),
    );
    dialogState.dispose();
    if (choice == null) return;
    if (identity == null) {
      await _approveAll(
        allowMic: choice.allowMic,
        allowScreenShare: choice.allowScreenShare,
      );
    } else {
      await _approve(
        identity,
        allowMic: choice.allowMic,
        allowScreenShare: choice.allowScreenShare,
      );
    }
  }

  Future<void> _approveAll({
    required bool allowMic,
    required bool allowScreenShare,
  }) async {
    if (!_isHost || _room == null || _waitingIdentities.isEmpty) return;
    final pending = List<String>.of(_waitingIdentities);
    for (final identity in pending) {
      await _send({
        'type': 'hand_approved',
        'allow_mic': allowMic,
        'allow_screen_share': allowScreenShare,
      }, destination: identity);
    }
    if (mounted) {
      _waitingIdentities.removeAll(pending);
      _refreshMeeting();
    }
  }

  Future<void> _reject(String identity) async {
    if (!_isHost || _room == null) return;
    await _send({'type': 'hand_rejected'}, destination: identity);
    _waitingIdentities.remove(identity);
    _refreshMeeting();
  }

  /// Asks the host how to turn off [media] for one member. Without an
  /// [identity] the host picks what to turn off for every member.
  Future<void> _showStopMediaDialog({
    String? identity,
    _MemberMedia? media,
  }) async {
    assert((identity == null) == (media == null));
    if (!_isHost || _room == null) return;
    final participant = identity == null
        ? null
        : _participants.where((p) => p.identity == identity).firstOrNull;
    if (identity != null && participant == null) return;
    final name = participant == null
        ? ''
        : _participantDisplayName(participant);
    final members = _room?.remoteParticipants.values.toList() ?? const [];

    final dialogState = ValueNotifier(
      _StopDialogState(selected: {media ?? _MemberMedia.microphone}),
    );
    final choice = await showDialog<_StopDialogState>(
      context: context,
      builder: (dialogContext) => ValueListenableBuilder<_StopDialogState>(
        valueListenable: dialogState,
        builder: (context, state, _) => AlertDialog(
          // Four options can be taller than a phone in landscape.
          scrollable: true,
          backgroundColor: const Color(0xFF222630),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Colors.white12),
          ),
          titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
          contentPadding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          title: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF657A).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  media?.offIcon ?? Icons.do_not_disturb_on_rounded,
                  color: const Color(0xFFFF7184),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  media?.stopAction ?? 'Tắt tất cả',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                media == null
                    ? 'Chọn những gì cần tắt cho mọi thành viên. Của bạn vẫn giữ nguyên.'
                    : 'Tắt ${media.label} của $name.',
                style: const TextStyle(color: Colors.white60, height: 1.4),
              ),
              const SizedBox(height: 16),
              if (media == null) ...[
                for (final value in _MemberMedia.values) ...[
                  _ApprovalPermissionTile(
                    icon: value.onIcon,
                    title: value.title,
                    subtitle: switch (members.where(value.isOnFor).length) {
                      0 => 'Không ai đang bật',
                      final count => '$count người đang bật',
                    },
                    selected: state.selected.contains(value),
                    onChanged: (selected) =>
                        dialogState.value = state.select(value, selected),
                  ),
                  const SizedBox(height: 10),
                ],
                const Divider(color: Colors.white12),
                const SizedBox(height: 10),
              ],
              _ApprovalPermissionTile(
                icon: Icons.lock_open_rounded,
                title: 'Cho phép tự bật lại',
                subtitle: state.allowResume
                    ? 'Thành viên có thể bật lại khi cần'
                    : switch (media) {
                        null => 'Thành viên cần host cho phép lại mới bật được',
                        _MemberMedia.camera =>
                          'Thành viên chỉ bật lại được khi host mời',
                        _ => 'Thành viên phải giơ tay để xin lại quyền',
                      },
                selected: state.allowResume,
                onChanged: (value) =>
                    dialogState.value = state.copyWith(allowResume: value),
              ),
            ],
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Hủy'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE44F68),
                foregroundColor: Colors.white,
                minimumSize: const Size(104, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: state.selected.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, state),
              child: Text(media?.stopAction ?? 'Tắt'),
            ),
          ],
        ),
      ),
    );
    dialogState.dispose();
    if (choice == null) return;
    await _stopMemberMedia(
      choice.selected,
      identity,
      allowResume: choice.allowResume,
    );
  }

  Future<void> _stopMemberMedia(
    Set<_MemberMedia> media,
    String? identity, {
    required bool allowResume,
  }) async {
    final room = _room;
    if (!_isHost || room == null || media.isEmpty) return;
    final participant = identity == null
        ? null
        : _participants.where((p) => p.identity == identity).firstOrNull;
    try {
      // Without a destination the packet reaches every member. Members only
      // accept it from the room host, so the host's own media stay unchanged.
      await _send({
        'type': 'media_stopped',
        'media': [for (final value in media) value.key],
        'allow_resume': allowResume,
      }, destination: identity);
    } catch (_) {
      if (mounted && _room == room) {
        _showMediaError('Chưa gửi được yêu cầu tắt. Vui lòng thử lại.');
      }
      return;
    }
    if (!mounted || _room != room) return;
    final name = participant == null
        ? 'thành viên'
        : _participantDisplayName(participant);
    final target = identity == null ? 'tất cả thành viên' : name;
    final list = _MemberMedia.describe(media);
    _showMediaError(
      allowResume
          ? 'Đã tắt $list của $target.'
          : 'Đã tắt $list của $target và thu hồi quyền bật lại.',
    );
  }

  /// Lets a member use [media] and asks them to turn it on. The member
  /// confirms on their device: screen capture always needs their consent,
  /// and the mic and camera follow the same rule.
  Future<void> _inviteMemberMedia(_MemberMedia media, String identity) async {
    final room = _room;
    if (!_isHost || room == null) return;
    final participant = _participants
        .where((p) => p.identity == identity)
        .firstOrNull;
    try {
      await _send({
        'type': 'media_invited',
        'media': media.key,
      }, destination: identity);
    } catch (_) {
      if (mounted && _room == room) {
        _showMediaError('Chưa gửi được lời mời. Vui lòng thử lại.');
      }
      return;
    }
    if (!mounted || _room != room) return;
    // Like an approval, a mic or share invite answers the raised hand.
    if (media != _MemberMedia.camera && _waitingIdentities.remove(identity)) {
      _refreshMeeting();
    }
    final name = participant == null
        ? 'thành viên'
        : _participantDisplayName(participant);
    _showMediaError('Đã mời $name bật ${media.label}.');
  }

  Future<void> _showHostInvite(_MemberMedia media) async {
    // A repeated invite for the same media adds nothing to an open prompt.
    if (!_openHostInvites.add(media)) return;
    final (title, message, action) = switch (media) {
      _MemberMedia.microphone => (
        'Host mời bạn phát biểu',
        'Bật mic để mọi người nghe bạn nói.',
        'Bật mic',
      ),
      _MemberMedia.camera => (
        'Host mời bạn bật camera',
        'Bật camera để mọi người nhìn thấy bạn.',
        'Bật camera',
      ),
      _MemberMedia.screenShare => (
        'Host mời bạn trình chiếu',
        'Chia sẻ màn hình để mọi người xem nội dung bạn trình bày.',
        'Chia sẻ',
      ),
    };
    final bool? accepted;
    try {
      accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF222630),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Colors.white12),
          ),
          icon: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFF43B5FF).withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(media.onIcon, color: const Color(0xFF70C7FF)),
          ),
          title: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          actions: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      minimumSize: const Size(96, 46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Để sau', textAlign: TextAlign.center),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF168BE7),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(96, 46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(action, textAlign: TextAlign.center),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    } finally {
      _openHostInvites.remove(media);
    }
    if (accepted != true || !mounted || _room == null) return;
    // The member may have turned it on meanwhile.
    if (_isLocalMediaOn(media)) return;
    switch (media) {
      case _MemberMedia.microphone:
        await _changeMedia(MeetingMedia.microphone, true);
      case _MemberMedia.camera:
        await _changeMedia(MeetingMedia.camera, true);
      case _MemberMedia.screenShare:
        await _toggleScreenShare();
    }
  }

  Future<void> _muteLocalMicrophone() async {
    final room = _room;
    final local = room?.localParticipant;
    if (local == null || !local.isMicrophoneEnabled()) return;
    try {
      await local.setMicrophoneEnabled(false);
    } catch (error) {
      if (mounted && _room == room) {
        _reportMediaFailure(MeetingMedia.microphone, error);
      }
    } finally {
      if (mounted && _room == room) _refreshMeeting();
    }
  }

  /// The first mic publication starts recording on an audio engine that was
  /// playout-only, and the input route can still be settling. That capture
  /// was sometimes silent until the user turned the mic off and on again.
  /// Restart the new track once, as that toggle does, after the route settles.
  Future<void> _refreshFirstMicCapture(Room room) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final local = room.localParticipant;
    final publication = local?.getTrackPublicationBySource(
      TrackSource.microphone,
    );
    final track = publication?.track;
    if (!mounted ||
        _room != room ||
        local == null ||
        !local.isMicrophoneEnabled() ||
        publication == null ||
        publication.muted ||
        track is! LocalAudioTrack) {
      return;
    }
    try {
      await track.restartTrack();
      debugPrint('[Hisale Coaching Hub] First microphone capture restarted.');
    } catch (error) {
      debugPrint('[Hisale Coaching Hub] First mic restart failed: $error');
    }
  }

  Future<void> _toggleMic() async {
    if (!_micEnabled && !_canUseMicrophone) {
      _showMediaError('Bạn cần giơ tay và chờ chủ phòng duyệt quyền bật mic.');
      return;
    }
    await _changeMedia(MeetingMedia.microphone, !_micEnabled);
  }

  Future<void> _toggleCamera() async {
    if (!_cameraEnabled && !_canUseCamera) {
      _showMediaError('Host đã tắt camera của bạn. Chờ host mời để bật lại.');
      return;
    }
    await _changeMedia(MeetingMedia.camera, !_cameraEnabled);
  }

  LocalVideoTrack? get _localCameraTrack {
    final track = _room?.localParticipant
        ?.getTrackPublicationBySource(TrackSource.camera)
        ?.track;
    return track is LocalVideoTrack ? track : null;
  }

  Future<void> _switchCamera() async {
    if (!_cameraEnabled || _changingCamera || _changingMic) return;
    final track = _localCameraTrack;
    if (track == null) {
      _showMediaError('Chưa có luồng camera để đổi. Hãy bật camera trước.');
      return;
    }
    final room = _room;
    _changingCamera = true;
    _refreshMeeting();
    try {
      final nextPosition = _cameraPosition.switched();
      await track.setCameraPosition(nextPosition);
      if (mounted && _room == room) {
        _cameraPosition = nextPosition;
        _refreshMeeting();
      }
    } catch (error) {
      if (mounted && _room == room) {
        _reportMediaFailure(MeetingMedia.camera, error);
      }
    } finally {
      if (mounted && _room == room) {
        _changingCamera = false;
        _refreshMeeting();
      }
    }
  }

  Future<void> _changeMedia(MeetingMedia media, bool enabled) async {
    final room = _room;
    final local = room?.localParticipant;
    if (local == null || _changingMic || _changingCamera) return;
    final microphone = media == MeetingMedia.microphone;
    final label = microphone ? 'micro' : 'camera';
    bool allowed() => microphone ? _canUseMicrophone : _canUseCamera;
    _changingMic = microphone;
    _changingCamera = !microphone;
    _refreshMeeting();
    try {
      if (enabled) {
        if (!allowed()) return;
        final access = await _mediaAccess.request(media);
        if (!mounted || _room != room) return;
        if (access != MediaAccessResult.granted) {
          await _showPermissionHelp(media, access);
          return;
        }
        // The host may revoke approval while the OS permission prompt is open.
        if (!allowed()) return;

        final canPublishSource =
            !microphone ||
            local.permissions.canPublishSources.isEmpty ||
            local.permissions.canPublishSources.any(
              (source) => source.name == 'MICROPHONE',
            );
        if (!local.permissions.canPublish || !canPublishSource) {
          _showMediaError(
            microphone
                ? 'Token LiveKit chưa cấp quyền phát micro. BE cần cấp canPublish=true và cho phép nguồn MICROPHONE.'
                : 'Phòng chưa cấp quyền phát $label cho bạn. Hãy rời phòng và vào lại.',
          );
          return;
        }
      }
      if (!mounted || _room != room) return;
      if (microphone) {
        if (enabled) {
          // Lower boosted voices before the mic opens, not after its first
          // words were already met by them.
          _openingMic = true;
          _syncSpeakerGain();
        }
        final hadMicTrack =
            local.getTrackPublicationBySource(TrackSource.microphone)?.track !=
            null;
        await local.setMicrophoneEnabled(enabled);
        // iOS may list external inputs only once the session records, and
        // starting to record can move the route back to the phone's mic.
        if (enabled) await _microphoneRouter?.apply(reselect: true);
        if (enabled && !hadMicTrack) await _refreshFirstMicCapture(room!);
      } else {
        if (enabled) {
          // LiveKit keeps a muted camera publication and restarts it with its
          // previous options. Reset that track's real capture options before
          // unmuting so a camera switched to the back camera reopens on front.
          final cameraTrack = _localCameraTrack;
          final options = cameraTrack?.currentOptions;
          if (cameraTrack != null && options is CameraCaptureOptions) {
            cameraTrack.currentOptions = options.copyWith(
              cameraPosition: CameraPosition.front,
            );
          }
        }
        await local.setCameraEnabled(enabled);
        _cameraPosition = CameraPosition.front;
      }
      if (enabled && !allowed()) {
        if (microphone) {
          await local.setMicrophoneEnabled(false);
        } else {
          await local.setCameraEnabled(false);
        }
      }
    } catch (error) {
      if (mounted && _room == room) {
        _reportMediaFailure(media, error);
      }
    } finally {
      if (mounted && _room == room) {
        _changingMic = false;
        _changingCamera = false;
        if (microphone) {
          // Also undoes the early switch when the mic failed to open.
          _openingMic = false;
          _syncSpeakerGain();
        }
        _refreshMeeting();
      }
    }
  }

  Future<void> _showPermissionHelp(
    MeetingMedia media,
    MediaAccessResult result,
  ) async {
    final label = media == MeetingMedia.microphone ? 'micro' : 'camera';
    if (result == MediaAccessResult.simulatorCamera) {
      _showMediaError(
        'iPhone Simulator không có camera để phát hình. Hãy dùng iPhone thật; bạn vẫn xem được hình của người khác.',
      );
      return;
    }
    if (result == MediaAccessResult.restricted) {
      _showMediaError(
        'Quyền $label bị giới hạn trên thiết bị. Hãy kiểm tra giới hạn quyền trong Cài đặt.',
      );
      return;
    }
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cần quyền truy cập $label'),
        content: Text(
          media == MeetingMedia.microphone
              ? 'HiSale chưa được cấp quyền dùng micro. Nếu không thấy HiSale trong Cài đặt > Micro, hãy vào Cài đặt > Quyền riêng tư & Bảo mật > Micro để kiểm tra, bật quyền cho HiSale rồi quay lại thử lại.'
              : 'Bạn chưa cho phép ứng dụng dùng camera. Mở Cài đặt của ứng dụng và bật quyền này, sau đó quay lại thử lại.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mở Cài đặt'),
          ),
        ],
      ),
    );
    if (openSettings == true) await openAppSettings();
  }

  void _reportMediaFailure(MeetingMedia media, Object error) {
    final label = media == MeetingMedia.microphone ? 'micro' : 'camera';
    final details = _errorMessage(error);
    final lower = details.toLowerCase();
    if (kDebugMode) debugPrint('[Hisale Coaching Hub] $label: $details');
    if (lower.contains('notallowed') || lower.contains('permission')) {
      _showMediaError(
        'Thiết bị chưa cho phép truy cập $label. Kiểm tra quyền của ứng dụng trong Cài đặt rồi thử lại.',
      );
    } else if (lower.contains('notfound') || lower.contains('no device')) {
      _showMediaError(
        'Không tìm thấy thiết bị $label. Hãy kiểm tra thiết bị hoặc thử trên điện thoại thật.',
      );
    } else if (error is AudioSessionException) {
      _showMediaError(
        'Chưa khởi tạo được âm thanh. Hãy đóng ứng dụng đang dùng micro rồi thử lại.',
      );
    } else if (error is TrackPublishException || error is ConnectException) {
      _showMediaError(
        'Chưa gửi được $label lên phòng. Kiểm tra kết nối mạng rồi thử lại.',
      );
    } else {
      _showMediaError(
        'Chưa bật/tắt được $label. Hãy thử lại hoặc rời phòng rồi vào lại.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Room?>(
      valueListenable: _roomNotifier,
      builder: (context, room, _) => Scaffold(
        backgroundColor: room == null
            ? (_isBackendAutoConnect
                  ? const Color(0xFF101114)
                  : const Color(0xFFF0F7FF))
            : const Color(0xFF101114),
        appBar: room == null
            ? (_isBackendAutoConnect
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(kToolbarHeight),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _preJoinRevision,
                        builder: (context, _, _) => _buildConnectingAppBar(),
                      ),
                    )
                  : null)
            // Like Meet, a phone turned sideways gives the meeting the full
            // height; the camera switch moves into the control bar.
            : _isLandscape(context)
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(kToolbarHeight),
                child: ValueListenableBuilder<int>(
                  valueListenable: _meetingRevision,
                  builder: (context, _, _) => _buildMeetingAppBar(),
                ),
              ),
        body: SafeArea(
          child: room == null
              ? ValueListenableBuilder<int>(
                  valueListenable: _preJoinRevision,
                  builder: (context, _, _) => _isBackendAutoConnect
                      ? _buildBackendConnectState()
                      : _buildPreJoin(),
                )
              : ValueListenableBuilder<int>(
                  valueListenable: _meetingRevision,
                  builder: (context, _, _) => _buildMeeting(room),
                ),
        ),
      ),
    );
  }

  Widget _buildBackendConnectState() {
    final connecting = _connecting || _error == null;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF17181C), Color(0xFF101114)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            decoration: BoxDecoration(
              color: const Color(0xFF1D1F24),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF168BE7).withValues(alpha: 0.14),
                  ),
                  child: Center(
                    child: connecting
                        ? const SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Color(0xFF55B7FF),
                            ),
                          )
                        : const Icon(
                            Icons.cloud_off_rounded,
                            size: 34,
                            color: Color(0xFFFF8A80),
                          ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  connecting
                      ? 'Đang kết nối Hisale Coaching Hub'
                      : 'Chưa thể vào phòng',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  connecting
                      ? 'Đang xác thực và thiết lập kết nối an toàn. Vui lòng chờ trong giây lát.'
                      : (_error ?? 'Đã có lỗi xảy ra. Vui lòng thử lại.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFAAADB5),
                    height: 1.45,
                    fontSize: 14,
                  ),
                ),
                if (!connecting) ...[
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _connecting ? null : _connect,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Thử kết nối lại'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF168BE7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  AppBar _buildConnectingAppBar() {
    final status = _error != null && !_connecting
        ? 'Không kết nối được'
        : 'Đang kết nối...';
    return AppBar(
      backgroundColor: const Color(0xFF17181C),
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleSpacing: 16,
      iconTheme: IconThemeData(color: Colors.white),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.initialRoomTitle?.trim().isNotEmpty == true
                ? widget.initialRoomTitle!.trim()
                : (widget.initialRoomName ?? 'Hisale Coaching Hub'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Text(
            status,
            style: const TextStyle(
              color: Color(0xFFAAADB5),
              fontSize: 11,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
      actions: _appBarActions(),
    );
  }

  List<Widget> _appBarActions() => [
    if (widget.appBarAction != null) ...[
      Center(child: widget.appBarAction!),
      const SizedBox(width: 12),
    ],
  ];

  AppBar _buildMeetingAppBar() => AppBar(
    backgroundColor: const Color(0xFF17181C),
    foregroundColor: Colors.white,
    centerTitle: false,
    iconTheme: const IconThemeData(color: Colors.white),
    title: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.initialRoomTitle?.trim().isNotEmpty == true
              ? widget.initialRoomTitle!.trim()
              : (_connectedRoomName ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        Text(
          '${_participants.length} người tham gia',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    ),
    actions: [
      if (_cameraEnabled)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: TextButton.icon(
            onPressed: _changingCamera || _changingMic ? null : _switchCamera,
            icon: const Icon(Icons.flip_camera_ios, size: 19),
            label: Text(
              _cameraPosition == CameraPosition.front ? 'Cam sau' : 'Cam trước',
            ),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white38,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      if (_isHost) _lobbyToggle(),
      const SizedBox(width: 12),
    ],
  );

  /// A pill that names the state it is in; the badge counts who waits.
  Widget _lobbyToggle() {
    final on = _lobbyEnabled;
    return Badge(
      isLabelVisible: _joinRequests.isNotEmpty,
      label: Text('${_joinRequests.length}'),
      offset: const Offset(-2, -4),
      child: Material(
        color: on ? const Color(0xFF168BE7) : const Color(0xFF2B2D34),
        shape: StadiumBorder(
          side: BorderSide(
            color: on ? const Color(0xFF55B7FF) : Colors.white24,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () {
            final enabled = !on;
            unawaited(_setLobby(enabled));
            _showMediaError(
              enabled
                  ? 'Đã bật duyệt vào phòng. Người mới vào phải chờ bạn cho vào.'
                  : 'Đã tắt duyệt vào phòng. Mọi người vào xem tự do.',
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  on ? Icons.lock_rounded : Icons.lock_open_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  'Duyệt vào',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreJoin() {
    const blue = Color(0xFF168BE7);
    const ink = Color(0xFF173858);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE2F2FF), Color(0xFFF6FAFF)],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: blue,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: blue.withValues(alpha: 0.22),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.video_camera_front_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Hisale Coaching Hub',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: blue,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Kết nối và học tập cùng nhau',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF68859E), fontSize: 15),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFDCEBFA)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0C176FA6),
                        blurRadius: 28,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Form(
                    key: _joinFormKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Tham gia phòng học',
                          style: TextStyle(
                            color: ink,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Mọi người nhập cùng tên phòng để gặp nhau.',
                          style: TextStyle(
                            color: Color(0xFF68859E),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _joinField(
                          controller: _roomController,
                          label: 'Tên phòng',
                          hint: 'Ví dụ: dao-tao-ban-hang',
                          icon: Icons.meeting_room_outlined,
                          missingMessage: 'Vui lòng nhập tên phòng.',
                          action: TextInputAction.next,
                        ),
                        const SizedBox(height: 18),
                        _joinField(
                          controller: _nameController,
                          label: 'Tên của bạn',
                          hint: 'Nhập tên hiển thị',
                          icon: Icons.person_outline_rounded,
                          missingMessage: 'Vui lòng nhập tên của bạn.',
                          action: TextInputAction.done,
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'Vai trò',
                          style: TextStyle(
                            color: ink,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<_DemoRole>(
                          initialValue: _role,
                          isExpanded: true,
                          dropdownColor: Colors.white,
                          style: const TextStyle(color: ink, fontSize: 15),
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: blue,
                          ),
                          decoration: _joinDecoration(
                            'Chọn vai trò',
                            Icons.badge_outlined,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: _DemoRole.audience,
                              child: Text('Thành viên'),
                            ),
                            DropdownMenuItem(
                              value: _DemoRole.host,
                              child: Text('Chủ phòng'),
                            ),
                          ],
                          onChanged: _connecting
                              ? null
                              : (value) {
                                  _role = value ?? _DemoRole.audience;
                                  _refreshPreJoin();
                                },
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _error!,
                            style: const TextStyle(
                              color: Color(0xFFC33D4F),
                              fontSize: 13,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 54,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: blue,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFFB4DDF9),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: _connecting ? null : _connect,
                            icon: _connecting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.login_rounded, size: 21),
                            label: Text(
                              _connecting ? 'Đang kết nối...' : 'Vào phòng',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Mic và camera tắt khi vào phòng.\nBạn có thể bật khi sẵn sàng.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF68859E),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _joinDecoration(String hint, IconData icon) =>
      InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF91A6B9), fontSize: 14),
        prefixIcon: Icon(icon, color: const Color(0xFF168BE7), size: 21),
        filled: true,
        fillColor: const Color(0xFFF5F9FE),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFFDCE8F4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFFDCE8F4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFF168BE7), width: 1.5),
        ),
      );

  Widget _joinField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required String missingMessage,
    required TextInputAction action,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF173858),
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
      const SizedBox(height: 8),
      TextFormField(
        controller: controller,
        readOnly: _connecting,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: action,
        style: const TextStyle(color: Color(0xFF173858), fontSize: 15),
        decoration: _joinDecoration(hint, icon),
        validator: (value) =>
            value == null || value.trim().isEmpty ? missingMessage : null,
        onFieldSubmitted: (_) {
          if (action == TextInputAction.done) _connect();
        },
      ),
    ],
  );

  void _focusParticipant(Participant participant) {
    _focusedScreen = false;
    _focusedIdentity = participant.identity;
    _fullScreen = true;
    _refreshMeeting();
  }

  void _onScreenPublished(Participant participant, TrackSource source) {
    if (!mounted || _room == null || source != TrackSource.screenShareVideo) {
      return;
    }
    // The pin keeps the stage; a pinned presenter's screen shows there.
    if (_pinnedParticipant != null) return;
    _focusedIdentity = participant.identity;
    _focusedScreen = true;
    _fullScreen = false;
    _refreshMeeting();
  }

  void _exitFullScreen() {
    _clearFocus();
    _refreshMeeting();
  }

  void _clearFocus() {
    _focusedIdentity = null;
    _focusedScreen = false;
    _fullScreen = false;
  }

  /// Who the host pinned, with the viewer's way out, or back in.
  Widget? _pinBar() {
    final pin = _roomPin;
    final participant = pin == null
        ? null
        : _participants.where((p) => p.identity == pin).firstOrNull;
    if (participant == null) return null;
    final name = _participantDisplayName(participant);
    final dismissed = _dismissedPin == pin;
    final (text, action, onPressed) = _isHost
        ? (
            'Đang ghim $name cho cả phòng',
            'Bỏ ghim',
            () => _togglePin(participant),
          )
        : dismissed
        ? (
            'Chủ phòng đang ghim $name',
            'Xem',
            () {
              _dismissedPin = null;
              _clearFocus();
              _refreshMeeting();
            },
          )
        : (
            'Chủ phòng đang ghim $name',
            'Bỏ ghim',
            () {
              _dismissedPin = pin;
              _clearFocus();
              _refreshMeeting();
            },
          );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF263952),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            dismissed ? Icons.push_pin_outlined : Icons.push_pin,
            color: _pinColor,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF9ACBFF),
            ),
            onPressed: onPressed,
            child: Text(action, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  static const _pinColor = Color(0xFFFF5A5F);

  Widget _pinButton(Participant participant, {double size = 34}) {
    final pinned = _pinnedIdentity == participant.identity;
    return _RequestActionButton(
      size: size,
      tooltip: pinned ? 'Bỏ ghim' : 'Ghim lên màn hình chính',
      color: pinned ? _pinColor : Colors.white60,
      icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
      onPressed: () => _togglePin(participant),
    );
  }

  Widget _buildLobby() {
    final hostAway = _hostParticipant == null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          decoration: BoxDecoration(
            color: const Color(0xFF1D1F24),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF55B7FF),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Đang chờ chủ phòng cho vào',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hostAway
                    ? 'Chủ phòng đang vắng. Bạn sẽ được duyệt khi chủ phòng quay lại.'
                    : 'Chủ phòng đã nhận yêu cầu của bạn. Vui lòng chờ trong giây lát.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFAAADB5),
                  height: 1.45,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: _exitApplication,
                icon: const Icon(Icons.exit_to_app_rounded),
                label: const Text('Rời phòng'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF7184),
                  side: const BorderSide(color: Color(0xFFFF7184)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shared by hand raises and the waiting room: how many wait, a look at
  /// the list, and one tap to approve everyone.
  Widget _requestBanner({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onView,
    required VoidCallback onApproveAll,
  }) => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF202E48), Color(0xFF25243D)],
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF435A7A)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x30000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFF31517A),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: iconColor, size: 21),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFB8C5D8), fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onView,
          child: const Text('Xem', style: TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 4),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF168BE7),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onApproveAll,
          child: const Text(
            'Duyệt tất cả',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _buildMeeting(Room room) {
    if (_inLobby) return _buildLobby();
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final chat = _chat;
    final participants = _participants;
    if (participants.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final focused = participants
        .where((p) => p.identity == _focusedIdentity)
        .firstOrNull;
    final host = _hostParticipant;
    final sharing = participants.where((p) => p.isScreenShareEnabled()).toList()
      ..sort((a, b) => a.identity.compareTo(b.identity));
    // What this viewer tapped, then the host's pin, then a shared screen,
    // then the host.
    final pinned = _pinnedParticipant;
    final center =
        focused ?? pinned ?? sharing.firstOrNull ?? host ?? participants.first;
    final hostIdentity = host?.identity;
    final showingScreen = focused != null
        ? _focusedScreen
        : pinned != null
        ? pinned.isScreenShareEnabled()
        : sharing.isNotEmpty;
    final pinBar = keyboardVisible ? null : _pinBar();
    final others = participants
        .where((p) => showingScreen || p.identity != center.identity)
        .toList();
    return Column(
      children: [
        if (_hostNotice != null && !keyboardVisible)
          GestureDetector(
            // A tap anywhere on the notice closes it, like the close button.
            behavior: HitTestBehavior.opaque,
            onTap: _dismissHostNotice,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF263952),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: Color(0xFF84C9FF),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _hostNotice!,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Đóng thông báo',
                    onPressed: _dismissHostNotice,
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ?pinBar,
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;
              final sidebarWidth = (constraints.maxWidth * 0.28)
                  .clamp(170.0, 240.0)
                  .toDouble();
              final availableHeight = (constraints.maxHeight - 24).clamp(
                0.0,
                double.infinity,
              );
              final chatHeight = keyboardVisible
                  ? availableHeight
                  : (availableHeight * (isLandscape ? 0.72 : 0.62))
                        .clamp(
                          isLandscape ? 120.0 : 160.0,
                          isLandscape ? 240.0 : 330.0,
                        )
                        .clamp(0.0, availableHeight);
              final chatRight =
                  isLandscape &&
                      !_fullScreen &&
                      !keyboardVisible &&
                      others.isNotEmpty
                  ? sidebarWidth + 18
                  : 12.0;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (isLandscape)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: showingScreen
                                ? _screenShareTile(center)
                                : _participantTile(
                                    center,
                                    large: true,
                                    hostIdentity: hostIdentity,
                                    onTap: _fullScreen
                                        ? _exitFullScreen
                                        : () => _focusParticipant(center),
                                  ),
                          ),
                        ),
                        if (!_fullScreen &&
                            !keyboardVisible &&
                            others.isNotEmpty)
                          SizedBox(
                            width: sidebarWidth,
                            child: Container(
                              margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF17181C),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFF2B2D34),
                                ),
                              ),
                              child: ListView.separated(
                                padding: EdgeInsets.zero,
                                itemCount: others.length,
                                separatorBuilder: (_, index) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, index) => SizedBox(
                                  height: 96,
                                  child: _participantTile(
                                    others[index],
                                    hostIdentity: hostIdentity,
                                    onTap: () =>
                                        _focusParticipant(others[index]),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: showingScreen
                                ? _screenShareTile(center)
                                : _participantTile(
                                    center,
                                    large: true,
                                    hostIdentity: hostIdentity,
                                    onTap: _fullScreen
                                        ? _exitFullScreen
                                        : () => _focusParticipant(center),
                                  ),
                          ),
                        ),
                        if (!_fullScreen &&
                            !keyboardVisible &&
                            others.isNotEmpty &&
                            constraints.maxHeight >= 280)
                          SizedBox(
                            height: 112,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                              itemCount: others.length,
                              separatorBuilder: (_, index) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, index) => SizedBox(
                                width: 142,
                                child: _participantTile(
                                  others[index],
                                  hostIdentity: hostIdentity,
                                  onTap: () => _focusParticipant(others[index]),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  if (chat != null && chat.visible && chatHeight > 0)
                    Positioned(
                      left: 12,
                      right: chatRight,
                      bottom: 12,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 380),
                          child: SizedBox(
                            height: chatHeight,
                            width: double.infinity,
                            child: LiveChatOverlay(controller: chat),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        if (_isHost && _joinRequests.isNotEmpty && !keyboardVisible)
          _requestBanner(
            icon: Icons.door_front_door_rounded,
            iconColor: const Color(0xFF70C7FF),
            title: '${_joinRequests.length} người xin vào',
            subtitle: 'Đang ở phòng chờ',
            onView: _showJoinRequestsSheet,
            onApproveAll: () {
              for (final identity in List.of(_joinRequests)) {
                unawaited(_answerJoin(identity, admit: true));
              }
            },
          ),
        if (_isHost && _waitingIdentities.isNotEmpty && !keyboardVisible)
          _requestBanner(
            icon: Icons.back_hand_rounded,
            iconColor: const Color(0xFFFFD166),
            title: '${_waitingIdentities.length} người giơ tay',
            subtitle: 'Chờ duyệt quyền phát biểu',
            onView: _showWaitingSheet,
            onApproveAll: _showApprovalDialog,
          ),
        _controlBar(),
      ],
    );
  }

  VideoTrack? _videoTrack(Participant participant) {
    final publication = participant.getTrackPublicationBySource(
      TrackSource.camera,
    );
    if (publication == null || publication.muted) return null;
    final track = publication.track;
    return track is VideoTrack ? track : null;
  }

  Widget _screenShareTile(Participant participant) => ListenableBuilder(
    listenable: participant,
    builder: (context, _) {
      final publication = participant.getTrackPublicationBySource(
        TrackSource.screenShareVideo,
      );
      final track = publication?.track;
      final local = participant.identity == _room?.localParticipant?.identity;
      final name = _participantDisplayName(participant);
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF393C47)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (local)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Bạn đang chia sẻ màn hình.\nMở tài liệu hoặc ứng dụng cần trình bày.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else if (track is VideoTrack && publication?.muted == false)
              IgnorePointer(
                child: RepaintBoundary(
                  child: VideoTrackRenderer(
                    track,
                    key: ValueKey('screen-share-${participant.identity}'),
                    fit: VideoViewFit.contain,
                    // Use a Flutter texture so Flutter overlays and dialogs
                    // can render above the video on iOS.
                    renderMode: VideoRenderMode.texture,
                  ),
                ),
              )
            else
              const Center(
                child: Text(
                  'Đang tải màn hình chia sẻ…',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            Positioned(
              top: 8,
              left: 12,
              right: 4,
              child: Row(
                children: [
                  const Icon(
                    Icons.screen_share,
                    color: Color(0xFF80CFFF),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$name đang chia sẻ',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ),
                  if (_isHost && !local)
                    IconButton(
                      tooltip: 'Dừng chia sẻ màn hình',
                      icon: const Icon(
                        Icons.stop_screen_share_rounded,
                        color: Color(0xFFFF7184),
                      ),
                      onPressed: () => unawaited(
                        _showStopMediaDialog(
                          identity: participant.identity,
                          media: _MemberMedia.screenShare,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: _fullScreen
                        ? 'Thu nhỏ màn hình chia sẻ'
                        : 'Phóng to màn hình chia sẻ',
                    icon: Icon(
                      _fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      _fullScreen = !_fullScreen;
                      _focusedIdentity = _fullScreen
                          ? participant.identity
                          : null;
                      _focusedScreen = _fullScreen;
                      _refreshMeeting();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _toggleScreenShare() async {
    final share = _screenShare;
    if (share == null) return;
    if (!share.active && !_canShareScreen) {
      _showMediaError(
        'Bạn cần giơ tay và chờ chủ phòng duyệt quyền chia sẻ màn hình.',
      );
      return;
    }

    await share.toggle();
    // Sharing changes the iOS audio session, which can drop the mic route.
    if (mounted && _screenShare == share) {
      unawaited(_microphoneRouter?.apply(reselect: true));
    }
    if (mounted && _screenShare == share && share.active && _cameraEnabled) {
      await _turnOffLocalCamera();
    }
    if (mounted && _screenShare == share && share.active && !_micEnabled) {
      _showMediaError(
        'Đang chia sẻ hình ảnh. Bật mic đã được duyệt để truyền cả tiếng video; '
        'tắt mic sẽ tắt cả tiếng chia sẻ.',
      );
    }
  }

  void _showMoreActions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF24262D),
      builder: (sheetContext) {
        final sharedParticipants = _participants
            .where((p) => p.isScreenShareEnabled())
            .toList();
        final members = _room?.remoteParticipants.values.toList() ?? const [];
        final mediaInUse = [
          for (final media in _MemberMedia.values)
            if (members.where(media.isOnFor).length case final count
                when count > 0)
              '$count ${media.label}',
        ];
        final microphoneRouter = _microphoneRouter;
        final microphones = microphoneRouter?.inputs ?? const <MediaDevice>[];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const ListTile(
                leading: Icon(Icons.tune_rounded, color: Color(0xFF80CFFF)),
                title: Text(
                  'Chức năng phụ',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.people_alt_outlined,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Thành viên',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showParticipantsSheet();
                },
              ),
              // In portrait this sits in the app bar, which landscape hides.
              if (_isHost && _isLandscape(context))
                StatefulBuilder(
                  builder: (context, setSheetState) => SwitchListTile(
                    secondary: const Icon(
                      Icons.door_front_door_outlined,
                      color: Colors.white70,
                    ),
                    title: const Text(
                      'Duyệt vào phòng',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Người mới vào phải chờ bạn cho vào mới xem được',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    value: _lobbyEnabled,
                    activeThumbColor: const Color(0xFF43B5FF),
                    onChanged: (value) async {
                      // Flips at once; flips back if the host's metadata
                      // could not be saved.
                      final change = _setLobby(value);
                      setSheetState(() {});
                      await change;
                      if (context.mounted) setSheetState(() {});
                    },
                  ),
                ),
              if (_isHost && members.isNotEmpty)
                ListTile(
                  leading: const Icon(
                    Icons.do_not_disturb_on_outlined,
                    color: Colors.white70,
                  ),
                  title: const Text(
                    'Tắt tất cả',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    mediaInUse.isEmpty
                        ? 'Mic, camera và chia sẻ của thành viên đều đang tắt'
                        : 'Đang bật: ${mediaInUse.join(' · ')}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) unawaited(_showStopMediaDialog());
                    });
                  },
                ),
              const Divider(color: Colors.white12, height: 1),
              ValueListenableBuilder<double>(
                valueListenable: _speakerGain,
                builder: (context, gain, _) => ListTile(
                  leading: const Icon(
                    Icons.volume_up_rounded,
                    color: Color(0xFF80CFFF),
                  ),
                  title: const Text(
                    'Âm lượng người nói',
                    style: TextStyle(color: Colors.white),
                  ),
                  trailing: Text(
                    '${(gain * 100).round()}%',
                    style: const TextStyle(
                      color: Color(0xFF80CFFF),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Slider(
                        value: gain,
                        min: 1,
                        max: 5,
                        divisions: 8,
                        activeColor: const Color(0xFF43B5FF),
                        inactiveColor: Colors.white24,
                        onChanged: (value) => _speakerGain.value = value,
                        padding: EdgeInsets.zero,
                      ),
                      const Text(
                        'Khi bật mic của điện thoại, tối đa 150% để không bị vọng. Dùng mic rời hoặc tai nghe thì không giới hạn.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              if (microphoneRouter != null && microphones.length > 1) ...[
                const Divider(color: Colors.white12, height: 1),
                const ListTile(
                  leading: Icon(Icons.mic_rounded, color: Color(0xFF80CFFF)),
                  title: Text('Micro', style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                    'Mic rời được chọn tự động khi cắm vào điện thoại',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                for (final microphone in microphones)
                  ListTile(
                    leading: Icon(
                      _microphoneIcon(microphone),
                      color: Colors.white70,
                    ),
                    title: Text(
                      microphone.label.isEmpty ? 'Micro' : microphone.label,
                      style: const TextStyle(color: Colors.white),
                    ),
                    trailing: microphone.deviceId == microphoneRouter.selectedId
                        ? const Icon(
                            Icons.check_rounded,
                            color: Color(0xFF80CFFF),
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      unawaited(microphoneRouter.select(microphone));
                    },
                  ),
              ],
              if (sharedParticipants.isNotEmpty) ...[
                const Divider(color: Colors.white12, height: 1),
                const ListTile(
                  leading: Icon(Icons.present_to_all, color: Color(0xFF80CFFF)),
                  title: Text(
                    'Màn hình đang chia sẻ',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    'Chọn một người để xem toàn màn hình',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                for (final p in sharedParticipants)
                  ListTile(
                    leading: const Icon(
                      Icons.present_to_all,
                      color: Colors.white70,
                    ),
                    title: Text(
                      'Xem màn hình: ${_participantDisplayName(p)}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _focusedIdentity = p.identity;
                      _focusedScreen = true;
                      _fullScreen = true;
                      _refreshMeeting();
                    },
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  IconData _microphoneIcon(MediaDevice microphone) {
    switch (MicrophoneRouter.kindOf(microphone)) {
      case MicrophoneKind.usb:
        return Icons.usb_rounded;
      case MicrophoneKind.wired:
        return Icons.headset_mic_rounded;
      case MicrophoneKind.bluetooth:
        return Icons.bluetooth_audio_rounded;
      case MicrophoneKind.builtIn:
        return Icons.phone_iphone_rounded;
      case MicrophoneKind.other:
        return Icons.mic_external_on_rounded;
    }
  }

  Widget _participantTile(
    Participant participant, {
    bool large = false,
    String? hostIdentity,
    required VoidCallback onTap,
  }) {
    return ListenableBuilder(
      listenable: participant,
      builder: (context, _) {
        final isLocal =
            participant.identity == _room?.localParticipant?.identity;
        final isHost = participant.identity == hostIdentity;
        final name = _participantDisplayName(participant);
        final initials = name.trim().isEmpty
            ? '?'
            : name.trim().characters.first.toUpperCase();
        final micEnabled = participant.isMicrophoneEnabled();
        final cameraEnabled = participant.isCameraEnabled();
        final videoTrack = cameraEnabled ? _videoTrack(participant) : null;
        final actionLabel = large && _fullScreen
            ? 'Thu nhỏ'
            : 'Xem toàn màn hình';
        final hostControls = _isHost && !isLocal;
        // Small tiles shrink the avatar to fit between the host's controls
        // at the top and the name at the bottom.
        final compactAvatar = hostControls && !large;
        return Semantics(
          button: true,
          label:
              '$name${isHost ? ', Chủ phòng' : ''}, mic ${micEnabled ? 'bật' : 'tắt'}, camera ${cameraEnabled ? 'bật' : 'tắt'}. $actionLabel',
          child: GestureDetector(
            onTap: onTap,
            onLongPress: _isHost ? () => _togglePin(participant) : null,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                // Keep portrait camera feeds fully visible in landscape. The
                // unused sides become the dark letterbox used by Zoom.
                color: const Color(0xFF080A0F),
                borderRadius: BorderRadius.circular(16),
              ),
              // Paint the border above the video and bottom gradient so its
              // rounded lower corners remain visible.
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isHost
                      ? const Color(0xFF60BFFF)
                      : const Color(0xFF393C47),
                  width: isHost ? 2 : 1,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (videoTrack != null)
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: VideoTrackRenderer(
                          videoTrack,
                          key: ValueKey('camera-${participant.identity}'),
                          // Keep the complete camera frame. In landscape a
                          // portrait source gets dark bars on the sides
                          // instead of being cropped or stretched.
                          fit: VideoViewFit.contain,
                          mirrorMode: isLocal
                              ? VideoViewMirrorMode.auto
                              : VideoViewMirrorMode.off,
                          // A Flutter texture keeps dialogs and bottom sheets
                          // above the camera feed on iOS. The renderer owns
                          // and disposes its texture renderer normally.
                          renderMode: VideoRenderMode.texture,
                        ),
                      ),
                    )
                  else
                    Padding(
                      // Below the controls (6 + 36 px) and above the name.
                      padding: compactAvatar
                          ? const EdgeInsets.fromLTRB(8, 46, 8, 26)
                          : EdgeInsets.zero,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: CircleAvatar(
                            radius: large ? 48 : 24,
                            backgroundColor: const Color(0xFF464A5A),
                            child: Text(
                              initials,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: large ? 38 : 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Positioned(
                    left: 0,
                    bottom: 0,
                    right: 0,
                    height: 72,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0xBB000000)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isHost)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xDD176FA6),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: const Text(
                          'Chủ phòng',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  if (hostControls)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _memberControls(participant, large: large),
                    )
                  else
                    Positioned(
                      top: _isHost ? 6 : 8,
                      right: _isHost ? 6 : 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // The host's own tile; members only see the pin.
                          if (_isHost)
                            _pinButton(participant, size: large ? 34 : 28)
                          else if (_roomPin == participant.identity)
                            const Icon(
                              Icons.push_pin,
                              color: _pinColor,
                              size: 18,
                            ),
                          const SizedBox(width: 6),
                          Icon(
                            cameraEnabled ? Icons.videocam : Icons.videocam_off,
                            color: cameraEnabled
                                ? Colors.white
                                : Colors.white60,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    right: 10,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            isLocal ? '$name (Bạn)' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: large ? 15 : 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!hostControls) ...[
                          const SizedBox(width: 4),
                          Icon(
                            micEnabled ? Icons.mic : Icons.mic_off,
                            color: micEnabled
                                ? Colors.greenAccent
                                : Colors.white60,
                            size: 18,
                          ),
                        ],
                        if (large) ...[
                          const SizedBox(width: 8),
                          Icon(
                            _fullScreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            color: Colors.white70,
                            size: 22,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The host's mic, camera and share toggles for a member, on a dark pill
  /// so they stay readable over video.
  Widget _memberControls(Participant participant, {required bool large}) {
    final size = large ? 34.0 : 28.0;
    // Four buttons still fit a 142 px thumbnail.
    final gap = SizedBox(width: large ? 8 : 4);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(size),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _memberMediaButton(participant, _MemberMedia.microphone, size: size),
          gap,
          _memberMediaButton(participant, _MemberMedia.camera, size: size),
          gap,
          _memberMediaButton(participant, _MemberMedia.screenShare, size: size),
          gap,
          _pinButton(participant, size: size),
        ],
      ),
    );
  }

  /// One toggle: it shows the current state, confirms before turning it off,
  /// and invites the member to turn it on.
  Widget _memberMediaButton(
    Participant participant,
    _MemberMedia media, {
    required double size,
  }) {
    final on = media.isOnFor(participant);
    return _RequestActionButton(
      size: size,
      tooltip: on ? media.stopAction : media.inviteAction,
      color: on ? media.onColor : Colors.white60,
      icon: on ? media.onIcon : media.offIcon,
      onPressed: () => unawaited(
        on
            ? _showStopMediaDialog(identity: participant.identity, media: media)
            : _inviteMemberMedia(media, participant.identity),
      ),
    );
  }

  String _participantDisplayName(Participant participant) {
    final isLocal = participant.identity == _room?.localParticipant?.identity;
    final requestedName = widget.initialParticipantName?.trim() ?? '';
    if (isLocal && requestedName.isNotEmpty) return requestedName;

    final announcedName = _announcedNames[participant.identity];
    if (announcedName != null) return announcedName;
    final liveKitName = participant.name.trim();
    return liveKitName.isNotEmpty ? liveKitName : participant.identity;
  }

  Widget _controlBar() {
    final screenShareActive = _screenShare?.active ?? false;
    final screenShareBusy = _screenShare?.busy ?? true;
    final micWaiting = _handRaised && !_micEnabled;
    final micLabel = _micEnabled
        ? 'Tắt mic'
        : micWaiting
        ? 'Hủy xin'
        : _canUseMicrophone
        ? 'Bật mic'
        : 'Xin mic';
    final micIcon = _micEnabled
        ? Icons.mic
        : micWaiting
        ? Icons.cancel_outlined
        : _canUseMicrophone
        ? Icons.mic_off
        : Icons.mic_none_rounded;
    final micAction = micWaiting ? _cancelHandRaise : _toggleMic;
    final actions = <Widget>[
      _controlButton(
        micIcon,
        micLabel,
        micAction,
        enabled: !_changingMic && !_changingCamera,
        active: _micEnabled || _handRaised,
      ),
      _controlButton(
        _cameraEnabled ? Icons.videocam : Icons.videocam_off,
        _cameraEnabled ? 'Tắt cam' : 'Bật cam',
        _toggleCamera,
        enabled: !_changingCamera && !_changingMic,
        active: _cameraEnabled,
      ),
      // In portrait this sits in the app bar, which landscape hides.
      if (_cameraEnabled && _isLandscape(context))
        _controlButton(
          Icons.flip_camera_ios,
          _cameraPosition == CameraPosition.front ? 'Cam sau' : 'Cam trước',
          _switchCamera,
          enabled: !_changingCamera && !_changingMic,
        ),
      // Chat is a primary action and stays visible without horizontal scroll.
      _controlButton(
        (_chat?.visible ?? false)
            ? Icons.chat_bubble_rounded
            : Icons.chat_bubble_outline,
        'Chat',
        _toggleChat,
        enabled: _chat != null,
        active: _chat?.visible ?? false,
        unreadCount: _chat?.unread ?? 0,
      ),
      _controlButton(
        screenShareActive ? Icons.stop_screen_share : Icons.screen_share,
        screenShareActive ? 'Dừng share' : 'Chia sẻ',
        _toggleScreenShare,
        // Let an unapproved member tap to see why sharing is unavailable.
        enabled: _screenShare != null && !screenShareBusy,
        active: screenShareActive,
      ),
      if (!_isHost && _needsHostApproval)
        _controlButton(
          _handRaised ? Icons.hourglass_top : Icons.back_hand,
          _handRaised ? 'Đang chờ' : 'Giơ tay',
          _handRaised ? _cancelHandRaise : _raiseHand,
          enabled: !_changingMic && !_changingCamera,
          active: _handRaised,
        ),
      _controlButton(
        Icons.more_horiz,
        'Thêm',
        _showMoreActions,
        enabled: _room != null,
      ),
      _controlButton(
        Icons.exit_to_app_rounded,
        'Thoát',
        _exitApplication,
        danger: true,
      ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      decoration: const BoxDecoration(color: Color(0xFF17181C)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: actions,
      ),
    );
  }

  Widget _controlButton(
    IconData icon,
    String label,
    VoidCallback action, {
    bool expand = true,
    bool enabled = true,
    bool active = false,
    bool danger = false,
    int unreadCount = 0,
  }) {
    final button = Tooltip(
      message: label,
      child: InkWell(
        onTap: enabled ? action : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 36,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Container(
                    width: 36,
                    height: 34,
                    decoration: BoxDecoration(
                      color: danger
                          ? Colors.redAccent
                          : (active
                                ? const Color(0xFF176FA6)
                                : const Color(0xFF2B2D34)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Badge(
                        isLabelVisible: unreadCount > 0,
                        backgroundColor: Colors.redAccent,
                        textColor: Colors.white,
                        largeSize: 16,
                        offset: const Offset(4, -12),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        textStyle: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                        label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
                        child: Icon(
                          icon,
                          color: enabled ? Colors.white : Colors.white24,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: enabled ? Colors.white70 : Colors.white24,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return expand
        ? Expanded(child: button)
        : SizedBox(width: 76, child: button);
  }

  void _showParticipantsSheet() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF24262D),
    // Rebuild on room events so mic/share states and controls stay current.
    builder: (context) => ValueListenableBuilder<int>(
      valueListenable: _meetingRevision,
      builder: (context, _, _) {
        final hostIdentity = _hostParticipant?.identity;
        final localIdentity = _room?.localParticipant?.identity;
        final canStopAll =
            _isHost && (_room?.remoteParticipants.isNotEmpty ?? false);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Người tham gia',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (canStopAll)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7184),
                      ),
                      onPressed: () => unawaited(_showStopMediaDialog()),
                      icon: const Icon(
                        Icons.do_not_disturb_on_outlined,
                        size: 18,
                      ),
                      label: const Text('Tắt tất cả'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ..._participants.map((participant) {
                final isHost = participant.identity == hostIdentity;
                final micEnabled = participant.isMicrophoneEnabled();
                final canControl =
                    _isHost && participant.identity != localIdentity;
                return ListTile(
                  leading: Icon(
                    isHost ? Icons.star_rounded : Icons.person,
                    color: Colors.white70,
                  ),
                  title: Text(
                    _participantDisplayName(participant),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    isHost ? 'Chủ phòng' : 'Thành viên',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  // The host's three toggles leave no room for the
                  // fullscreen hint; tapping the row still focuses.
                  trailing: canControl
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _pinButton(participant),
                            const SizedBox(width: 6),
                            for (final media in _MemberMedia.values) ...[
                              if (media != _MemberMedia.microphone)
                                const SizedBox(width: 6),
                              _memberMediaButton(participant, media, size: 34),
                            ],
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // The host's own row.
                            if (_isHost) ...[
                              _pinButton(participant),
                              const SizedBox(width: 12),
                            ],
                            Icon(
                              micEnabled ? Icons.mic : Icons.mic_off,
                              color: micEnabled
                                  ? Colors.greenAccent
                                  : Colors.white38,
                              size: 20,
                            ),
                            if (participant.isScreenShareEnabled()) ...[
                              const SizedBox(width: 8),
                              const Icon(
                                Icons.screen_share_rounded,
                                color: Color(0xFF80CFFF),
                                size: 20,
                              ),
                            ],
                            const SizedBox(width: 12),
                            const Icon(Icons.fullscreen, color: Colors.white70),
                          ],
                        ),
                  onTap: () {
                    Navigator.pop(context);
                    _focusParticipant(participant);
                  },
                );
              }),
            ],
          ),
        );
      },
    ),
  );

  static const _waitingSheetColor = Color(0xFF20242C);

  static const _dataPermissionMissing =
      'Token LiveKit chưa cấp quyền gửi dữ liệu nên giơ tay và chat không tới '
      'được chủ phòng. BE cần cấp canPublishData=true.';

  /// The host drags it up when many members wait, or down to close it.
  void _showWaitingSheet() => _showRequestSheet(
    icon: Icons.front_hand_rounded,
    title: 'Yêu cầu phát biểu',
    subtitle: 'Duyệt quyền mic hoặc chia sẻ màn hình',
    status: 'Đang chờ host duyệt',
    identities: _waitingIdentities,
    onApprove: (sheetContext, identity) {
      Navigator.pop(sheetContext);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showApprovalDialog(identity));
      });
    },
    onReject: (sheetContext, identity) {
      Navigator.pop(sheetContext);
      unawaited(_reject(identity));
    },
  );

  void _showJoinRequestsSheet() => _showRequestSheet(
    icon: Icons.door_front_door_rounded,
    title: 'Người xin vào phòng',
    subtitle: 'Cho vào thì họ mới xem được',
    status: 'Đang ở phòng chờ',
    identities: _joinRequests,
    // The list updates in place, so the host can answer several in a row.
    onApprove: (_, identity) => unawaited(_answerJoin(identity, admit: true)),
    onReject: (_, identity) => unawaited(_answerJoin(identity, admit: false)),
  );

  void _showRequestSheet({
    required IconData icon,
    required String title,
    required String subtitle,
    required String status,
    required Set<String> identities,
    required void Function(BuildContext sheetContext, String identity)
    onApprove,
    required void Function(BuildContext sheetContext, String identity) onReject,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const [0.5],
      builder: (context, scrollController) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _waitingSheetColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: Colors.white12),
        ),
        child: ValueListenableBuilder<int>(
          valueListenable: _meetingRevision,
          builder: (context, _, _) {
            // useSafeArea leaves the home indicator inside the sheet.
            final bottomInset = MediaQuery.paddingOf(context).bottom;
            return CustomScrollView(
              controller: scrollController,
              slivers: [
                // Pinned inside the scroll view, so dragging the header
                // resizes the sheet too.
                PinnedHeaderSliver(
                  child: _requestSheetHeader(
                    icon: icon,
                    title: title,
                    subtitle: subtitle,
                    count: identities.length,
                  ),
                ),
                if (identities.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        30,
                        24,
                        34 + bottomInset,
                      ),
                      child: const Column(
                        children: [
                          Icon(
                            Icons.hourglass_empty_rounded,
                            color: Colors.white38,
                            size: 30,
                          ),
                          SizedBox(height: 10),
                          Text(
                            'Không còn yêu cầu đang chờ.',
                            style: TextStyle(color: Colors.white60),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 14, 16, 20 + bottomInset),
                    sliver: SliverList.separated(
                      itemCount: identities.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final identity = identities.elementAt(index);
                        return _requestTile(
                          identity,
                          status: status,
                          onApprove: () => onApprove(sheetContext, identity),
                          onReject: () => onReject(sheetContext, identity),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _requestSheetHeader({
    required IconData icon,
    required String title,
    required String subtitle,
    required int count,
  }) => ColoredBox(
    // Opaque, so requests scroll under the pinned header.
    color: _waitingSheetColor,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Container(
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white30,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF43B5FF).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: const Color(0xFF70C7FF)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF43B5FF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Color(0xFF70C7FF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
      ],
    ),
  );

  Widget _requestTile(
    String identity, {
    required String status,
    required VoidCallback onApprove,
    required VoidCallback onReject,
  }) {
    final participant = _participants
        .where((value) => value.identity == identity)
        .firstOrNull;
    final name = participant == null
        ? 'Thành viên'
        : _participantDisplayName(participant);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF292E38),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 21,
            backgroundColor: const Color(0xFF3A4656),
            child: Text(
              name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  status,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _RequestActionButton(
            tooltip: 'Duyệt',
            color: const Color(0xFF35C98B),
            icon: Icons.check_rounded,
            onPressed: onApprove,
          ),
          const SizedBox(width: 4),
          _RequestActionButton(
            tooltip: 'Từ chối',
            color: const Color(0xFFFF657A),
            icon: Icons.close_rounded,
            onPressed: onReject,
          ),
        ],
      ),
    );
  }
}

class _ApprovalPermissionTile extends StatelessWidget {
  const _ApprovalPermissionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? const Color(0xFF43B5FF) : Colors.white38;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: () => onChanged(!selected),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF168BE7).withValues(alpha: 0.13)
                : const Color(0xFF292E38),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: selected
                  ? const Color(0xFF43B5FF).withValues(alpha: 0.55)
                  : Colors.white10,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: selected,
                activeTrackColor: const Color(0xFF168BE7),
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RequestActionButton extends StatelessWidget {
  const _RequestActionButton({
    required this.tooltip,
    required this.color,
    required this.icon,
    required this.onPressed,
    this.size = 40,
  });

  final String tooltip;
  final Color color;
  final IconData icon;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Its own semantics node, so screen readers can reach it inside a
    // tappable participant tile.
    return Semantics(
      container: true,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: color.withValues(alpha: 0.14),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: color, size: size * 0.525),
            ),
          ),
        ),
      ),
    );
  }
}

class _ApprovalChoice {
  const _ApprovalChoice({
    required this.allowMic,
    required this.allowScreenShare,
  });

  final bool allowMic;
  final bool allowScreenShare;
}

class _ApprovalDialogState {
  const _ApprovalDialogState({
    this.allowMic = true,
    this.allowScreenShare = true,
  });

  final bool allowMic;
  final bool allowScreenShare;

  _ApprovalDialogState copyWith({bool? allowMic, bool? allowScreenShare}) =>
      _ApprovalDialogState(
        allowMic: allowMic ?? this.allowMic,
        allowScreenShare: allowScreenShare ?? this.allowScreenShare,
      );
}

enum _DemoRole { host, audience }

/// Member media the host can turn off, or invite the member to turn on.
enum _MemberMedia {
  microphone(
    key: 'mic',
    label: 'mic',
    title: 'Micro',
    stopAction: 'Tắt mic',
    inviteAction: 'Mời bật mic',
    onIcon: Icons.mic_rounded,
    offIcon: Icons.mic_off_rounded,
    onColor: Colors.greenAccent,
  ),
  camera(
    key: 'camera',
    label: 'camera',
    title: 'Camera',
    stopAction: 'Tắt camera',
    inviteAction: 'Mời bật camera',
    onIcon: Icons.videocam_rounded,
    offIcon: Icons.videocam_off_rounded,
    onColor: Colors.white,
  ),
  screenShare(
    key: 'screen_share',
    label: 'chia sẻ màn hình',
    title: 'Chia sẻ màn hình',
    stopAction: 'Dừng chia sẻ',
    inviteAction: 'Mời chia sẻ màn hình',
    onIcon: Icons.screen_share_rounded,
    offIcon: Icons.stop_screen_share_rounded,
    onColor: Color(0xFF80CFFF),
  );

  const _MemberMedia({
    required this.key,
    required this.label,
    required this.title,
    required this.stopAction,
    required this.inviteAction,
    required this.onIcon,
    required this.offIcon,
    required this.onColor,
  });

  /// Name used in the host's data packets.
  final String key;

  /// Lowercase name used inside sentences.
  final String label;
  final String title;
  final String stopAction;
  final String inviteAction;
  final IconData onIcon;
  final IconData offIcon;
  final Color onColor;

  bool isOnFor(Participant participant) => switch (this) {
    _MemberMedia.microphone => participant.isMicrophoneEnabled(),
    _MemberMedia.camera => participant.isCameraEnabled(),
    _MemberMedia.screenShare => participant.isScreenShareEnabled(),
  };

  /// Labels in a fixed order, e.g. "mic, camera và chia sẻ màn hình".
  static String describe(Iterable<_MemberMedia> media) {
    final labels = [
      for (final value in values)
        if (media.contains(value)) value.label,
    ];
    if (labels.length < 2) return labels.join();
    return '${labels.take(labels.length - 1).join(', ')} và ${labels.last}';
  }
}

class _StopDialogState {
  const _StopDialogState({required this.selected, this.allowResume = true});

  final Set<_MemberMedia> selected;
  final bool allowResume;

  _StopDialogState select(_MemberMedia media, bool value) => _StopDialogState(
    selected: value ? {...selected, media} : ({...selected}..remove(media)),
    allowResume: allowResume,
  );

  _StopDialogState copyWith({bool? allowResume}) => _StopDialogState(
    selected: selected,
    allowResume: allowResume ?? this.allowResume,
  );
}
