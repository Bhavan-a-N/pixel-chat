# 0028 - Pixel Art Custom Painter and Strict Theme

## Context
The app design was updated to follow a "Cozy Pixel Cafe" aesthetic: soft pastel colors, large rounded corner radii, soft shadows, and clean modern typography. The primary constraint was that pixel art is ONLY to be used for avatar critters and specific empty-state illustrations, maintaining crisp 1x1 scale mapping (`FilterQuality.none`), while the UI chrome remains entirely smooth.

## Decision

1. **Inline Grid-to-CustomPainter Strategy:** We opted against using SVG assets (`flutter_svg` dependency) or PNG sprites for the pixel art. Instead, a custom `PixelArt` widget reads 16x16 string arrays (e.g. `cat`, `envelope`) and renders them directly to the Flutter Canvas using `drawRect` with a standard `Paint` (where `isAntiAlias = false` guarantees razor-sharp edges). This is incredibly efficient, scales infinitely with zero artifacts, isolates the domain perfectly, and requires zero package dependencies.
2. **Avatar Identity Hashing:** We needed a deterministic way to assign avatars to users based on their IDs (`avatar_seed`), without making everyone the same color/animal. We implemented a custom djb2 string hashing function inside `CritterIdentity` (to avoid adding the `crypto` package) which selects the animal type, palette, and background ring deterministically.
3. **Strict Theming:** We introduced `AppPalette` and `AppTypography` in `app_theme.dart` removing hardcoded values from UI components.

## Status
Accepted.

## Consequences
- No external asset files (PNG/SVG) need to be managed for avatars.
- Pixel-perfect rendering is guaranteed across all device DPIs.
- Hashing logic handles all color and shape diversity deterministically.

### Group Avatars
For group avatars, conv.id was intentionally chosen as the seed rather than adding a dedicated vatar_seed field to the Conversation model. Since a conversation's ID is a stable UUID generated at creation and never changes, it perfectly satisfies the requirement for a deterministic, globally stable pixel art avatar for the group. It avoids requiring a database migration to add an vatar_seed column to the conversations table, keeping the implementation lightweight while fulfilling the design system requirements.
