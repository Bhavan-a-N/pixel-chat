import 'package:dio/dio.dart';
import '../../auth/domain/user.dart';
import '../domain/chat_models.dart';

abstract class ChatRepository {
  Future<List<Conversation>> getConversations();
  Future<Conversation> createOrGetDm(String username);
  Future<List<ChatMessage>> getMessages(
    String conversationId, {
    int? beforeSeq,
    int? afterSeq,
    int limit = 30,
  });
  Future<List<User>> searchUsers(String username);

  // Group endpoints
  Future<Conversation> createGroup({
    required String name,
    required List<String> members,
  });
  Future<GroupDetail> getGroupDetail(String conversationId);
  Future<GroupDetail> renameGroup(String conversationId, String newName);
  Future<GroupDetail> addGroupMembers(
    String conversationId,
    List<String> members,
  );
  Future<void> removeGroupMember(String conversationId, String userId);
  Future<void> changeMemberRole(
    String conversationId,
    String userId,
    String newRole,
  );
  Future<Map<String, dynamic>> leaveGroup(String conversationId);
  Future<Map<String, bool>> getPresence(List<String> userIds);
}

class ChatRepositoryImpl implements ChatRepository {
  ChatRepositoryImpl({required this.dio});

  final Dio dio;

  @override
  Future<List<Conversation>> getConversations() async {
    final response = await dio.get<List<dynamic>>('/api/conversations');
    final data = response.data ?? [];
    return data
        .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Conversation> createOrGetDm(String username) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/conversations/dm',
      data: {'username': username},
    );
    return Conversation.fromJson(response.data!);
  }

  @override
  Future<List<ChatMessage>> getMessages(
    String conversationId, {
    int? beforeSeq,
    int? afterSeq,
    int limit = 30,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit};
    if (beforeSeq != null) {
      queryParams['before_seq'] = beforeSeq;
    }
    if (afterSeq != null) {
      queryParams['after_seq'] = afterSeq;
    }

    final response = await dio.get<List<dynamic>>(
      '/api/conversations/$conversationId/messages',
      queryParameters: queryParams,
    );
    final data = response.data ?? [];
    return data
        .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<User>> searchUsers(String username) async {
    final response = await dio.get<List<dynamic>>(
      '/api/users/search',
      queryParameters: {'username': username},
    );
    final data = response.data ?? [];
    return data
        .map((item) => User.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Conversation> createGroup({
    required String name,
    required List<String> members,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/conversations/group',
      data: {'name': name, 'members': members},
    );
    return Conversation.fromJson(response.data!);
  }

  @override
  Future<GroupDetail> getGroupDetail(String conversationId) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/conversations/$conversationId',
    );
    return GroupDetail.fromJson(response.data!);
  }

  @override
  Future<GroupDetail> renameGroup(String conversationId, String newName) async {
    final response = await dio.patch<Map<String, dynamic>>(
      '/api/conversations/$conversationId',
      data: {'name': newName},
    );
    return GroupDetail.fromJson(response.data!);
  }

  @override
  Future<GroupDetail> addGroupMembers(
    String conversationId,
    List<String> members,
  ) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/conversations/$conversationId/members',
      data: {'members': members},
    );
    return GroupDetail.fromJson(response.data!);
  }

  @override
  Future<void> removeGroupMember(String conversationId, String userId) async {
    await dio.delete<void>(
      '/api/conversations/$conversationId/members/$userId',
    );
  }

  @override
  Future<void> changeMemberRole(
    String conversationId,
    String userId,
    String newRole,
  ) async {
    await dio.patch<Map<String, dynamic>>(
      '/api/conversations/$conversationId/members/$userId/role',
      data: {'role': newRole},
    );
  }

  @override
  Future<Map<String, dynamic>> leaveGroup(String conversationId) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/conversations/$conversationId/leave',
    );
    return response.data ?? {};
  }

  @override
  Future<Map<String, bool>> getPresence(List<String> userIds) async {
    if (userIds.isEmpty) return {};
    final response = await dio.get<Map<String, dynamic>>(
      '/api/users/presence',
      queryParameters: {'user_ids': userIds.join(',')},
    );
    final data = response.data ?? {};
    return data.map((key, value) => MapEntry(key, value == true));
  }
}
