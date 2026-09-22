import '../../auth/domain/user.dart';

enum MessageStatus { pending, sent, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.seq,
    required this.body,
    required this.clientId,
    required this.createdAt,
    this.status = MessageStatus.sent,
    this.errorMessage,
    this.isSystem = false,
    this.systemData,
    this.senderDisplayName,
    this.senderAvatarSeed,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final int seq;
  final String body;
  final String clientId;
  final DateTime createdAt;
  final MessageStatus status;
  final String? errorMessage;
  final bool isSystem;
  final Map<String, dynamic>? systemData;
  final String? senderDisplayName;
  final String? senderAvatarSeed;

  bool get isPending => status == MessageStatus.pending;
  bool get isFailed => status == MessageStatus.failed;
  bool get isSent => status == MessageStatus.sent;

  MessageTickStatus getTickStatus({
    required bool isMe,
    required int otherDeliveredSeq,
    required int otherReadSeq,
  }) {
    if (!isMe || isSystem) return MessageTickStatus.sent;
    if (status == MessageStatus.failed) return MessageTickStatus.failed;
    if (status == MessageStatus.pending || seq <= 0) {
      return MessageTickStatus.pending;
    }
    if (seq <= otherReadSeq) return MessageTickStatus.read;
    if (seq <= otherDeliveredSeq) return MessageTickStatus.delivered;
    return MessageTickStatus.sent;
  }

