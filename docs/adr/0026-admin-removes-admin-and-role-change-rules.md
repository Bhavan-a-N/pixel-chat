# ADR 0026: Admin Permissions, Role Changes, and Admin-Removes-Admin Rules

## Status
Accepted

## Context
Group chats require a clear, unambiguous permission model. We must decide whether all group members have equal authority or if administrative privileges are required for group governance. Specifically, we must establish rules regarding role changes (promotions and demotions) and whether one administrator can remove or demote another administrator.

## Decision
1. **Administrative Tier**:
   - `Membership.role` has two values: `admin` and `member`.
   - The creator of a group is assigned the `admin` role automatically upon creation.
   - All other initial or newly added members default to `member`.
2. **Administrative Operations (Admin-Only)**:
   - Only admins can:
     - Rename the group (`PATCH /api/conversations/<id>`).
     - Add new members (`POST /api/conversations/<id>/members`).
     - Remove members (`DELETE /api/conversations/<id>/members/<user_id>`).
     - Change member roles (`PATCH /api/conversations/<id>/members/<user_id>/role`).
   - Standard members attempting these operations receive HTTP 403 Forbidden.
   - Non-members receive HTTP 404 Not Found (avoiding group existence enumeration).
3. **Role Modifications & Admin-Removes-Admin**:
   - Any administrator can promote a standard member to administrator.
   - Any administrator can demote another administrator to member, provided the target is not the last remaining administrator (ADR 0022).
   - Any administrator can remove another administrator from the group, provided the target is not the last remaining administrator.
   - Self-removal via `DELETE /members/<user_id>` is prohibited; admins and members must use `POST /leave` to voluntarily exit.

## Consequences
- **Pros**: Peer-admin model avoids hierarchical deadlock if a creator becomes inactive. Fully symmetrical administrative powers with strict last-admin safeguards.
- **Cons**: Co-admins must trust each other, as any admin can remove another admin if at least two admins exist.
