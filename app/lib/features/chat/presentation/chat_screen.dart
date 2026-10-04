import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/pixel_art.dart';
import '../../../../core/theme/pixel_assets.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../application/chat_notifier.dart';
import '../application/conversations_notifier.dart';
import '../application/group_details_notifier.dart';
import '../domain/chat_models.dart';
import 'widgets/connection_banner.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({required this.conversationId, super.key});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isNearBottom = true;
  bool _isForegrounded = true;
  Timer? _typingDebounceTimer;

  late final ActiveConversationNotifier _activeConvNotifier;
  late final ChatNotifier _chatNotifier;

  @override
  void initState() {
    super.initState();
    _activeConvNotifier = ref.read(activeConversationIdProvider.notifier);
    _chatNotifier = ref.read(
      chatMessagesNotifierProvider(widget.conversationId).notifier,
    );
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeConvNotifier.setActive(widget.conversationId);
      _triggerReadAck();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    _typingDebounceTimer?.cancel();
    _activeConvNotifier.setActive(null);
    _chatNotifier.cancelReadTimer();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForegrounded = (state == AppLifecycleState.resumed);
    if (_isForegrounded) {
      _triggerReadAck();
    }
  }

  void _triggerReadAck() {
    if (_isForegrounded && _isNearBottom) {
      ref
          .read(chatMessagesNotifierProvider(widget.conversationId).notifier)
          .markReadIfNeeded(isForegrounded: true, isNearBottom: true);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Check if scrolled near top to load older messages
    if (_scrollController.position.pixels <=
        _scrollController.position.minScrollExtent + 80) {
      ref
          .read(chatMessagesNotifierProvider(widget.conversationId).notifier)
          .loadOlder();
    }

    // Check if user is near bottom
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    _isNearBottom = (maxScroll - currentScroll) <= 100;
    if (_isNearBottom) {
      _triggerReadAck();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onTextChanged(String text) {
    if (text.trim().isEmpty) {
      _typingDebounceTimer?.cancel();
      _chatNotifier.sendTyping(false);
      return;
    }

    _typingDebounceTimer?.cancel();
    _chatNotifier.sendTyping(true);
    _typingDebounceTimer = Timer(const Duration(seconds: 4), () {
      _chatNotifier.sendTyping(false);
    });
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || text.length > 4000) return;

    _typingDebounceTimer?.cancel();
    _chatNotifier.sendTyping(false);
    _textController.clear();
    ref
        .read(chatMessagesNotifierProvider(widget.conversationId).notifier)
        .sendMessage(text);

    _scrollToBottom();
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _showMessageInfo(
    BuildContext context,
    ChatMessage message,
    Conversation conv,
    String currentUserId,
  ) {
    final otherMembers = conv.memberships
        .where((m) => m.userId != currentUserId)
        .toList();
    final groupDetail = ref
        .read(groupDetailsNotifierProvider(widget.conversationId))
        .detail;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.radiusLg),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Message Info', style: AppTypography.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Sent: ${_formatTime(message.createdAt)}',
                  style: AppTypography.bodyMedium,
                ),
                Text('Seq: ${message.seq}', style: AppTypography.bodyMedium),
                const Divider(height: AppSpacing.lg),
                Text(
                  'Receipts',
                  style: AppTypography.titleLarge.copyWith(fontSize: 16),
                ),
                const SizedBox(height: AppSpacing.xs),
                if (otherMembers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                    child: Text(
                      'No receipts',
                      style: AppTypography.bodyMedium.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ...otherMembers.map((m) {
                    final gm = groupDetail?.findMember(m.userId);
                    final name = gm != null
                        ? '${gm.displayName} (@${gm.username})'
                        : (conv.otherParticipant != null &&
                                  conv.otherParticipant!.id == m.userId
                              ? conv.otherParticipant!.displayName
                              : m.userId);

                    String statusText = 'Sent';
                    IconData statusIcon = Icons.check_rounded;
                    Color statusColor = AppColors.outline;
                    if (m.lastReadSeq >= message.seq && message.seq > 0) {
                      statusText = 'Read';
                      statusIcon = Icons.done_all_rounded;
                      statusColor = AppColors.primary;
                    } else if (m.lastDeliveredSeq >= message.seq &&
                        message.seq > 0) {
                      statusText = 'Delivered';
                      statusIcon = Icons.done_all_rounded;
                      statusColor = AppColors.outline;
                    }

                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(statusIcon, color: statusColor, size: 18),
                      title: Text(name),
                      trailing: Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(
      chatMessagesNotifierProvider(widget.conversationId),
    );
    final authState = ref.watch(authNotifierProvider);
    final currentUserId = authState.user?.id ?? '';

    // Find conversation partner from conversations list if available
    final conversations =
        ref.watch(conversationsNotifierProvider).asData?.value ?? [];
    final conv = conversations.firstWhere(
      (c) => c.id == widget.conversationId,
      orElse: () => Conversation(
        id: widget.conversationId,
        type: 'dm',
        lastSeq: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    // Auto-scroll to bottom only if user was already at the bottom
    ref.listen(chatMessagesNotifierProvider(widget.conversationId), (
      previous,
      next,
    ) {
      if (_isNearBottom &&
          (previous?.messages.length ?? 0) < next.messages.length) {
        _scrollToBottom();
      }
      _triggerReadAck();
    });

    final otherMembers = conv.memberships
        .where((m) => m.userId != currentUserId)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: InkWell(
          key: const Key('chat_header_title_button'),
          onTap: conv.isGroup
              ? () => context.push('/group/${widget.conversationId}')
              : null,
          child: Column(
            children: [
              Text(conv.title, style: AppTypography.titleLarge),
              if (conv.isGroup)
                Text(
                  '${conv.resolvedMemberCount} members',
                  style: AppTypography.bodyMedium.copyWith(
                    fontSize: 12,
                    color: AppColors.onSurfaceVariant,
                  ),
                )
              else if (conv.otherParticipant?.username.isNotEmpty == true)
                Text(
                  '@${conv.otherParticipant!.username}',
                  style: AppTypography.bodyMedium,
                ),
            ],
          ),
        ),
        actions: [
          if (conv.isGroup)
            IconButton(
              key: const Key('chat_group_details_button'),
              icon: const Icon(Icons.info_outline_rounded),
              tooltip: 'Group details',
              onPressed: () => context.push('/group/${widget.conversationId}'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const ConnectionBanner(),
            Expanded(
              child: chatState.isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : Column(
                      children: [
                        if (chatState.isLoadingOlder)
                          const Padding(
                            padding: EdgeInsets.all(AppSpacing.xs),
                            child: SizedBox(
                              height: AppSpacing.md,
                              width: AppSpacing.md,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        Expanded(
                          child: chatState.messages.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      PixelArt(
                                        grid: PixelAssets.sparkle,
                                        palette: PixelAssets.sparklePalette,
                                        size: 48.0,
                                      ),
                                      const SizedBox(height: AppSpacing.md),
                                      Text(
                                        'No messages yet. Say hello!',
                                        style: AppTypography.bodyMedium,
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.md,
                                    vertical: AppSpacing.sm,
                                  ),
                                  itemCount: chatState.messages.length,
                                  itemBuilder: (context, index) {
                                    final msg = chatState.messages[index];

                                    if (msg.isSystem) {
                                      return _SystemMessageChip(
                                        key: Key(
                                          'system_msg_${msg.id.isNotEmpty ? msg.id : msg.clientId}',
                                        ),
                                        message: msg,
                                      );
                                    }

                                    final isMe = msg.senderId == currentUserId;

                                    return _MessageBubble(
                                      key: Key(
                                        'message_bubble_${msg.clientId.isNotEmpty ? msg.clientId : msg.id}',
                                      ),
                                      message: msg,
                                      isMe: isMe,
                                      isGroup: conv.isGroup,
                                      formattedTime: _formatTime(msg.createdAt),
                                      otherMembers: otherMembers,
                                      otherDeliveredSeq:
                                          chatState.otherDeliveredSeq,
                                      otherReadSeq: chatState.otherReadSeq,
                                      onRetry: () {
                                        ref
                                            .read(
                                              chatMessagesNotifierProvider(
                                                widget.conversationId,
                                              ).notifier,
                                            )
                                            .retryMessage(msg.clientId);
                                      },
                                      onLongPress: isMe
                                          ? () => _showMessageInfo(
                                              context,
                                              msg,
                                              conv,
                                              currentUserId,
                                            )
                                          : () {},
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
            ),
            if (chatState.typingText != null)
              Container(
                key: const Key('chat_typing_indicator'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                color: AppColors.surface,
                child: Text(
                  chatState.typingText!,
                  style: AppTypography.bodyMedium.copyWith(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ),
            _buildInputBar(chatState.isRemovedFromGroup),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isRemoved) {
    if (isRemoved) {
      return Container(
        key: const Key('chat_removed_banner'),
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        color: AppColors.surfaceVariant,
        child: Center(
          child: Text(
            'You are no longer a member of this conversation',
            style: AppTypography.bodyMedium.copyWith(
              color: AppColors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('chat_message_input'),
              controller: _textController,
              maxLines: 4,
              minLines: 1,
              maxLength: 4000,
              buildCounter:
                  (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null, // Hide counter text
              decoration: const InputDecoration(
                hintText: 'Type a message...',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
              ),
              onChanged: _onTextChanged,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            key: const Key('chat_send_button'),
            icon: const Icon(Icons.send_rounded),
            color: AppColors.primary,
            onPressed: _sendMessage,
          ),
        ],
      ),
    );
  }
}

class _SystemMessageChip extends StatelessWidget {
  const _SystemMessageChip({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant.withValues(alpha: 0.6),
          borderRadius: AppRadii.borderPill,
        ),
        child: Text(
          message.body,
          style: AppTypography.bodyMedium.copyWith(
            color: AppColors.onSurfaceVariant,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.isGroup,
    required this.formattedTime,
    required this.onRetry,
    required this.onLongPress,
    required this.otherMembers,
    required this.otherDeliveredSeq,
    required this.otherReadSeq,
  });

  final ChatMessage message;
  final bool isMe;
  final bool isGroup;
  final String formattedTime;
  final VoidCallback onRetry;
  final VoidCallback onLongPress;
  final List<MembershipPointer> otherMembers;
  final int otherDeliveredSeq;
  final int otherReadSeq;

  Widget _buildStatusIndicator() {
    MessageTickStatus tickStatus;
    if (otherMembers.isNotEmpty) {
      tickStatus = message.getMembersTickStatus(
        isMe: isMe,
        otherMembers: otherMembers,
      );
    } else {
      tickStatus = message.getTickStatus(
        isMe: isMe,
        otherDeliveredSeq: otherDeliveredSeq,
        otherReadSeq: otherReadSeq,
      );
    }

    switch (tickStatus) {
      case MessageTickStatus.failed:
        return Text(
          'Failed',
          key: Key('msg_status_failed_${message.clientId}'),
          style: AppTypography.bodyMedium.copyWith(
            fontSize: 11,
            color: AppColors.error,
          ),
        );
      case MessageTickStatus.pending:
        return Icon(
          Icons.access_time_rounded,
          key: Key('msg_tick_pending_${message.clientId}'),
          size: 14,
          color: AppColors.outline,
        );
      case MessageTickStatus.sent:
        return Icon(
          Icons.check_rounded,
          key: Key('msg_tick_sent_${message.clientId}'),
          size: 14,
          color: AppColors.outline,
        );
      case MessageTickStatus.delivered:
        return Icon(
          Icons.done_all_rounded,
          key: Key('msg_tick_delivered_${message.clientId}'),
          size: 14,
          color: AppColors.outline,
        );
      case MessageTickStatus.read:
        return Container(
          key: Key('msg_tick_read_${message.clientId}'),
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(
            Icons.done_all_rounded,
            size: 13,
            color: AppColors.primary,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bubbleColor = isMe
        ? AppColors.primaryContainer
        : AppColors.surfaceVariant;
    final textColor = isMe ? AppColors.onPrimaryContainer : AppColors.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: onLongPress,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: AppRadii.radiusMd,
                  topRight: AppRadii.radiusMd,
                  bottomLeft: isMe ? AppRadii.radiusMd : Radius.zero,
                  bottomRight: isMe ? Radius.zero : AppRadii.radiusMd,
                ),
              ),
              child: Column(
                crossAxisAlignment: isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isMe && isGroup)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
                      child: Text(
                        message.senderDisplayName?.isNotEmpty == true
                            ? message.senderDisplayName!
                            : 'Member',
                        style: AppTypography.bodyMedium.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  Text(
                    message.body,
                    style: AppTypography.bodyLarge.copyWith(color: textColor),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formattedTime,
                        style: AppTypography.bodyMedium.copyWith(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.7),
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: AppSpacing.xs),
                        _buildStatusIndicator(),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (message.isFailed && isMe) ...[
            const SizedBox(height: AppSpacing.xxs),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.errorMessage != null)
                  Text(
                    message.errorMessage!,
                    style: AppTypography.errorText.copyWith(fontSize: 11),
                  ),
                TextButton(
                  key: Key('retry_button_${message.clientId}'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 0,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onRetry,
                  child: const Text('Retry', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
