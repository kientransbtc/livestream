import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';
import 'package:path_provider/path_provider.dart';

const liveChatTopic = 'hisale.chat';
const liveChatImageTopic = 'hisale.chat.image';
const liveChatMaxCharacters = 1000;
const liveChatMaxBytes = 12 * 1024;
const liveChatHistoryLimit = 200;
const liveChatHostHistoryLimit = 1000;
const liveChatMaxImages = 3;
const liveChatMaxImageBytes = 5 * 1024 * 1024;

// Stream attributes that tie a chat message to the images sent with it.
const _imageMessageKey = 'hisale_image_message';
const _imageCountKey = 'hisale_image_count';
const _imageIndexKey = 'hisale_image_index';
// On the notice: the images the sender finished, e.g. "0,2".
const _imageSentKey = 'hisale_image_sent';

// One data packet. The SDK re-copies the rest of a larger write for every
// packet it splits off, so images are written in packet-sized pieces.
const _imageChunkBytes = 15000;
const _imageAttempts = 3;

// The notice follows the images on the same ordered channel, so an image
// still missing a little after it is not coming.
const _imageGracePeriod = Duration(seconds: 20);
// Images whose notice never arrives, e.g. the sender left mid-way.
const _imageOrphanTimeout = Duration(minutes: 3);

/// One image slot of a chat message.
@immutable
class LiveChatImage {
  const LiveChatImage.pending() : path = null, failed = false;

  const LiveChatImage.received(String this.path) : failed = false;

  const LiveChatImage.failed() : path = null, failed = true;

  /// The image file on this device, once received.
  final String? path;

  final bool failed;

  bool get pending => path == null && !failed;
}

@immutable
class LiveChatMessage {
  const LiveChatMessage({
    required this.id,
    required this.senderIdentity,
    required this.senderName,
    required this.sentAt,
    required this.text,
    this.isOwn = false,
    this.images = const [],
    this.imagesVisible = false,
  });

  final String id;
  final String senderIdentity;
  final String senderName;
  final DateTime sentAt;
  final String text;
  final bool isOwn;

  /// Images sent with this message; empty for a text message.
  final List<LiveChatImage> images;

  /// Whether this device may show the images, decided when they arrive:
  /// a member's images reach only the host, who sees them all.
  final bool imagesVisible;

  int get imageCount => images.length;

  bool get hasImages => images.isNotEmpty;

  LiveChatMessage _copyWith({
    String? text,
    List<LiveChatImage>? images,
    bool? imagesVisible,
  }) => LiveChatMessage(
    id: id,
    senderIdentity: senderIdentity,
    senderName: senderName,
    sentAt: sentAt,
    text: text ?? this.text,
    isOwn: isOwn,
    images: images ?? this.images,
    imagesVisible: imagesVisible ?? this.imagesVisible,
  );

  @override
  String toString() {
    return 'LiveChatMessage('
        'id: $id, '
        'senderIdentity: $senderIdentity, '
        'senderName: $senderName, '
        'sentAt: $sentAt, '
        'text: $text, '
        'isOwn: $isOwn, '
        'imageCount: $imageCount'
        ')';
  }
}

/// Chat controller for one LiveKit room session.
///
/// LiveKit delivers new messages only, so history lasts until the user
/// leaves the room. Members' images reach the host alone; everyone else only
/// learns that images were sent. The host's images reach everyone.
class LiveChatController extends ChangeNotifier {
  LiveChatController({
    required Future<LiveChatMessage> Function(String text) sendText,
    Future<LiveChatMessage> Function(
      List<String> paths,
      void Function(int done) onProgress,
    )?
    sendImages,
    bool Function()? isHost,
    String? Function()? hostIdentity,
  }) : _sendText = sendText,
       _sendImages = sendImages,
       _isHost = isHost ?? _nobodyIsHost,
       _hostIdentity = hostIdentity ?? _noHost;

