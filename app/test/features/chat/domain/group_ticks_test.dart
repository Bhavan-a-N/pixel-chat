import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_chat/features/chat/domain/chat_models.dart';

void main() {
  group('Group Ticks - getMembersTickStatus', () {
    final baseMessage = ChatMessage(
      id: 'msg-1',
      conversationId: 'conv-1',
      senderId: 'me',
      seq: 5,
      body: 'Hello team',
      clientId: 'c-1',
      createdAt: DateTime.now(),
      status: MessageStatus.sent,
    );

    test('Zero other members: tick stays sent (Amendment 7)', () {
      final status = baseMessage.getMembersTickStatus(
        isMe: true,
        otherMembers: [],
      );
      expect(status, MessageTickStatus.sent);
    });

    test('Incoming message (!isMe) returns sent regardless of pointers', () {
      final status = baseMessage.getMembersTickStatus(
        isMe: false,
        otherMembers: [
          const MembershipPointer(
            userId: 'user2',
            lastDeliveredSeq: 10,
            lastReadSeq: 10,
          ),
        ],
      );
      expect(status, MessageTickStatus.sent);
    });

    test('Pending message returns pending', () {
      final pendingMsg = baseMessage.copyWith(status: MessageStatus.pending);
      final status = pendingMsg.getMembersTickStatus(
        isMe: true,
        otherMembers: [
          const MembershipPointer(
            userId: 'user2',
            lastDeliveredSeq: 10,
            lastReadSeq: 10,
          ),
        ],
      );
      expect(status, MessageTickStatus.pending);
    });

    test('Failed message returns failed', () {
      final failedMsg = baseMessage.copyWith(status: MessageStatus.failed);
      final status = failedMsg.getMembersTickStatus(
        isMe: true,
        otherMembers: [
          const MembershipPointer(
            userId: 'user2',
            lastDeliveredSeq: 10,
            lastReadSeq: 10,
          ),
        ],
      );
      expect(status, MessageTickStatus.failed);
    });

    test('All other members read seq >= message seq -> read tick', () {
      final members = [
        const MembershipPointer(
          userId: 'user2',
          lastDeliveredSeq: 5,
          lastReadSeq: 5,
        ),
        const MembershipPointer(
          userId: 'user3',
          lastDeliveredSeq: 6,
          lastReadSeq: 6,
        ),
      ];
      final status = baseMessage.getMembersTickStatus(
        isMe: true,
        otherMembers: members,
      );
      expect(status, MessageTickStatus.read);
    });

    test(
      'Not all have read, but all have delivered seq >= message seq -> delivered tick',
      () {
        final members = [
          const MembershipPointer(
            userId: 'user2',
            lastDeliveredSeq: 5,
            lastReadSeq: 5,
          ),
          const MembershipPointer(
            userId: 'user3',
            lastDeliveredSeq: 5,
            lastReadSeq: 4, // hasn't read msg seq 5 yet
          ),
        ];
        final status = baseMessage.getMembersTickStatus(
          isMe: true,
          otherMembers: members,
        );
        expect(status, MessageTickStatus.delivered);
      },
    );

    test('Not all delivered seq >= message seq -> sent tick', () {
      final members = [
        const MembershipPointer(
          userId: 'user2',
          lastDeliveredSeq: 5,
          lastReadSeq: 5,
        ),
        const MembershipPointer(
          userId: 'user3',
          lastDeliveredSeq: 4, // hasn't received msg seq 5 yet
          lastReadSeq: 2,
        ),
      ];
      final status = baseMessage.getMembersTickStatus(
        isMe: true,
        otherMembers: members,
      );
      expect(status, MessageTickStatus.sent);
    });
  });
}
