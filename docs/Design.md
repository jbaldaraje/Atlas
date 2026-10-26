> The later requested mascot/glass update is documented in [MascotGlass.md](MascotGlass.md). It adds optional native 3D sidebar motion, live activity, glass surfaces, and slow background lighting while preserving this workspace structure.

# Vault · spatial workspace design

Implemented from the uploaded cinematic workspace brief. The uploaded text ends mid-sentence in the Storage section; no missing requirements are inferred. This is native SwiftUI source, not a rendered application screenshot or a verified macOS build.

## Composition

The native title bar owns search, import, workspace navigation, and inspector toggle. A quiet resizable sidebar carries an illuminated accent edge on its selected row. The main workspace is expansive; the context panel uses the macOS 14 inspector presentation and starts collapsed. Selecting a file/subject/collection reveals it; Option–Command–I toggles it. Navigation remains available through a symbol-bearing toolbar menu when the sidebar is collapsed. Large dashboard headings and the previous statistic-card overview have been removed.

The Overview uses actual imported files, actual successful default-app-open events, real subjects and collections, and a miniature representation of explicit file relationships. Nothing is seeded into the library. Until files are opened through Vault there is no invented Recently Opened section. The first file-open event is recorded only after NSWorkspace reports success; file access remains scoped until that completion callback. Approved-location controls sit in a disclosure instead of dominating the opening screen.

## Materials and typography

VaultStyle centralizes midnight charcoal and graphite surfaces, adaptive lavender/teal/amber accents, hairline borders, and restrained shadows. Light appearance uses darker accent colors for legibility. Atmospheric gradients and static guide dots remain behind interactive content. They do not move, intercept input, or appear as fake activity. Reduced Transparency makes floating controls opaque; Increase Contrast removes atmospheric lighting, strengthens guide/edge contrast, and stops dimming peripheral nodes. System typography and window controls retain native macOS behavior.

## Living map

KnowledgeMap renders documents, subjects, and collections from real persisted metadata. Secure records never enter this graph. Nodes use file-type symbols, restrained halos, favorite badges, compact type labels, selection rings, and hover expansion. Every item has a meaningful title rather than a generic data dot. Layouts are persisted independently of file paths; adding/filtering nodes preserves existing positions. Initial spacing is generated without collisions, and user dragging saves world coordinates rather than screen coordinates.

The camera supports background dragging, pinch zoom, explicit zoom buttons, fit, overview, focus on direct neighbors, and a structured list alternative. Context menus focus/expand nodes, open actual documents, reveal them in Finder, favorite, or create explicit relationships. Double-click opens a file; single click selects. Focusable nodes support Return to select and Space to focus; the list offers native keyboard buttons. VoiceOver actions can select/focus nodes. Search and subject/collection/membership layers narrow the graph. Rendering is capped at 150 matching nodes, prioritizing selection and its neighbors, with counts and a tooltip explaining the limit.

Curved lines distinguish membership from explicit links using color and inactive dashes. Hover and selection emphasize direct neighbors without removing unrelated data. A short pulse travels away from the active node along connected lines for 1.8 seconds after selection. The animation timeline then pauses; it also pauses when the scene is inactive and disables animation for Reduce Motion. There is no perpetual particle animation or idle node rearrangement.

At low zoom, peripheral labels collapse into type icons; selecting/hovering reveals a readable label. Focus reduces the visible graph to a node and its immediate neighborhood. This is not a recursive cluster hierarchy, force simulation, 3D scene, or minimap navigation system. Those are not presented as completed features.

## Inspector and practical library

The contextual inspector supports files, subjects, collections, and explicit relationships. Frequent file actions come first: Open, native in-app Quick Look Preview, Reveal, and Favorite. Metadata, organization, relationships, and opt-in text indexing use disclosure sections. Subject membership is editable; related files and link details can be inspected without changing source files. Quick Look owns rendering support; unavailable/stale files show access errors. File bookmarks remain scoped while the preview sheet is open.

The library retains grid/list, real thumbnails with file-type fallback, sorting including type, search, filters, batch actions, and review-before-drop-import. Its controls adapt into two rows when space is constrained. Storage cleanup and encrypted records retain their explicit confirmation/authentication flows; atmosphere does not turn a destructive or sensitive action into an ambiguous interaction.

## Validation required on macOS

Static syntax and project-structure checks pass, but visual quality, Swift type checking, framework APIs, Quick Look, gesture arbitration, selection/pan/zoom behavior, keyboard/VoiceOver, menu focus, light/dark/increased-contrast behavior, and reduced-motion rendering remain unverified on this Linux machine. Run the existing build/tests and the following disposable-fixture checklist on a Mac:

- Start with an empty library: no invented network, activity, storage values, or file cards.
- Add several real files, create subjects/collections and explicit links; verify all map node types and context inspectors.
- Move a node, change filters, leave/reenter Map, and restart; verify retained coordinates.
- Pan, pinch, fit, focus, expand, select, double-click, and use the organized list; verify world/screen coordinates remain consistent.
- Hover connected and unrelated nodes; check legibility and that selection pulses stop. Enable Reduce Motion and confirm no pulse/scale animation.
- Toggle inspector/sidebar, resize to minimum size, and test both appearances and Increase Contrast/Reduce Transparency.
- Open a file successfully and confirm Overview changes; cancel/fail an open and verify no false activity event.
- Preview supported and unsupported files, stale bookmarks, moved files, and disconnected volumes; close preview and verify access cleanup.
- Use only disposable files for original Trash, managed recovery, and permanent removal testing.
