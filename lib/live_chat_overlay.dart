import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
                                  itemBuilder: (context, index) => _MessageRow(
                                    message:
                                        chat.messages[chat.messages.length -
                                            1 -
                                            index],
                                  ),
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
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  chat.error!,
                                  style: const TextStyle(
                                    color: Color(0xFFFFC3BF),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
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
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final LiveChatMessage message;

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
          Text(
            message.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
