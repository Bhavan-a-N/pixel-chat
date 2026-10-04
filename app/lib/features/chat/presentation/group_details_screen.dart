import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/widgets/pixel_avatar.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../../auth/domain/user.dart';
import '../application/conversations_notifier.dart';
import '../application/group_details_notifier.dart';

class GroupDetailsScreen extends ConsumerStatefulWidget {
  const GroupDetailsScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends ConsumerState<GroupDetailsScreen> {
  void _showRenameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename Group'),
          content: TextField(
            key: const Key('rename_group_input'),
            controller: controller,
            maxLength: 50,
            decoration: const InputDecoration(labelText: 'Group Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              key: const Key('rename_group_confirm_button'),
              onPressed: () async {
                final newName = controller.text.trim();
                if (newName.isNotEmpty && newName != currentName) {
                  Navigator.of(dialogContext).pop();
                  await ref
                      .read(
                        groupDetailsNotifierProvider(
                          widget.conversationId,
                        ).notifier,
                      )
                      .renameGroup(newName);
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showAddMembersDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return _AddMembersDialog(conversationId: widget.conversationId);
      },
    );
  }

  void _showLeaveConfirmation(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Leave Group'),
          content: const Text(
            'Are you sure you want to leave this group? If you are the last member, the group will be deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              key: const Key('confirm_leave_group_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: AppColors.onError,
              ),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                try {
                  await ref
                      .read(
                        groupDetailsNotifierProvider(
                          widget.conversationId,
                        ).notifier,
                      )
                      .leaveGroup();
                  if (context.mounted) {
                    context.go('/home');
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error leaving group: $e')),
                    );
                  }
                }
              },
              child: const Text('Leave'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      groupDetailsNotifierProvider(widget.conversationId),
    );
    final authState = ref.watch(authNotifierProvider);
    final currentUserId = authState.user?.id ?? '';

    if (state.isLoading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('Group Details')),
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    final detail = state.detail;
    if (detail == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('Group Details')),
        body: Center(
          child: Text(
            state.error ?? 'Group not found',
            style: AppTypography.titleLarge,
          ),
        ),
      );
    }

    final currentMember = detail.findMember(currentUserId);
    final isCurrentUserAdmin = currentMember?.isAdmin ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Group Details'),
        actions: [
          if (isCurrentUserAdmin)
            IconButton(
              key: const Key('add_members_app_bar_button'),
              icon: const Icon(Icons.person_add_rounded),
              tooltip: 'Add Members',
              onPressed: () => _showAddMembersDialog(context),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            // Group Header Card
            Center(
              child: Column(
                children: [
                  PixelAvatar(
                    seed: detail.id,
                    size: AppSpacing.xxl * 2,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          detail.name,
                          style: AppTypography.headlineMedium,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCurrentUserAdmin) ...[
                        const SizedBox(width: AppSpacing.xs),
                        IconButton(
                          key: const Key('edit_group_name_button'),
                          icon: const Icon(Icons.edit_rounded, size: 20),
                          tooltip: 'Rename Group',
                          onPressed: () =>
                              _showRenameDialog(context, detail.name),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    '${detail.members.length} members',
                    style: AppTypography.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Members Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Members', style: AppTypography.titleLarge),
                if (isCurrentUserAdmin)
                  TextButton.icon(
                    key: const Key('add_members_text_button'),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add'),
                    onPressed: () => _showAddMembersDialog(context),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),

            // Members List
            Card(
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadii.borderMd,
                side: BorderSide(color: AppColors.surfaceVariant),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: detail.members.length,
                separatorBuilder: (context, index) =>
                    const Divider(height: 1, color: AppColors.surfaceVariant),
                itemBuilder: (context, index) {
                  final member = detail.members[index];
                  final isMe = member.id == currentUserId;

                  return ListTile(
                    key: Key('group_member_tile_${member.id}'),
                    leading: Stack(
                      children: [
                        PixelAvatar(
                          seed: member.id,
                          size: 40.0,
                        ),
                        if (member.isOnline)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.surface,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            member.displayName.isNotEmpty
                                ? member.displayName
                                : member.username,
                            style: AppTypography.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            '(You)',
                            style: AppTypography.bodyMedium.copyWith(
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      '@${member.username}',
                      style: AppTypography.bodyMedium,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xs,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: member.isAdmin
                                ? AppColors.primaryContainer
                                : AppColors.surfaceVariant,
                            borderRadius: AppRadii.borderPill,
                          ),
                          child: Text(
                            member.isAdmin ? 'Admin' : 'Member',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: member.isAdmin
                                  ? AppColors.onPrimaryContainer
                                  : AppColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (isCurrentUserAdmin && !isMe) ...[
                          PopupMenuButton<String>(
                            key: Key('member_actions_button_${member.id}'),
                            icon: const Icon(Icons.more_vert_rounded),
                            onSelected: (action) async {
                              final notifier = ref.read(
                                groupDetailsNotifierProvider(
                                  widget.conversationId,
                                ).notifier,
                              );
                              if (action == 'make_admin') {
                                await notifier.changeRole(member.id, 'admin');
                              } else if (action == 'dismiss_admin') {
                                await notifier.changeRole(member.id, 'member');
                              } else if (action == 'remove') {
                                await notifier.removeMember(member.id);
                              }
                            },
                            itemBuilder: (context) => [
                              if (!member.isAdmin)
                                const PopupMenuItem(
                                  value: 'make_admin',
                                  child: Text('Make admin'),
                                )
                              else
                                const PopupMenuItem(
                                  value: 'dismiss_admin',
                                  child: Text('Dismiss as admin'),
                                ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text(
                                  'Remove from group',
                                  style: TextStyle(color: AppColors.error),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Leave Group Button
            OutlinedButton.icon(
              key: const Key('leave_group_button'),
              icon: const Icon(
                Icons.exit_to_app_rounded,
                color: AppColors.error,
              ),
              label: Text(
                'Leave Group',
                style: AppTypography.titleLarge.copyWith(
                  color: AppColors.error,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.error),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              ),
              onPressed: () => _showLeaveConfirmation(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddMembersDialog extends ConsumerStatefulWidget {
  const _AddMembersDialog({required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends ConsumerState<_AddMembersDialog> {
  final _controller = TextEditingController();
  final List<User> _selected = [];
  List<User> _results = [];
  bool _isLoading = false;
  Timer? _timer;

  @override
  void dispose() {
    _controller.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () async {
      final trimmed = query.trim();
      if (trimmed.length < 2) {
        setState(() {
          _results = [];
        });
        return;
      }

      setState(() {
        _isLoading = true;
      });

      try {
        final repo = ref.read(chatRepositoryProvider);
        final users = await repo.searchUsers(trimmed);
        if (mounted) {
          setState(() {
            _results = users;
            _isLoading = false;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Members'),
      content: SizedBox(
        width: double.maxFinite,
        height: 350,
        child: Column(
          children: [
            TextField(
              key: const Key('add_member_search_input'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Search username',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: _onSearchChanged,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_selected.isNotEmpty)
              Wrap(
                spacing: AppSpacing.xs,
                children: _selected.map((u) {
                  return Chip(
                    label: Text(u.username),
                    onDeleted: () {
                      setState(() {
                        _selected.removeWhere((item) => item.id == u.id);
                      });
                    },
                  );
                }).toList(),
              ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final user = _results[index];
                        final isSelected = _selected.any(
                          (u) => u.id == user.id,
                        );

                        return ListTile(
                          title: Text(user.displayName),
                          subtitle: Text('@${user.username}'),
                          trailing: Checkbox(
                            value: isSelected,
                            onChanged: (_) {
                              setState(() {
                                if (isSelected) {
                                  _selected.removeWhere((u) => u.id == user.id);
                                } else {
                                  _selected.add(user);
                                }
                              });
                            },
                          ),
                          onTap: () {
                            setState(() {
                              if (isSelected) {
                                _selected.removeWhere((u) => u.id == user.id);
                              } else {
                                _selected.add(user);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('confirm_add_members_button'),
          onPressed: _selected.isEmpty
              ? null
              : () async {
                  final usernames = _selected.map((u) => u.username).toList();
                  Navigator.of(context).pop();
                  await ref
                      .read(
                        groupDetailsNotifierProvider(
                          widget.conversationId,
                        ).notifier,
                      )
                      .addMembers(usernames);
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