  /// [announcedName] is the name a member announced for itself, which wins
  /// over its LiveKit name.
  factory LiveChatController.forRoom(
    Room room, {
    String? localDisplayName,
    bool Function()? isHost,
    String? Function()? hostIdentity,
    String? Function(String identity)? announcedName,
  }) {
    LocalParticipant connectedLocal() {
      final local = room.localParticipant;

      if (local == null || room.connectionState != ConnectionState.connected) {
        throw StateError('Chat is not connected');
      }

      return local;
    }

    String ownName(LocalParticipant? local) => _displayName(
      local?.name ?? '',
      fallbackIdentity: local?.identity,
      preferredName: localDisplayName,
    );

    String senderName(String identity) {
      final local = room.localParticipant;

      if (identity == local?.identity) {
        return ownName(local);
      }

      return _displayName(
        room.remoteParticipants[identity]?.name ?? '',
        fallbackIdentity: identity,
        preferredName: announcedName?.call(identity),
      );
    }

    final controller = LiveChatController(
      sendText: (text) async {
        final local = connectedLocal();

        final info = await local.sendText(
          text,
          options: SendTextOptions(topic: liveChatTopic),
        );

        return LiveChatMessage(
          id: info.id,
          senderIdentity: local.identity,
          senderName: ownName(local),
          sentAt: _sentAt(info.timestamp),
          text: text,
          isOwn: true,
        );
      },
      sendImages: isHost == null || hostIdentity == null
          ? null
          : (paths, onProgress) async {
              var local = connectedLocal();
              final toEveryone = isHost();
              final host = hostIdentity();

              if (!toEveryone && host == null) {
                throw StateError('The host is not in the room');
              }

              final messageId = _newMessageId();
              final count = paths.length;
              final sent = <int>[];

              for (var index = 0; index < count; index++) {
                final bytes = await File(paths[index]).readAsBytes();

                // A brief data channel hiccup should not lose the image.
                for (var attempt = 1; attempt <= _imageAttempts; attempt++) {
                  try {
                    await _streamImage(
                      local,
                      bytes,
                      name: _fileName(paths[index]),
                      mimeType: _imageMimeType(paths[index]),
                      // The SFU forwards the bytes to these identities only.
                      destination: toEveryone ? const [] : [host!],
                      attributes: {
                        _imageMessageKey: messageId,
                        _imageCountKey: '$count',
                        _imageIndexKey: '$index',
                      },
                    );
                    sent.add(index);
                    break;
                  } catch (_) {
                    if (attempt == _imageAttempts) break;
                    await Future<void>.delayed(
                      Duration(milliseconds: 700 * attempt),
                    );
                    // Stops retrying once the room itself is gone.
                    local = connectedLocal();
                  }
                }

                onProgress(index + 1);
              }

              if (sent.isEmpty) {
                throw StateError('No image was sent');
              }

              // Everyone learns that images were sent; older app versions
              // show this as a normal text message.
              final text = _imagesNotice(sent.length);
              final info = await local.sendText(
                text,
                options: SendTextOptions(
                  topic: liveChatTopic,
                  attributes: {
                    _imageMessageKey: messageId,
                    _imageCountKey: '$count',
                    _imageSentKey: sent.join(','),
                  },
                ),
              );

              return LiveChatMessage(
                id: messageId,
                senderIdentity: local.identity,
                senderName: ownName(local),
                sentAt: _sentAt(info.timestamp),
                text: text,
                isOwn: true,
                images: [
                  for (final index in sent)
                    LiveChatImage.received(paths[index]),
                ],
                imagesVisible: true,
              );
            },
      isHost: isHost,
      hostIdentity: hostIdentity,
    );

    room.registerTextStreamHandler(liveChatTopic, (reader, identity) {
      unawaited(
        controller._receiveStream(
          reader,
          identity: identity,
          name: senderName(identity),
          isOwn: identity == room.localParticipant?.identity,
        ),
      );
    });

    room.registerByteStreamHandler(liveChatImageTopic, (reader, identity) {
      unawaited(
        controller._receiveImage(
          reader,
          identity: identity,
          name: senderName(identity),
        ),
      );
    });

    controller._detach = () {
      room.unregisterTextStreamHandler(liveChatTopic);
      room.unregisterByteStreamHandler(liveChatImageTopic);
    };

    return controller;
  }

  final Future<LiveChatMessage> Function(String text) _sendText;

  final Future<LiveChatMessage> Function(
    List<String> paths,
    void Function(int done) onProgress,
  )?
  _sendImages;

  final bool Function() _isHost;

  final String? Function() _hostIdentity;

