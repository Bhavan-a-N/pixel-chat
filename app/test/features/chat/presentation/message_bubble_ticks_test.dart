import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_chat/features/chat/domain/chat_models.dart';

void main() {
  testWidgets('ChatMessage getTickStatus produces correct tick indicators', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();

    ChatMessage createMessage({
      required int seq,
      required MessageStatus status,
      required String clientId,
    }) {
      return ChatMessage(
        id: 'msg-$clientId',
        conversationId: 'c1',
        senderId: 'user-me',
        seq: seq,
        body: 'Test msg $clientId',
        clientId: clientId,
        createdAt: now,
        status: status,
      );
    }

    // 1. Pending message
    final pendingMsg = createMessage(
      seq: -1,
      status: MessageStatus.pending,
      clientId: 'pend',
    );
    expect(
      pendingMsg.getTickStatus(
        isMe: true,
        otherDeliveredSeq: 10,
        otherReadSeq: 10,
      ),
      MessageTickStatus.pending,
    );

    // 2. Sent message (seq > otherDeliveredSeq)
    final sentMsg = createMessage(
      seq: 8,
      status: MessageStatus.sent,
      clientId: 's8',
    );
    expect(
      sentMsg.getTickStatus(isMe: true, otherDeliveredSeq: 5, otherReadSeq: 2),
      MessageTickStatus.sent,
    );

    // 3. Delivered message (seq <= otherDeliveredSeq and seq > otherReadSeq)
    final delivMsg = createMessage(
      seq: 5,
      status: MessageStatus.sent,
      clientId: 'd5',
    );
    expect(
      delivMsg.getTickStatus(isMe: true, otherDeliveredSeq: 5, otherReadSeq: 2),
      MessageTickStatus.delivered,
    );

    // 4. Read message (seq <= otherReadSeq)
    final readMsg = createMessage(
      seq: 2,
      status: MessageStatus.sent,
      clientId: 'r2',
    );
    expect(
      readMsg.getTickStatus(isMe: true, otherDeliveredSeq: 5, otherReadSeq: 2),
      MessageTickStatus.read,
    );

    // 5. Failed message
    final failedMsg = createMessage(
      seq: -1,
      status: MessageStatus.failed,
      clientId: 'f1',
    );
    expect(
      failedMsg.getTickStatus(
        isMe: true,
        otherDeliveredSeq: 5,
        otherReadSeq: 2,
      ),
      MessageTickStatus.failed,
    );
  });
}
