import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/domain/user.dart';
import '../application/conversations_notifier.dart';

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _searchController = TextEditingController();

  final List<User> _selectedUsers = [];
  List<User> _searchResults = [];
  bool _isSearching = false;
  bool _isCreating = false;
  String? _errorMessage;
  Timer? _debounceTimer;

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    try {
      final repo = ref.read(chatRepositoryProvider);
      final results = await repo.searchUsers(trimmed);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _toggleUser(User user) {
    setState(() {
      if (_selectedUsers.any((u) => u.id == user.id)) {
        _selectedUsers.removeWhere((u) => u.id == user.id);
      } else {
        _selectedUsers.add(user);
      }
    });
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a group name.';
      });
      return;
    }
    if (name.length > 50) {
      setState(() {
        _errorMessage = 'Group name must be 50 characters or less.';
      });
      return;
    }

    setState(() {
      _isCreating = true;
      _errorMessage = null;
    });

    try {
      final memberUsernames = _selectedUsers.map((u) => u.username).toList();
      final conv = await ref
          .read(conversationsNotifierProvider.notifier)
          .createGroup(name: name, members: memberUsernames);

      if (mounted) {
        context.go('/chat/${conv.id}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = _nameController.text.trim().isNotEmpty && !_isCreating;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('New Group'),
        actions: [
          TextButton(
            key: const Key('create_group_submit_button'),
            onPressed: canCreate ? _createGroup : null,
            child: _isCreating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  )
                : Text(
                    'Create',
                    style: AppTypography.titleLarge.copyWith(
                      color: canCreate ? AppColors.primary : AppColors.outline,
                    ),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('group_name_input'),
                controller: _nameController,
                maxLength: 50,
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  hintText: 'Enter group name',
                  prefixIcon: Icon(Icons.group_rounded),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (_selectedUsers.isNotEmpty) ...[
                Text(
                  'Members (${_selectedUsers.length})',
                  style: AppTypography.titleLarge,
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: _selectedUsers.map((user) {
                    return Chip(
                      key: Key('selected_user_chip_${user.id}'),
                      avatar: CircleAvatar(
                        backgroundColor: AppColors.primary,
                        child: Text(
                          user.displayName.isNotEmpty
                              ? user.displayName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: AppColors.onPrimary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      label: Text(
                        user.displayName.isNotEmpty
                            ? user.displayName
                            : user.username,
                      ),
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      onDeleted: () => _toggleUser(user),
                    );
                  }).toList(),
                ),
                const Divider(height: AppSpacing.lg),
              ],
              Text('Add Members', style: AppTypography.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                key: const Key('member_search_input'),
                controller: _searchController,
                decoration: const InputDecoration(
                  labelText: 'Search users',
                  hintText: 'Type username to search',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: _onSearchChanged,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_isSearching)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: CircularProgressIndicator(color: AppColors.primary),
                  ),
                )
              else
                Expanded(
                  child: _searchResults.isEmpty
                      ? Center(
                          child: Text(
                            _searchController.text.trim().length >= 2
                                ? 'No users found'
                                : 'Search by username to add members',
                            style: AppTypography.bodyMedium,
                          ),
                        )
                      : ListView.separated(
                          itemCount: _searchResults.length,
                          separatorBuilder: (context, index) => const Divider(
                            height: 1,
                            color: AppColors.surfaceVariant,
                          ),
                          itemBuilder: (context, index) {
                            final user = _searchResults[index];
                            final isSelected = _selectedUsers.any(
                              (u) => u.id == user.id,
                            );

                            return ListTile(
                              key: Key('search_user_tile_${user.id}'),
                              leading: CircleAvatar(
                                backgroundColor: AppColors.primaryContainer,
                                child: Text(
                                  user.displayName.isNotEmpty
                                      ? user.displayName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: AppColors.onPrimaryContainer,
                                  ),
                                ),
                              ),
                              title: Text(
                                user.displayName.isNotEmpty
                                    ? user.displayName
                                    : user.username,
                                style: AppTypography.titleLarge,
                              ),
                              subtitle: Text(
                                '@${user.username}',
                                style: AppTypography.bodyMedium,
                              ),
                              trailing: Checkbox(
                                value: isSelected,
                                activeColor: AppColors.primary,
                                onChanged: (_) => _toggleUser(user),
                              ),
                              onTap: () => _toggleUser(user),
                            );
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
