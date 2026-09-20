class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
    required this.avatarSeed,
    required this.createdAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String avatarSeed;
  final DateTime createdAt;

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      avatarSeed: json['avatar_seed'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'display_name': displayName,
      'avatar_seed': avatarSeed,
      'created_at': createdAt.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          username == other.username &&
          displayName == other.displayName &&
          avatarSeed == other.avatarSeed;

  @override
  int get hashCode =>
      id.hashCode ^
      username.hashCode ^
      displayName.hashCode ^
      avatarSeed.hashCode;

  @override
  String toString() =>
      'User(id: $id, username: $username, displayName: $displayName)';
}
