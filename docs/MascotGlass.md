# Vault mascot and cinematic glass

The existing workspace gains a compact sidebar mascot/status panel and shared glass materials. Navigation, scan limits (none), file safety, graph data, and secure-record cryptography/authentication are unchanged.

## Native 3D mascot

VaultMascot.swift renders a local SceneKit character: beveled metallic body, inset face, luminous eyes, a small V emblem, side sensors, and an activity orbit. Geometry, materials, lights, and camera are created locally in code; no asset download, third-party engine, web view, or network service is used. This is a 3D scene rather than a flat image with a rotation effect.

The robot gently floats, turns, and blinks; its orbit moves only for an active operation. Eyes/status accents distinguish active work, authentication, locked/paused state, and attention. Continuous rendering is capped at 24 frames per second, stops in inactive windows, stops when the view is dismantled, and is disabled by Reduce Motion or the Cinematic animations preference. The scene and actions are reused while progress text changes, avoiding scene rebuilds for every counter update. Hidden mascots are removed from the view tree; their status text remains.

## Current activity, not simulated monitoring

VaultActivity.swift resolves the actual observable inputs into a public-facing status. It has no input for filenames, full paths, secure record titles, passwords, or raw error messages. Display priority is attention → authentication → active scan stage → import → actual folder-polling cycle → other background work → selected secure-vault state → monitoring-ready/paused/idle.

Scan counters show discovered and processed entries. No percentage is fabricated because a full scan total is unknown. Import percentages are shown only when a real total exists and are clamped to valid bounds. “Folders monitored while open” is a readiness statement, distinct from “Checking your folders” during a real poll. Idle rendering is decorative motion, not a claim that files are being scanned continuously. Secure state labels apply explicitly to the separate encrypted-record subsystem, not to the regular library.

LibraryStore exposes an operation-failed bit so informational import summaries are not mistaken for failures. WorkspaceStore exposes active polling and generic processing labels for storage analysis, text extraction, recovery, and retained-copy deletion. No private contents are forwarded into the mascot.

## Glass and motion

VaultStyle's existing quietPanel modifier now uses layered native ultra-thin material with a graphite tint, hairline specular borders, soft depth shadow, and a restrained highlight. Button labels stay outside the material layer and remain sharp. A custom button style supplies consistent glass controls, subtle hover outlines, and a small press response. Primary scan buttons use a tinted version. Existing plain file-card/navigation interactions and destructive confirmation/authentication flows are retained.

The background's lavender/teal illumination moves slowly over 22 seconds. Navigation uses a short easing transition. Increase Contrast removes atmospheric lighting and strengthens borders; Reduce Transparency uses opaque panel backgrounds. Reduce Motion disables mascot movement, background drift, navigation/hover/press movement, and graph hover/pulse animation. The same behavior can be selected manually with Settings → Cinematic animations. Light and dark accents remain adaptive.

Settings → Show 3D sidebar mascot hides the character while retaining readable activity text, which is useful for smaller windows. Sidebar navigation remains a native scrolling list, and the sidebar itself can still collapse. The decorative scene is hidden from VoiceOver; the panel exposes one concise activity label/value and avoids repeating per-frame announcements.

## Files

New: Vault/VaultMascot.swift (SceneKit character and live panel), Vault/VaultActivity.swift (testable status resolution), docs/MascotGlass.md.

Updated: VaultStyle.swift, WorkspaceView.swift, OverviewWorkspace.swift, FolderScanReview.swift, VaultApp.swift, DetailViews.swift (materials, controls, panel, preferences); KnowledgeMap.swift (honor the shared animation preference); LibraryStore.swift and WorkspaceStore.swift (observable non-sensitive activity); project.pbxproj (target source membership); FeatureTests.swift (activity semantics); README.md, Design.md, Validation.md (usage/evidence).

## Validation and remaining macOS checks

Static Swift grammar parsing and project/source-reference checks pass. The five activity tests cover real counters without invented percentages, import progress bounds, authentication/error precedence, idle versus active versus paused monitoring, and secure-only lock labels. They are written but unrun. This Linux host has no Swift compiler, Xcode, SceneKit renderer, or macOS window server; no build, visual render, GPU performance, or runtime claim is made.

Before relying on appearance, build on macOS and check both appearances; transparency/contrast/motion accessibility settings; idle/scanning/indexing/organization/import/polling/paused/authentication/lock/error states; labels at the minimum window size; sidebar collapse/reopen; key-window/background transitions; hiding/re-enabling the mascot; CPU/GPU behavior during a large local scan; native keyboard focus and disabled/destructive buttons; and Touch ID with the decorative SCNView present. Confirm that no secure fields appear in sidebar text and that no frame updates continue after hiding the scene or deactivating the window.
