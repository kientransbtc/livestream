import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';

const liveChatTopic = 'hisale.chat';
const liveChatMaxCharacters = 1000;
const liveChatMaxBytes = 12 * 1024;
const liveChatHistoryLimit = 200;

@immutable
class LiveChatMessage {
  const LiveChatMessage({
    required this.id,
    required this.senderIdentity,
    required this.senderName,
    required this.sentAt,
    required this.text,
    this.isOwn = false,
  });

  final String id;
  final String senderIdentity;
  final String senderName;
  final DateTime sentAt;
  final String text;
  final bool isOwn;

  @override
  String toString() {
    return 'LiveChatMessage('
        'id: $id, '
        'senderIdentity: $senderIdentity, '
        'senderName: $senderName, '
        'sentAt: $sentAt, '
        'text: $text, '
        'isOwn: $isOwn'
        ')';
  }
}

/// Chat controller for one LiveKit room session.
///
/// LiveKit delivers new messages only.
/// If you need history after leaving/rejoining the room,
/// save messages in your backend/database.
class LiveChatController extends ChangeNotifier {
  LiveChatController({
    required Future<LiveChatMessage> Function(String text) sendText,
  }) : _sendText = sendText;

  factory LiveChatController.forRoom(Room room, {String? localDisplayName}) {
    final controller = LiveChatController(
      sendText: (text) async {
        final local = room.localParticipant;

        if (local == null ||
            room.connectionState != ConnectionState.connected) {
          throw StateError('Chat is not connected');
        }

        final info = await local.sendText(
          text,
          options: SendTextOptions(topic: liveChatTopic),
        );

        return LiveChatMessage(
          id: info.id,
          senderIdentity: local.identity,
          senderName: _displayName(
            local.name,
            fallbackIdentity: local.identity,
            preferredName: localDisplayName,
          ),
          sentAt: _sentAt(info.timestamp),
          text: text,
          isOwn: true,
        );
      },
    );

    room.registerTextStreamHandler(liveChatTopic, (reader, identity) {
      final localParticipant = room.localParticipant;
      final isOwn = identity == localParticipant?.identity;

      String senderName;

      if (isOwn) {
        senderName = _displayName(
          localParticipant?.name ?? '',
          fallbackIdentity: identity,
          preferredName: localDisplayName,
        );
      } else {
        final remoteParticipant = room.remoteParticipants[identity];

        senderName = _displayName(
          remoteParticipant?.name ?? '',
          fallbackIdentity: identity,
        );
      }

      unawaited(
        controller._receiveStream(
          reader,
          identity: identity,
          name: senderName,
          isOwn: isOwn,
        ),
      );
    });

    controller._detach = () {
      room.unregisterTextStreamHandler(liveChatTopic);
    };

    return controller;
  }

  final Future<LiveChatMessage> Function(String text) _sendText;

  final TextEditingController draft = TextEditingController();

  final List<LiveChatMessage> _messages = [];

  /// senderIdentity + messageId
  final Set<(String, String)> _seen = {};

  VoidCallback? _detach;

  bool _disposed = false;
  bool _visible = false;
  bool _sending = false;

  int _unread = 0;

  String? _error;

  List<LiveChatMessage> get messages => List.unmodifiable(_messages);

  bool get visible => _visible;

  bool get sending => _sending;

  int get unread => _unread;

  String? get error => _error;

  static String _displayName(
    String name, {
    String? fallbackIdentity,
    String? preferredName,
  }) {
    final preferred = preferredName?.trim() ?? '';
    if (preferred.isNotEmpty) return preferred;

    final value = name.trim();

    if (value.isNotEmpty) {
      return value;
    }

    final identity = fallbackIdentity?.trim() ?? '';

    if (identity.isNotEmpty) {
      return identity;
    }

    return 'Thành viên';
  }

