import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/pixel_art.dart';
import '../../../../core/theme/pixel_assets.dart';
import '../../../../ui/widgets/pixel_avatar.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../../auth/domain/user.dart';
import '../application/conversations_notifier.dart';
import '../application/websocket_provider.dart';
import 'widgets/connection_banner.dart';

class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);

    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    if (difference.inDays == 0 && now.day == local.day) {
      return '$hour:$minute';
    } else if (difference.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    } else {
      return '${local.month}/${local.day}';
    }
  }

  void _showUserSearchDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return _UserSearchDialog(
          onUserSelected: (user) async {
            Navigator.of(dialogContext).pop();
            final conv = await ref
                .read(conversationsNotifierProvider.notifier)
                .createOrGetDm(user.username);
            if (context.mounted) {
              context.push('/chat/${conv.id}');
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Ensure lifecycle manager is registered
    ref.watch(appLifecycleManagerProvider);

    final authState = ref.watch(authNotifierProvider);
    final user = authState.user;
    final conversationsAsync = ref.watch(conversationsNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Column(
          children: [
            const Text('Pixel Chat'),
            if (user != null)
              Text(
                user.displayName,
                style: AppTypography.bodyMedium.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('chat_list_new_group_button'),
            icon: const Icon(Icons.group_add_rounded),
            tooltip: 'New Group',
            onPressed: () {
              context.push('/group/new');
            },
          ),
          IconButton(
            key: const Key('chat_list_logout_button'),
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Log out',
            onPressed: () {
              ref.read(authNotifierProvider.notifier).logout();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('start_chat_fab'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderPill),
        onPressed: () => _showUserSearchDialog(context, ref),
        child: const Icon(Icons.chat_rounded),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const ConnectionBanner(),
            Expanded(
              child: conversationsAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
                error: (err, _) => Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Failed to load chats',
                        style: AppTypography.titleLarge.copyWith(
                          color: AppColors.error,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      ElevatedButton(
                        onPressed: () => ref
                            .read(conversationsNotifierProvider.notifier)
                            .load(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
                data: (conversations) {
                  if (conversations.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: AppSpacing.xxl,
                            color: AppColors.outline,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'No conversations yet',
                            style: AppTypography.titleLarge.copyWith(
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Tap the chat icon to start a conversation',
                            style: AppTypography.bodyMedium,
                          ),
                        ],
                      ),
                    );
                  }

                  return RefreshIndicator(
                    color: AppColors.primary,
                    onRefresh: () =>
                        ref.read(conversationsNotifierProvider.notifier).load(),
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      itemCount: conversations.length,
                      separatorBuilder: (context, index) => const Divider(
                        height: 1,
                        color: AppColors.surfaceVariant,
                      ),
                      itemBuilder: (context, index) {
                        final conv = conversations[index];
                        final partner = conv.otherParticipant;
                        final lastMsg = conv.lastMessage;

                        final initial =
                            (partner != null && partner.displayName.isNotEmpty)
                            ? partner.displayName[0].toUpperCase()
                            : (partner != null && partner.username.isNotEmpty
                                  ? partner.username[0].toUpperCase()
                                  : '?');

                        String subtitleText;
                        if (lastMsg == null) {
                          subtitleText = 'No messages yet';
                        } else if (lastMsg.isSystem) {
                          subtitleText = lastMsg.body;
                        } else if (lastMsg.senderId == user?.id) {
                          subtitleText = 'You: ${lastMsg.body}';
                        } else if (conv.isGroup) {
                          final sender =
                              (lastMsg.senderDisplayName != null &&
                                  lastMsg.senderDisplayName!.isNotEmpty)
                              ? lastMsg.senderDisplayName!
                              : 'Member';
                          subtitleText = '$sender: ${lastMsg.body}';
                        } else {
                          subtitleText = lastMsg.body;
                        }

                        return ListTile(
                          key: Key('conversation_tile_${conv.id}'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs,
                          ),
                          leading: PixelAvatar(
                            seed: conv.isGroup ? conv.id : (partner?.avatarSeed ?? conv.id),
                            size: AppSpacing.xl, // using an appropriate size (32.0 or 40.0)
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  conv.title,
                                  style: AppTypography.titleLarge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (lastMsg != null)
                                Text(
                                  _formatTimestamp(lastMsg.createdAt),
                                  style: AppTypography.bodyMedium,
                                ),
                            ],
                          ),
                          subtitle: Text(
                            subtitleText,
                            style: AppTypography.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            context.push('/chat/${conv.id}');
                          },
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserSearchDialog extends ConsumerStatefulWidget {
  const _UserSearchDialog({required this.onUserSelected});

  final void Function(User user) onUserSelected;

  @override
  ConsumerState<_UserSearchDialog> createState() => _UserSearchDialogState();
}

class _UserSearchDialogState extends ConsumerState<_UserSearchDialog> {
  final _controller = TextEditingController();
  List<User> _results = [];
  bool _isLoading = false;
  String? _error;

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final repository = ref.read(chatRepositoryProvider);
      final users = await repository.searchUsers(trimmed);
      if (mounted) {
        setState(() {
          _results = users;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Search failed';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderLg),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Start a conversation', style: AppTypography.titleLarge),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('user_search_textfield'),
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search username (min 2 chars)',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: _search,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Text(_error!, style: AppTypography.errorText),
              )
            else if (_results.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final user = _results[index];
                    return ListTile(
                      key: Key('search_result_user_${user.username}'),
                      leading: PixelAvatar(
                        seed: user.avatarSeed,
                        size: AppSpacing.xl,
                      ),
                      title: Text(
                        user.displayName,
                        style: AppTypography.titleLarge,
                      ),
                      subtitle: Text(
                        '@${user.username}',
                        style: AppTypography.bodyMedium,
                      ),
                      onTap: () => widget.onUserSelected(user),
                    );
                  },
                ),
              )
            else if (_controller.text.trim().length >= 2)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Center(
                  child: Text(
                    'No users found',
                    style: AppTypography.bodyMedium,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
