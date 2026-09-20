# ADR 0010: Custom User Model

## Status
Accepted

## Context
Django provides a built-in User model, but it is deeply tied to sequential integer IDs, separate username/email fields (where username is the default login), and case-sensitive uniqueness. We need a secure, scalable model that natively supports UUIDv4 primary keys and uses email for login.

## Decision
We will implement a custom User model (extending `AbstractBaseUser` and `PermissionsMixin`) **before the initial database migration**. 
1.  **Primary Key**: UUIDv4 to prevent enumeration and simplify client-side idempotency.
2.  **Login Field**: Email.
3.  **Uniqueness**: Email and Username both use case-insensitive `UniqueConstraint`s with Postgres `Lower()`.
4.  **Manager**: A custom `UserManager` normalizes emails to lowercase at creation.

## Consequences
*   **Pros**: Correct database schema from day one. Avoids complex migrations later. Enforces case-insensitive constraints at the database level, preventing spoofing (e.g., "Bob" vs "bob").
*   **Cons**: Requires upfront boilerplate (custom managers and forms if using Django Admin).
