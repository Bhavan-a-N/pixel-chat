# ADR 0021: Read-Delivered Invariant and Client Tick Derivation

## Status
Accepted

## Context
Message receipt state needs to be displayed to users through standard chat tick indicators (Pending, Sent, Delivered, Read). Because we track state as monotonic sequence pointers rather than per-message status records, the client must derive each outgoing message's status dynamically from the other participant's pointers. In addition, reading a message inherently implies that the message was delivered, so `last_read_seq` must never exceed `last_delivered_seq`.

## Decision
1. **Read-Delivered Invariant**:
   - `last_delivered_seq >= last_read_seq` is enforced both in SQL (using `GREATEST(last_delivered_seq, seq)`) and in client state transitions.
2. **Decoupled Ack Handling**:
   - **Delivered Acks**: Managed at a global lifecycle level (`ConversationsNotifier`) active as long as the WebSocket connection exists, independent of whether any chat screen is open. Highest received `seq` across conversations is debounced (~300ms) and sent. On reconnect, for non-viewed conversations with unread incoming messages (`last_seq > my_delivered_seq`), `chat.delivered` is sent for `last_seq` without needing message fetches.
   - **Read Acks**: Managed strictly by the open chat screen (`ChatScreen` / `ChatNotifier`). Dispatched only when the screen is open, foregrounded (`AppLifecycleState.resumed`), and scrolled to the bottom (newest message visible). Debounced ~300ms.
   - **Acks are Never Sent for Own Messages**: A client never sends delivery or read acknowledgements for messages sent by the authenticated user.
3. **Tick Derivation**:
   - Applied only to outgoing messages (`isMe == true`):
     - `seq <= 0` or pending status $\to$ **Pending** (Clock icon: `Icons.access_time_rounded`, `AppColors.outline`).
     - `seq > otherDeliveredSeq` $\to$ **Sent** (Single check: `Icons.check_rounded`, `AppColors.outline`).
     - `seq <= otherDeliveredSeq && seq > otherReadSeq` $\to$ **Delivered** (Double check: `Icons.done_all_rounded`, `AppColors.outline`).
     - `seq <= otherReadSeq` $\to$ **Read** (Double check: `Icons.done_all_rounded`, `AppColors.primary`, rendered inside a filled container `AppColors.primaryContainer` to ensure distinct visual differentiation beyond color).
     - Failed status $\to$ **Failed** (Error text and Retry button).

## Consequences
- **Pros**: Client derives status purely in O(1) from message `seq` and participant pointers. No state explosion or synchronization drift. Clean visual accessibility for colorblind users.
- **Cons**: Skipping reading past unread messages marks everything up to the highest visible message as read.