  final TextEditingController draft = TextEditingController();

  final List<LiveChatMessage> _messages = [];

  /// senderIdentity + messageId
  final Set<(String, String)> _seen = {};

  final Set<Timer> _timers = {};

  VoidCallback? _detach;

  /// Images this device received; deleted with the session.
  Future<Directory>? _imageDirectory;

  bool _disposed = false;
  bool _visible = false;
  bool _sending = false;

  ({int done, int total})? _imageProgress;

  int _unread = 0;

  String? _error;

  List<LiveChatMessage> get messages => List.unmodifiable(_messages);

  bool get visible => _visible;

  bool get sending => _sending;

  int get unread => _unread;

  String? get error => _error;

  /// Whether this chat has the image button at all.
  bool get imagesEnabled => _sendImages != null;

  /// A member's images go to the host, so the host must be in the room.
  bool get canSendImages =>
      _sendImages != null && (_isHost() || _hostIdentity() != null);

  /// The host's images go to everyone; a member's only to the host.
  bool get imagesGoToEveryone => _isHost();

  ({int done, int total})? get imageProgress => _imageProgress;

  bool get sendingImages => _imageProgress != null;

  bool canViewImages(LiveChatMessage message) => message.imagesVisible;

  int get _historyLimit =>
      _isHost() ? liveChatHostHistoryLimit : liveChatHistoryLimit;

  static bool _nobodyIsHost() => false;

  static String? _noHost() => null;

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

  static String _imagesNotice(int count) => 'đã gửi $count hình ảnh';

  static bool _validImageCount(int count) =>
      count > 0 && count <= liveChatMaxImages;