  static DateTime _sentAt(int milliseconds) {
    if (milliseconds <= 0 || milliseconds > 8640000000000000) {
      return DateTime.now();
    }

    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  void toggleVisibility() {
    setVisible(!_visible);
  }

  void setVisible(bool value) {
    if (_disposed || value == _visible) {
      return;
    }

    _visible = value;

    if (value) {
      _unread = 0;
    }

    notifyListeners();
  }

  void clearError() {
    if (_disposed || _error == null) {
      return;
    }

    _error = null;
    notifyListeners();
  }

  void receive(LiveChatMessage message) {
    if (_disposed) {
      return;
    }

    final text = message.text.trim();

    if (message.id.isEmpty ||
        message.senderIdentity.isEmpty ||
        text.isEmpty ||
        text.characters.length > liveChatMaxCharacters ||
        utf8.encode(text).length > liveChatMaxBytes) {
      return;
    }

    final key = (message.senderIdentity, message.id);

    if (!_seen.add(key)) {
      return;
    }

    final normalizedMessage = LiveChatMessage(
      id: message.id,
      senderIdentity: message.senderIdentity,
      senderName: _displayName(
        message.senderName,
        fallbackIdentity: message.senderIdentity,
      ),
      sentAt: message.sentAt,
      text: text,
      isOwn: message.isOwn,
    );

    _messages.add(normalizedMessage);

    if (_messages.length > liveChatHistoryLimit) {
      final removed = _messages.removeAt(0);

      _seen.remove((removed.senderIdentity, removed.id));
    }

    if (!_visible && !message.isOwn) {
      _unread++;
    }

    notifyListeners();
  }

  Future<void> _receiveStream(
    TextStreamReader reader, {
    required String identity,
    required String name,
    required bool isOwn,
  }) async {
    final info = reader.info;

    if (_disposed) {
      await _cancelReader(reader);
      return;
    }

    if (info == null) {
      await _cancelReader(reader);
      return;
    }

    if (info.size <= 0 || info.size > liveChatMaxBytes) {
      await _cancelReader(reader);
      return;
    }

    if (info.operationType != null &&
        info.operationType != TextStreamOperationType.create) {
      await _cancelReader(reader);
      return;
    }

    try {
      final text = await reader.readAll().timeout(const Duration(seconds: 15));

      if (_disposed) {
        return;
      }

      final normalizedText = text.trim();

      if (normalizedText.isEmpty) {
        return;
      }

      receive(
        LiveChatMessage(
          id: info.id,
          senderIdentity: identity,
          senderName: _displayName(name, fallbackIdentity: identity),
          sentAt: _sentAt(info.timestamp),
          text: normalizedText,
          isOwn: isOwn,
        ),
      );
    } catch (_) {
      // Ignore incomplete/failed stream.
    }
  }

  Future<void> _cancelReader(TextStreamReader reader) async {
    try {
      final subscription = reader.listen(null, onError: (Object _) {});

      await subscription.cancel();
    } catch (_) {
      // Ignore cleanup error.
    }
  }

  Future<void> send() async {
    if (_disposed || _sending) {
      return;
    }

    final originalDraft = draft.text;
    final text = originalDraft.trim();

    if (text.isEmpty) {
      return;
    }

    if (text.characters.length > liveChatMaxCharacters ||
        utf8.encode(text).length > liveChatMaxBytes) {
      _error = 'Tin nhắn quá dài. Bạn hãy rút gọn rồi gửi lại.';

      notifyListeners();

      return;
    }

    _sending = true;
    _error = null;

    notifyListeners();

    try {
      final message = await _sendText(
        text,
      ).timeout(const Duration(seconds: 15));

      if (_disposed) {
        return;
      }

      receive(message);

      if (draft.text == originalDraft) {
        draft.clear();
      }
    } catch (_) {
      if (!_disposed) {
        _error = 'Chưa xác nhận gửi được. Kiểm tra kết nối rồi thử lại.';
      }
    } finally {
      if (!_disposed) {
        _sending = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;

    _detach?.call();

    draft.dispose();

    _messages.clear();
    _seen.clear();

    super.dispose();
  }
}
