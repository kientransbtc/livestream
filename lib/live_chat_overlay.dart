import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:gallery_saver_plus/gallery_saver.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'live_chat.dart';

/// Sits over the video, leaving the call toolbar accessible underneath.
class LiveChatOverlay extends StatefulWidget {
  const LiveChatOverlay({super.key, required this.controller});

  final LiveChatController controller;

  @override
  State<LiveChatOverlay> createState() => _LiveChatOverlayState();
}

class _LiveChatOverlayState extends State<LiveChatOverlay> {
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  final ValueNotifier<bool> _atLatest = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atLatest = _scroll.offset < 36;
    if (_atLatest.value != atLatest) _atLatest.value = atLatest;
  }

  void _showLatest() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  void _close() {
    _inputFocus.unfocus();
    widget.controller.setVisible(false);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _inputFocus.dispose();
    _atLatest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.controller;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 250;
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          // Keep the composer reachable on small phones with the keyboard open.
          final composerHeight = math.min(
            compact ? 58.0 * textScale : 112.0 * textScale,
            constraints.maxHeight * 0.55,
          );
          final imageProgress = chat.imageProgress;
          return ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF081522).withValues(alpha: 0.93),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF6AA9D8).withValues(alpha: 0.62),
                    width: 1.2,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: compact ? 36 : 44,
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.chat_bubble_rounded,
                            size: 15,
                            color: Color(0xFF80CFFF),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Chat phòng',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Ẩn chat',
                            onPressed: _close,
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0x20FFFFFF)),
                    Expanded(
                      child: chat.messages.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Text(
                                  compact
                                      ? 'Chưa có tin nhắn'
                                      : 'Gửi tin nhắn đầu tiên nhé!',
                                  textAlign: TextAlign.center,
                                  maxLines: compact ? 1 : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 13,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            )
                          : Stack(
                              children: [
                                ListView.builder(
                                  controller: _scroll,
                                  reverse: true,
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    6,
                                    12,
                                    6,
                                  ),
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemCount: chat.messages.length,
                                  itemBuilder: (context, index) {
                                    final message =
                                        chat.messages[chat.messages.length -
                                            1 -
                                            index];
                                    return _MessageRow(
                                      message: message,
                                      canViewImages: chat.canViewImages(
                                        message,
                                      ),
                                      viewerIsHost: chat.imagesGoToEveryone,
                                      onOpenImage: (position) =>
                                          _openImages(message, position),
                                    );
                                  },
                                ),
                                ValueListenableBuilder<bool>(
                                  valueListenable: _atLatest,
                                  builder: (context, atLatest, _) {
                                    if (atLatest) {
                                      return const SizedBox.shrink();
                                    }
                                    return Positioned(
                                      bottom: 4,
                                      right: 8,
                                      child: Material(
                                        borderRadius: BorderRadius.circular(16),
                                        color: const Color(0xFF176FA6),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          onTap: _showLatest,
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            child: Text(
                                              'Mới nhất ↓',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: composerHeight),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(10, 5, 10, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (chat.error != null)
                              GestureDetector(
                                // Tapping the error closes it.
                                behavior: HitTestBehavior.opaque,
                                onTap: chat.clearError,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    chat.error!,
                                    style: const TextStyle(
                                      color: Color(0xFFFFC3BF),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                            if (imageProgress != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.6,
                                        color: Color(0xFF80CFFF),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Đang gửi ảnh ${math.min(imageProgress.done + 1, imageProgress.total)}/${imageProgress.total}…',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (chat.imagesEnabled) ...[
                                  IconButton(
                                    tooltip: !chat.canSendImages
                                        ? 'Chủ phòng chưa vào phòng'
                                        : chat.imagesGoToEveryone
                                        ? 'Gửi ảnh cho cả phòng'
                                        : 'Gửi ảnh cho chủ phòng',
                                    onPressed:
                                        chat.canSendImages &&
                                            !chat.sendingImages
                                        ? _pickImages
                                        : null,
                                    style: IconButton.styleFrom(
                                      foregroundColor: const Color(0xFF80CFFF),
                                      disabledForegroundColor: Colors.white30,
                                      minimumSize: const Size(40, 40),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    icon: const Icon(
                                      Icons.add_photo_alternate_outlined,
                                      size: 21,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                ],
                                Expanded(
                                  child: TextField(
                                    controller: chat.draft,
                                    focusNode: _inputFocus,
                                    minLines: 1,
                                    maxLines: compact ? 1 : 2,
                                    inputFormatters: [
                                      LengthLimitingTextInputFormatter(
                                        liveChatMaxCharacters,
                                      ),
                                    ],
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    textInputAction: TextInputAction.send,
                                    onSubmitted: (_) => _send(),
                                    onTapOutside: (_) => _inputFocus.unfocus(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                    cursorColor: const Color(0xFF80CFFF),
                                    decoration: InputDecoration(
                                      hintText: 'Nhắn cho cả phòng…',
                                      hintStyle: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 13,
                                      ),
                                      isDense: true,
                                      filled: true,
                                      fillColor: Colors.white.withValues(
                                        alpha: 0.09,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 11,
                                          ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(13),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ValueListenableBuilder(
                                  valueListenable: chat.draft,
                                  builder: (context, value, _) =>
                                      IconButton.filled(
                                        tooltip: 'Gửi tin nhắn',
                                        onPressed:
                                            chat.sending ||
                                                value.text.trim().isEmpty
                                            ? null
                                            : _send,
                                        style: IconButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF168BE7,
                                          ),
                                          disabledBackgroundColor: const Color(
                                            0xFF294153,
                                          ),
                                          disabledForegroundColor:
                                              Colors.white30,
                                          foregroundColor: Colors.white,
                                          minimumSize: const Size(40, 40),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        icon: chat.sending
                                            ? const SizedBox(
                                                width: 17,
                                                height: 17,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.send_rounded,
                                                size: 18,
                                              ),
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _send() async {
    await widget.controller.send();
    if (mounted && widget.controller.error == null) _showLatest();
  }

  Future<void> _pickImages() async {
    _inputFocus.unfocus();
    final chat = widget.controller;
    final List<XFile> files;
    try {
      // Resized on the device so each image sends quickly over the room's
      // data channel.
      files = await ImagePicker().pickMultiImage(
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
        limit: liveChatMaxImages,
      );
    } catch (_) {
      chat.showError(
        'Chưa mở được thư viện ảnh. Kiểm tra quyền truy cập ảnh trong Cài đặt.',
      );
      return;
    }
    if (!mounted || files.isEmpty) return;

    // Extra picks still reach the controller, which explains the limit.
    final paths = [for (final file in files) file.path];
    for (var index = 0; index < paths.length; index++) {
      if (index >= liveChatMaxImages) break;
      paths[index] = await _asJpeg(paths[index], index);
    }
    if (!mounted) return;

    await chat.sendImages(paths);
    if (mounted && chat.error == null) _showLatest();
  }

  /// Screenshots come as PNG, several times larger than a JPEG of the same
  /// picture; anything but JPEG is re-encoded so it sends quickly.
  static Future<String> _asJpeg(String path, int index) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return path;
    try {
      final directory = await getTemporaryDirectory();
      final target =
          '${directory.path}/hisale_chat_'
          '${DateTime.now().microsecondsSinceEpoch}_$index.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        path,
        target,
        format: CompressFormat.jpeg,
        quality: 75,
      );
      return result?.path ?? path;
    } catch (_) {
      return path;
    }
  }

  Future<void> _openImages(LiveChatMessage message, int position) async {
    final paths = [
      for (final image in message.images)
        if (image.path != null) image.path!,
    ];
    final opened = message.images[position].path;
    if (opened == null) return;
    _inputFocus.unfocus();
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      useSafeArea: false,
      builder: (_) =>
          _ImageViewer(paths: paths, initialIndex: paths.indexOf(opened)),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.canViewImages,
    required this.viewerIsHost,
    required this.onOpenImage,
  });

  final LiveChatMessage message;
  final bool canViewImages;
  final bool viewerIsHost;
  final ValueChanged<int> onOpenImage;

  @override
  Widget build(BuildContext context) {
    final time = message.sentAt.toLocal();
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final name = '${message.senderName}${message.isOwn ? ' (Bạn)' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: message.isOwn
                        ? const Color(0xFF80CFFF)
                        : const Color(0xFFB8DDF5),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                clock,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 3),
          if (!message.hasImages)
            Text(
              message.text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.35,
              ),
            )
          else if (canViewImages)
            _ImageStrip(
              images: message.images,
              onOpen: onOpenImage,
              // Tells each side who else can see these images.
              caption: message.isOwn && !viewerIsHost
                  ? 'Chỉ chủ phòng xem được'
                  : viewerIsHost && !message.isOwn
                  ? 'Chỉ bạn xem được'
                  : null,
            )
          else
            Row(
              children: [
                const Icon(
                  Icons.image_outlined,
                  size: 16,
                  color: Colors.white54,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${message.text} cho chủ phòng',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Thumbnails of a message's images: a spinner while one is arriving, a
/// marker when it never arrived.
class _ImageStrip extends StatelessWidget {
  const _ImageStrip({required this.images, required this.onOpen, this.caption});

  static const _size = 76.0;

  final List<LiveChatImage> images;
  final ValueChanged<int> onOpen;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final cacheWidth = (_size * MediaQuery.devicePixelRatioOf(context)).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var index = 0; index < images.length; index++)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox.square(
                  dimension: _size,
                  child: switch (images[index]) {
                    LiveChatImage(:final path?) => GestureDetector(
                      onTap: () => onOpen(index),
                      child: Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        cacheWidth: cacheWidth,
                        errorBuilder: (_, _, _) => const _ImageUnavailable(),
                      ),
                    ),
                    LiveChatImage(failed: true) => const _ImageUnavailable(),
                    _ => const ColoredBox(
                      color: Color(0x1FFFFFFF),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ),
                  },
                ),
              ),
          ],
        ),
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(
            caption!,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _ImageUnavailable extends StatelessWidget {
  const _ImageUnavailable();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x1FFFFFFF),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, color: Colors.white38, size: 22),
          SizedBox(height: 4),
          Text(
            'Không tải được',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 9),
          ),
        ],
      ),
    );
  }
}

/// Full-screen images: swipe between them, pinch to zoom, save one.
class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.paths, required this.initialIndex});

  final List<String> paths;
  final int initialIndex;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _saving = false;
  String? _status;
  Timer? _statusTimer;

  @override
  void dispose() {
    _statusTimer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    bool saved;
    try {
      saved =
          await GallerySaver.saveImage(
            widget.paths[_index],
            albumName: 'HiSALE',
          ) ==
          true;
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _status = saved
          ? 'Đã lưu ảnh vào thư viện'
          : 'Chưa lưu được ảnh. Kiểm tra quyền lưu ảnh trong Cài đặt.';
    });
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _status = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.paths.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) => InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: Image.file(
                  File(widget.paths[index]),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white38,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Đóng',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
                const Spacer(),
                if (widget.paths.length > 1)
                  Text(
                    '${_index + 1}/${widget.paths.length}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                IconButton(
                  tooltip: 'Lưu ảnh',
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.download_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          if (_status != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 32 + MediaQuery.paddingOf(context).bottom,
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    _statusTimer?.cancel();
                    setState(() => _status = null);
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xE6222630),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Text(
                        _status!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
