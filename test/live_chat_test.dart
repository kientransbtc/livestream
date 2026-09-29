import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hi_zoom/live_chat.dart';

typedef SendImages =
    Future<LiveChatMessage> Function(
      List<String> paths,
      void Function(int done) onProgress,
    );

final _sentAt = DateTime(2026, 9, 28, 9);

LiveChatController _chat({
  bool isHost = false,
  String? host = 'host',
  SendImages? sendImages,
}) => LiveChatController(
  sendText: (_) => throw UnimplementedError(),
  sendImages: sendImages ?? (_, _) => throw UnimplementedError(),
  isHost: () => isHost,
  hostIdentity: () => host,
);

void _notice(
  LiveChatController chat,
  String sender, {
  int count = 2,
  Set<int>? sent,
}) {
  chat.receiveImageNotice(
    senderIdentity: sender,
    senderName: sender,
    messageId: 'm1',
    count: count,
    sentAt: _sentAt,
    text: 'đã gửi ${sent?.length ?? count} hình ảnh',
    sent: sent,
  );
}

void _image(LiveChatController chat, String sender, int index, String path) {
  chat.receiveImageFile(
    senderIdentity: sender,
    senderName: sender,
    messageId: 'm1',
    count: 2,
    index: index,
    sentAt: _sentAt,
    path: path,
  );
}

List<String?> _paths(LiveChatMessage message) => [
  for (final image in message.images) image.path,
];

LiveChatMessage _sentMessage(List<String> paths) => LiveChatMessage(
  id: 'm1',
  senderIdentity: 'me',
  senderName: 'Me',
  sentAt: _sentAt,
  text: 'đã gửi ${paths.length} hình ảnh',
  isOwn: true,
  images: [for (final path in paths) LiveChatImage.received(path)],
  imagesVisible: true,
);

Future<List<String>> _pickedFiles(int count) async {
  final directory = await Directory.systemTemp.createTemp('live_chat_test');
  addTearDown(() => directory.delete(recursive: true));
  return [
    for (var index = 0; index < count; index++)
      (await File('${directory.path}/$index.jpg').writeAsBytes([1, 2, 3])).path,
  ];
}

void main() {
  test('members only learn that another member sent images', () {
    final chat = _chat();
    _notice(chat, 'nam');

    final message = chat.messages.single;
    expect(message.imageCount, 2);
    expect(chat.canViewImages(message), isFalse);
    chat.dispose();
  });

  test('the host gets images and their notice in any order', () {
    final chat = _chat(isHost: true);
    _image(chat, 'nam', 1, '/images/b.jpg');
    _notice(chat, 'nam');
    _image(chat, 'nam', 0, '/images/a.jpg');

    final message = chat.messages.single;
    expect(_paths(message), ['/images/a.jpg', '/images/b.jpg']);
    expect(chat.canViewImages(message), isTrue);
    expect(chat.unread, 1);
    chat.dispose();
  });

  test('members see the host images', () {
    final chat = _chat();
    _notice(chat, 'host');
    _image(chat, 'host', 0, '/images/a.jpg');

    final message = chat.messages.single;
    expect(chat.canViewImages(message), isTrue);
    expect(_paths(message), ['/images/a.jpg', null]);
    chat.dispose();
  });

  test('a member shows host images before it knows the host', () {
    final chat = _chat(host: null);
    _image(chat, 'kien', 0, '/images/a.jpg');

    expect(chat.canViewImages(chat.messages.single), isTrue);
    chat.dispose();
  });

  test('images the sender could not send show as failed', () {
    final chat = _chat(isHost: true);
    _notice(chat, 'nam', sent: {0});

    final images = chat.messages.single.images;
    expect(images[0].pending, isTrue);
    expect(images[1].failed, isTrue);
    chat.dispose();
  });

  testWidgets('images that never arrive fail instead of loading forever', (
    tester,
  ) async {
    final chat = _chat(isHost: true);
    _notice(chat, 'nam');
    _image(chat, 'nam', 0, '/images/a.jpg');

    await tester.pump(const Duration(seconds: 21));

    final images = chat.messages.single.images;
    expect(images[0].path, '/images/a.jpg');
    expect(images[1].failed, isTrue);
    chat.dispose();
  });

  test('a send takes at most three images and the sender keeps them', () async {
    final picked = await _pickedFiles(4);
    List<String>? sent;
    final progress = <int>[];
    final chat = _chat(
      sendImages: (paths, onProgress) async {
        sent = paths;
        for (var index = 0; index < paths.length; index++) {
          onProgress(index + 1);
          progress.add(index + 1);
        }
        return _sentMessage(paths);
      },
    );

    await chat.sendImages(picked);

    expect(sent, picked.take(3));
    expect(progress, [1, 2, 3]);
    final message = chat.messages.single;
    expect(_paths(message), picked.take(3));
    expect(chat.canViewImages(message), isTrue);
    expect(chat.error, contains('tối đa 3 ảnh'));
    expect(chat.sendingImages, isFalse);
    chat.dispose();
  });

  test('a partly failed send says how many images went through', () async {
    final picked = await _pickedFiles(3);
    final chat = _chat(
      sendImages: (paths, _) async => _sentMessage(paths.take(2).toList()),
    );

    await chat.sendImages(picked);

    expect(chat.messages.single.imageCount, 2);
    expect(chat.error, contains('Chỉ gửi được 2/3 ảnh'));
    chat.dispose();
  });

  test('a member cannot send images before the host joins', () async {
    var called = false;
    final chat = _chat(
      host: null,
      sendImages: (_, _) {
        called = true;
        throw StateError('unreachable');
      },
    );

    expect(chat.canSendImages, isFalse);
    await chat.sendImages(['/images/a.jpg']);
    expect(called, isFalse);
    expect(chat.error, contains('Chủ phòng chưa vào phòng'));
    chat.dispose();
  });
}
