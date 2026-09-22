import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_chat/features/chat/domain/chat_models.dart';

void main() {
  group('Chat Receipt Models & Invariants', () {
    final now = DateTime.now().toUtc();

    test('MembershipPointer parsing and JSON round-trip', () {
      final pointer = MembershipPointer(
        userId: 'u1',
        lastDeliveredSeq: 5,
        lastReadSeq: 3,
      );
      final json = pointer.toJson();
      expect(json['user_id'], 'u1');
      expect(json['last_delivered_seq'], 5);
      expect(json['last_read_seq'], 3);

      final parsed = MembershipPointer.fromJson(json);
      expect(parsed.userId, 'u1');
      expect(parsed.lastDeliveredSeq, 5);
      expect(parsed.lastReadSeq, 3);
    });

    test(
      'Conversation parses memberships, otherDeliveredSeq, otherReadSeq',
      () {
        final json = {
          'id': 'c1',
          'type': 'dm',
          'other_participant': {
            'id': 'u2',
            'username': 'bob',
            'display_name': 'Bob',
            'avatar_seed': 'seed2',
            'created_at': now.toIso8601String(),
          },
          'last_seq': 10,
          'other_delivered_seq': 8,
          'other_read_seq': 6,
          'memberships': [
            {'user_id': 'u1', 'last_delivered_seq': 10, 'last_read_seq': 7},
            {'user_id': 'u2', 'last_delivered_seq': 8, 'last_read_seq': 6},
          ],
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        };

        final conv = Conversation.fromJson(json);
        expect(conv.id, 'c1');
        expect(conv.otherDeliveredSeq, 8);
        expect(conv.otherReadSeq, 6);
        expect(conv.memberships.length, 2);
        expect(conv.myDeliveredSeq('u1'), 10);
        expect(conv.myReadSeq('u1'), 7);
        expect(conv.myDeliveredSeq('unknown'), 0);
      },
    );

    test('ChatMessage getTickStatus derives 4 states + failed correctly', () {
      ChatMessage makeMsg({required int seq, required MessageStatus status}) {
        return ChatMessage(
          id: 'm-$seq',
          conversationId: 'c1',
          senderId: 'me',
          seq: seq,
          body: 'Hello',
          clientId: 'cid-$seq',
          createdAt: now,
          status: status,
        );
      }

      // 1. Failed message
      final failedMsg = makeMsg(seq: 1, status: MessageStatus.failed);
      expect(
        failedMsg.getTickStatus(
          isMe: true,
          otherDeliveredSeq: 5,
          otherReadSeq: 5,
        ),
        MessageTickStatus.failed,
      );

      // 2. Pending message (status pending or seq <= 0)
      final pendingMsg = makeMsg(seq: -1, status: MessageStatus.pending);
      expect(
        pendingMsg.getTickStatus(
          isMe: true,
          otherDeliveredSeq: 5,
          otherReadSeq: 5,
        ),
        MessageTickStatus.pending,
      );

      // 3. Sent (seq > otherDeliveredSeq)
      final sentMsg = makeMsg(seq: 7, status: MessageStatus.sent);
      expect(
        sentMsg.getTickStatus(
          isMe: true,
          otherDeliveredSeq: 5,
          otherReadSeq: 3,
        ),
        MessageTickStatus.sent,
      );

      // 4. Delivered (seq <= otherDeliveredSeq and seq > otherReadSeq)
      final deliveredMsg = makeMsg(seq: 5, status: MessageStatus.sent);
      expect(
        deliveredMsg.getTickStatus(
          isMe: true,
          otherDeliveredSeq: 5,
          otherReadSeq: 3,
        ),
        MessageTickStatus.delivered,
      );

      // 5. Read (seq <= otherReadSeq)
      final readMsg = makeMsg(seq: 3, status: MessageStatus.sent);
      expect(
        readMsg.getTickStatus(
          isMe: true,
          otherDeliveredSeq: 5,
          otherReadSeq: 3,
        ),
        MessageTickStatus.read,
      );

      // 6. Incoming message (isMe == false) returns sent (no tick displayed)
      final otherMsg = ChatMessage(
        id: 'other',
        conversationId: 'c1',
        senderId: 'other',
        seq: 3,
        body: 'From Bob',
        clientId: 'c-bob',
        createdAt: now,
      );
      expect(
        otherMsg.getTickStatus(
          isMe: false,
          otherDeliveredSeq: 5,
          otherReadSeq: 5,
        ),
        MessageTickStatus.sent,
      );
    });
  });
}
