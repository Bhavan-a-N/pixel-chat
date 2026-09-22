# ADR 0022: Group Last Admin Rule and Empty Group Deletion

## Status
Accepted

## Context
In group conversations, administrators manage membership, group settings (e.g. name), and member roles. If the sole administrator of a group is allowed to demote themselves to a standard member or leave without appointing a successor, the group becomes permanently "orphaned" without administrative privileges. Additionally, when all members leave a group, leaving an empty group conversation creates orphaned rows that waste database resources and provide no utility.

## Decision
1. **Last Admin Protection**:
   - Demotion (`PATCH /api/conversations/<id>/members/<user_id>/role` setting `role="member"`): An administrator cannot be demoted if they are the last remaining administrator in the group. Any such request fails with HTTP 400 (`ValidationError("Cannot demote the last admin.")`).
   - Leaving (`POST /api/conversations/<id>/leave`): An administrator cannot voluntarily leave a group if they are the sole administrator, unless other administrators exist or they are the sole remaining member of the entire group.
2. **Empty Group Deletion**:
   - When the last member leaves a group conversation (whether via `leave_group`), the conversation and its associated records are deleted within the exact same database transaction.
   - The leave endpoint returns `{"left": true, "deleted": true}` to notify the client of group termination.

## Consequences
- **Pros**: Guarantees every active group has at least one administrator. Automatically reclaims storage when groups are abandoned.
- **Cons**: A sole admin wishing to step down must promote another member before doing so.