  static String _newMessageId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final random = Random().nextInt(1 << 32).toRadixString(36);
    return '$time-$random';
  }

  static String _fileName(String path) =>
      path.split(Platform.pathSeparator).last;

  static String _imageMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    return 'image/jpeg';
  }

  static String _imageExtension(String mimeType) => switch (mimeType) {
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'image/heic' => 'heic',
    _ => 'jpg',
  };

  static String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<void> _streamImage(
    LocalParticipant local,
    Uint8List bytes, {
    required String name,
    required String mimeType,
    required List<String> destination,
    required Map<String, String> attributes,
  }) async {
    final writer = await local.streamBytes(
      StreamBytesOptions(
        name: name,
        mimeType: mimeType,
        topic: liveChatImageTopic,
        destinationIdentities: destination,
        totalSize: bytes.length,
        attributes: attributes,
      ),
    );

    for (var start = 0; start < bytes.length; start += _imageChunkBytes) {
      await writer.write(
        Uint8List.sublistView(
          bytes,
          start,
          min(start + _imageChunkBytes, bytes.length),
        ),
      );
    }

    await writer.close();
  }

  static Set<int>? _parseIndexes(String? value) {
    if (value == null) return null;
    return {for (final part in value.split(',')) ?int.tryParse(part.trim())};
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

  void showError(String message) {
    if (_disposed) {
      return;
    }

    _error = message;
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
      images: message.images,
      imagesVisible: message.imagesVisible,
    );

    _messages.add(normalizedMessage);
    _trimHistory();

    if (!_visible && !message.isOwn) {
      _unread++;
    }

    notifyListeners();
  }

  /// The text announcing a sender's images. It may arrive before or after
  /// the images; [sent] lists the images the sender finished (null: all).
  void receiveImageNotice({
    required String senderIdentity,
    required String senderName,
    required String messageId,
    required int count,
    required DateTime sentAt,
    required String text,
    Set<int>? sent,
    bool isOwn = false,
  }) {
    _mergeImages(
      senderIdentity: senderIdentity,
      senderName: senderName,
      messageId: messageId,
      count: count,
      sentAt: sentAt,
      text: text,
      sent: sent ?? {for (var index = 0; index < count; index++) index},
      isOwn: isOwn,
      visible: isOwn || _isHost() || senderIdentity == _hostIdentity(),
    );
  }

  /// One received image, saved at [path]. Receiving it means the sender
  /// addressed it to this device, so it is shown.
  void receiveImageFile({
    required String senderIdentity,
    required String senderName,
    required String messageId,
    required int count,
    required int index,
    required DateTime sentAt,
    required String path,
  }) {
    _mergeImages(
      senderIdentity: senderIdentity,
      senderName: senderName,
      messageId: messageId,
      count: count,
      sentAt: sentAt,
      index: index,
      path: path,
      visible: true,
    );
  }

  void _mergeImages({
    required String senderIdentity,
    required String senderName,
    required String messageId,
    required int count,
    required DateTime sentAt,
    required bool visible,
    String? text,
    Set<int>? sent,
    bool isOwn = false,
    int? index,
    String? path,
  }) {
    if (_disposed ||
        senderIdentity.isEmpty ||
        messageId.isEmpty ||
        !_validImageCount(count) ||
        (index != null && (index < 0 || index >= count))) {
      if (path != null) unawaited(_deleteQuietly(path));
      return;
    }

    final position = _messages.indexWhere(
      (message) =>
          message.senderIdentity == senderIdentity && message.id == messageId,
    );

    if (position == -1 && !_seen.add((senderIdentity, messageId))) {
      // A message trimmed from history does not come back.
      if (path != null) unawaited(_deleteQuietly(path));
      return;
    }

    final existing = position == -1 ? null : _messages[position];
    final images = existing != null && existing.images.length == count
        ? [...existing.images]
        : List<LiveChatImage>.filled(count, const LiveChatImage.pending());

    if (index != null && path != null) {
      images[index] = LiveChatImage.received(path);
    }

    if (sent != null) {
      for (var slot = 0; slot < count; slot++) {
        if (!sent.contains(slot) && images[slot].pending) {
          images[slot] = const LiveChatImage.failed();
        }
      }
    }

    if (existing != null) {
      _messages[position] = existing._copyWith(
        text: text?.trim().isNotEmpty == true ? text!.trim() : null,
        images: images,
        imagesVisible: existing.imagesVisible || visible,
      );
    } else {
      _messages.add(
        LiveChatMessage(
          id: messageId,
          senderIdentity: senderIdentity,
          senderName: _displayName(
            senderName,
            fallbackIdentity: senderIdentity,
          ),
          sentAt: sentAt,
          text: text?.trim().isNotEmpty == true
              ? text!.trim()
              : _imagesNotice(count),
          isOwn: isOwn,
          images: images,
          imagesVisible: visible,
        ),
      );
      _trimHistory();

      if (!_visible && !isOwn) {
        _unread++;
      }
    }

    if (images.any((image) => image.pending)) {
      _expireLater(
        senderIdentity,
        messageId,
        sent != null ? _imageGracePeriod : _imageOrphanTimeout,
      );
    }

    notifyListeners();
  }

  /// Marks images that never arrived as failed instead of loading forever.
  void _expireLater(String senderIdentity, String messageId, Duration after) {
    late final Timer timer;
    timer = Timer(after, () {
      _timers.remove(timer);
      if (_disposed) return;

      final position = _messages.indexWhere(
        (message) =>
            message.senderIdentity == senderIdentity && message.id == messageId,
      );
      if (position == -1) return;

      final message = _messages[position];
      if (!message.images.any((image) => image.pending)) return;

      _messages[position] = message._copyWith(
        images: [
          for (final image in message.images)
            image.pending ? const LiveChatImage.failed() : image,
        ],
      );
      notifyListeners();
    });
    _timers.add(timer);
  }

  void _trimHistory() {
    while (_messages.length > _historyLimit) {
      final removed = _messages.removeAt(0);

      _seen.remove((removed.senderIdentity, removed.id));

      // The sender's own images are their picked files; keep those.
      if (!removed.isOwn) {
        for (final image in removed.images) {
          final path = image.path;
          if (path != null) unawaited(_deleteQuietly(path));
        }
      }
    }
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

      final imageMessageId = info.attributes[_imageMessageKey];
      final imageCount = int.tryParse(info.attributes[_imageCountKey] ?? '');

      if (imageMessageId != null && imageCount != null) {
        receiveImageNotice(
          senderIdentity: identity,
          senderName: name,
          messageId: imageMessageId,
          count: imageCount,
          sentAt: _sentAt(info.timestamp),
          text: normalizedText,
          sent: _parseIndexes(info.attributes[_imageSentKey]),
          isOwn: isOwn,
        );
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

  Future<void> _receiveImage(
    ByteStreamReader reader, {
    required String identity,
    required String name,
  }) async {
    final info = reader.info;
    final attributes = info?.attributes ?? const <String, String>{};
    final messageId = attributes[_imageMessageKey] ?? '';
    final count = int.tryParse(attributes[_imageCountKey] ?? '') ?? 0;
    final index = int.tryParse(attributes[_imageIndexKey] ?? '') ?? -1;

    // Senders address members' images to the host alone, so whatever this
    // device receives is meant for it; the host's identity is not checked
    // here because a member may not know it yet when the images arrive.
    if (_disposed ||
        info == null ||
        messageId.isEmpty ||
        !_validImageCount(count) ||
        index < 0 ||
        index >= count ||
        !info.mimeType.startsWith('image/') ||
        info.size <= 0 ||
        info.size > liveChatMaxImageBytes) {
      await _cancelReader(reader);
      return;
    }

    try {
      final bytes = BytesBuilder(copy: false);

      await for (final chunk in reader.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk.content);

        if (bytes.length > liveChatMaxImageBytes) {
          throw StateError('Image is too large');
        }
      }

      if (_disposed || bytes.length != info.size) {
        return;
      }

      final directory = await (_imageDirectory ??= _createImageDirectory());
      final file = File(
        '${directory.path}/${_safeFileName(identity)}_'
        '${_safeFileName(messageId)}_$index.${_imageExtension(info.mimeType)}',
      );
      await file.writeAsBytes(bytes.takeBytes(), flush: true);

      if (_disposed) {
        await _deleteQuietly(file.path);
        return;
      }

      receiveImageFile(
        senderIdentity: identity,
        senderName: name,
        messageId: messageId,
        count: count,
        index: index,
        sentAt: _sentAt(info.timestamp),
        path: file.path,
      );
    } catch (_) {
      // An incomplete image stays pending until its notice marks it failed.
    }
  }

  static Future<Directory> _createImageDirectory() async {
    final temporary = await getTemporaryDirectory();
    final session = DateTime.now().microsecondsSinceEpoch;
    return Directory(
      '${temporary.path}/hisale_chat_$session',
    ).create(recursive: true);
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone.
    }
  }

  Future<void> _cancelReader(Stream<Object?> reader) async {
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

  /// Sends up to [liveChatMaxImages] picked images.
  Future<void> sendImages(List<String> paths) async {
    final sendImages = _sendImages;

    if (_disposed || sendImages == null || sendingImages || paths.isEmpty) {
      return;
    }

    if (!canSendImages) {
      showError('Chủ phòng chưa vào phòng nên chưa gửi được ảnh.');
      return;
    }

    final selected = paths.take(liveChatMaxImages).toList();

    for (final path in selected) {
      if (await File(path).length() > liveChatMaxImageBytes) {
        showError('Mỗi ảnh tối đa 5 MB. Hãy chọn ảnh nhỏ hơn.');
        return;
      }
    }

    if (_disposed) {
      return;
    }

    _imageProgress = (done: 0, total: selected.length);
    _error = paths.length > liveChatMaxImages
        ? 'Mỗi lần gửi tối đa $liveChatMaxImages ảnh; đã gửi $liveChatMaxImages ảnh đầu.'
        : null;

    notifyListeners();

    try {
      final message = await sendImages(selected, (done) {
        if (_disposed) return;
        _imageProgress = (done: done, total: selected.length);
        notifyListeners();
      }).timeout(const Duration(minutes: 3));

      if (_disposed) {
        return;
      }

      receive(message);

      if (message.imageCount < selected.length) {
        _error =
            'Chỉ gửi được ${message.imageCount}/${selected.length} ảnh. '
            'Kiểm tra kết nối rồi gửi lại ảnh còn thiếu.';
      }
    } catch (_) {
      if (!_disposed) {
        _error = 'Chưa gửi được ảnh. Kiểm tra kết nối rồi thử lại.';
      }
    } finally {
      if (!_disposed) {
        _imageProgress = null;
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

    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();

    draft.dispose();

    _messages.clear();
    _seen.clear();

    // History ends with the session, received images included.
    final directory = _imageDirectory;
    if (directory != null) {
      unawaited(
        directory
            .then((value) => value.delete(recursive: true))
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }

    super.dispose();
  }
}