  MessageTickStatus getMembersTickStatus({
    required bool isMe,
    required List<MembershipPointer> otherMembers,
  }) {
    if (!isMe || isSystem) return MessageTickStatus.sent;
    if (status == MessageStatus.failed) return MessageTickStatus.failed;
    if (status == MessageStatus.pending || seq <= 0) {
      return MessageTickStatus.pending;
    }
    if (otherMembers.isEmpty) return MessageTickStatus.sent;
    final allRead = otherMembers.every((m) => m.lastReadSeq >= seq);
    if (allRead) return MessageTickStatus.read;
    final allDelivered = otherMembers.every((m) => m.lastDeliveredSeq >= seq);
    if (allDelivered) return MessageTickStatus.delivered;
    return MessageTickStatus.sent;
  }

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    int? seq,
    String? body,
    String? clientId,
    DateTime? createdAt,
    MessageStatus? status,
    String? errorMessage,
    bool? isSystem,
    Map<String, dynamic>? systemData,
    String? senderDisplayName,
    String? senderAvatarSeed,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      seq: seq ?? this.seq,
      body: body ?? this.body,
      clientId: clientId ?? this.clientId,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      isSystem: isSystem ?? this.isSystem,
      systemData: systemData ?? this.systemData,
      senderDisplayName: senderDisplayName ?? this.senderDisplayName,
      senderAvatarSeed: senderAvatarSeed ?? this.senderAvatarSeed,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      conversationId: json['conversation_id'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      body: json['body'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc() ??
                DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      status: MessageStatus.sent,
      isSystem: json['is_system'] as bool? ?? false,
      systemData: json['system_data'] is Map<String, dynamic>
          ? json['system_data'] as Map<String, dynamic>
          : null,
      senderDisplayName: json['sender_display_name'] as String?,
      senderAvatarSeed: json['sender_avatar_seed'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'sender_id': senderId,
      'seq': seq,
      'body': body,
      'client_id': clientId,
      'created_at': createdAt.toIso8601String(),
      'is_system': isSystem,
      if (systemData != null) 'system_data': systemData,
      if (senderDisplayName != null) 'sender_display_name': senderDisplayName,
      if (senderAvatarSeed != null) 'sender_avatar_seed': senderAvatarSeed,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          clientId == other.clientId &&
          seq == other.seq &&
          status == other.status;

  @override
  int get hashCode => id.hashCode ^ clientId.hashCode ^ seq.hashCode;
}

class MembershipPointer {
  const MembershipPointer({
    required this.userId,
    required this.lastDeliveredSeq,
    required this.lastReadSeq,
    this.role = 'member',
  });

  final String userId;
  final int lastDeliveredSeq;
  final int lastReadSeq;
  final String role;

  bool get isAdmin => role == 'admin';

  MembershipPointer copyWith({
    String? userId,
    int? lastDeliveredSeq,
    int? lastReadSeq,
    String? role,
  }) {
    return MembershipPointer(
      userId: userId ?? this.userId,
      lastDeliveredSeq: lastDeliveredSeq ?? this.lastDeliveredSeq,
      lastReadSeq: lastReadSeq ?? this.lastReadSeq,
      role: role ?? this.role,
    );
  }

  factory MembershipPointer.fromJson(Map<String, dynamic> json) {
    return MembershipPointer(
      userId: json['user_id'] as String? ?? '',
      lastDeliveredSeq: (json['last_delivered_seq'] as num?)?.toInt() ?? 0,
      lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
      role: json['role'] as String? ?? 'member',
    );
  }

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'last_delivered_seq': lastDeliveredSeq,
    'last_read_seq': lastReadSeq,
    'role': role,
  };
}

class GroupMember {
  const GroupMember({
    required this.id,
    required this.username,
    required this.displayName,
    required this.avatarSeed,
    required this.role,
    this.joinedAtSeq = 0,
    this.lastDeliveredSeq = 0,
    this.lastReadSeq = 0,
    this.isOnline = false,
  });

  final String id;
  final String username;
  final String displayName;
  final String avatarSeed;
  final String role;
  final int joinedAtSeq;
  final int lastDeliveredSeq;
  final int lastReadSeq;
  final bool isOnline;

  bool get isAdmin => role == 'admin';

  GroupMember copyWith({
    String? id,
    String? username,
    String? displayName,
    String? avatarSeed,
    String? role,
    int? joinedAtSeq,
    int? lastDeliveredSeq,
    int? lastReadSeq,
    bool? isOnline,
  }) {
    return GroupMember(
      id: id ?? this.id,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      avatarSeed: avatarSeed ?? this.avatarSeed,
      role: role ?? this.role,
      joinedAtSeq: joinedAtSeq ?? this.joinedAtSeq,
      lastDeliveredSeq: lastDeliveredSeq ?? this.lastDeliveredSeq,
      lastReadSeq: lastReadSeq ?? this.lastReadSeq,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      avatarSeed: json['avatar_seed'] as String? ?? '',
      role: json['role'] as String? ?? 'member',
      joinedAtSeq: (json['joined_at_seq'] as num?)?.toInt() ?? 0,
      lastDeliveredSeq: (json['last_delivered_seq'] as num?)?.toInt() ?? 0,
      lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
      isOnline: json['is_online'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'display_name': displayName,
    'avatar_seed': avatarSeed,
    'role': role,
    'joined_at_seq': joinedAtSeq,
    'last_delivered_seq': lastDeliveredSeq,
    'last_read_seq': lastReadSeq,
    'is_online': isOnline,
  };
}

class GroupDetail {
  const GroupDetail({
    required this.id,
    required this.name,
    required this.memberCount,
    required this.members,
  });

  final String id;
  final String name;
  final int memberCount;
  final List<GroupMember> members;

  GroupMember? findMember(String userId) {
    for (final m in members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  GroupDetail copyWith({
    String? id,
    String? name,
    int? memberCount,
    List<GroupMember>? members,
  }) {
    return GroupDetail(
      id: id ?? this.id,
      name: name ?? this.name,
      memberCount: memberCount ?? this.memberCount,
      members: members ?? this.members,
    );
  }

  factory GroupDetail.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'] as List<dynamic>? ?? [];
    return GroupDetail(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      memberCount: (json['member_count'] as num?)?.toInt() ?? rawMembers.length,
      members: rawMembers
          .map((m) => GroupMember.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'member_count': memberCount,
    'members': members.map((m) => m.toJson()).toList(),
  };
}

enum MessageTickStatus { pending, failed, sent, delivered, read }

class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    this.name,
    this.memberCount,
    this.otherParticipant,
    this.lastMessage,
    required this.lastSeq,
    required this.createdAt,
    required this.updatedAt,
    this.otherDeliveredSeq = 0,
    this.otherReadSeq = 0,
    this.memberships = const [],
  });

  final String id;
  final String type;
  final String? name;
  final int? memberCount;
  final User? otherParticipant;
  final ChatMessage? lastMessage;
  final int lastSeq;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int otherDeliveredSeq;
  final int otherReadSeq;
  final List<MembershipPointer> memberships;

  bool get isGroup => type == 'group';
  bool get isDm => type == 'dm';

  int get resolvedMemberCount => memberCount ?? memberships.length;

  int myDeliveredSeq(String currentUserId) {
    for (final m in memberships) {
      if (m.userId == currentUserId) return m.lastDeliveredSeq;
    }
    return 0;
  }

  int myReadSeq(String currentUserId) {
    for (final m in memberships) {
      if (m.userId == currentUserId) return m.lastReadSeq;
    }
    return 0;
  }

  String get title {
    if (isGroup) {
      return (name != null && name!.trim().isNotEmpty) ? name!.trim() : 'Group';
    }
    return otherParticipant?.displayName.isNotEmpty == true
        ? otherParticipant!.displayName
        : (otherParticipant?.username.isNotEmpty == true
              ? '@${otherParticipant!.username}'
              : 'Conversation');
  }

  Conversation copyWith({
    String? id,
    String? type,
    String? name,
    int? memberCount,
    User? otherParticipant,
    ChatMessage? lastMessage,
    int? lastSeq,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? otherDeliveredSeq,
    int? otherReadSeq,
    List<MembershipPointer>? memberships,
  }) {
    return Conversation(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      memberCount: memberCount ?? this.memberCount,
      otherParticipant: otherParticipant ?? this.otherParticipant,
      lastMessage: lastMessage ?? this.lastMessage,
      lastSeq: lastSeq ?? this.lastSeq,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      otherDeliveredSeq: otherDeliveredSeq ?? this.otherDeliveredSeq,
      otherReadSeq: otherReadSeq ?? this.otherReadSeq,
      memberships: memberships ?? this.memberships,
    );
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawMemberships = json['memberships'] as List<dynamic>?;
    final memberships = rawMemberships != null
        ? rawMemberships
              .map((m) => MembershipPointer.fromJson(m as Map<String, dynamic>))
              .toList()
        : const <MembershipPointer>[];

    return Conversation(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'dm',
      name: json['name'] as String?,
      memberCount: (json['member_count'] as num?)?.toInt(),
      otherParticipant: json['other_participant'] != null
          ? User.fromJson(json['other_participant'] as Map<String, dynamic>)
          : null,
      lastMessage: json['last_message'] != null
          ? ChatMessage.fromJson(json['last_message'] as Map<String, dynamic>)
          : null,
      lastSeq: (json['last_seq'] as num?)?.toInt() ?? 0,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc() ??
                DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ??
                DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      otherDeliveredSeq: (json['other_delivered_seq'] as num?)?.toInt() ?? 0,
      otherReadSeq: (json['other_read_seq'] as num?)?.toInt() ?? 0,
      memberships: memberships,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      if (name != null) 'name': name,
      if (memberCount != null) 'member_count': memberCount,
      if (otherParticipant != null)
        'other_participant': otherParticipant!.toJson(),
      if (lastMessage != null) 'last_message': lastMessage!.toJson(),
      'last_seq': lastSeq,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'other_delivered_seq': otherDeliveredSeq,
      'other_read_seq': otherReadSeq,
      'memberships': memberships.map((m) => m.toJson()).toList(),
    };
  }
}

class WsEnvelope {
  const WsEnvelope({
    this.v = 1,
    required this.type,
    this.clientId,
    required this.payload,
  });

  final int v;
  final String type;
  final String? clientId;
  final Map<String, dynamic> payload;

  factory WsEnvelope.fromJson(Map<String, dynamic> json) {
    return WsEnvelope(
      v: (json['v'] as num?)?.toInt() ?? 1,
      type: json['type'] as String? ?? '',
      clientId: json['client_id'] as String?,
      payload: json['payload'] is Map<String, dynamic>
          ? json['payload'] as Map<String, dynamic>
          : <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'v': v,
      'type': type,
      if (clientId != null) 'client_id': clientId,
      'payload': payload,
    };
  }
}
