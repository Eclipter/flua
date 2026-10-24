# Development

Requires macOS 27+, Apple Silicon and Apple Swift command-line tools (`xcode-select --install`). The wallpaper extension needs a macOS 27 SDK/runtime. There are no external Swift package dependencies.

```sh
make build          # Flua.app with the wallpaper extension, ad-hoc signature
make test           # model, library path, package security tests
make smoke          # builds Flua.app for an isolated library, tests, then exits
make run            # open the app
make release        # dist/Flua.zip
make wallpaper-test # isolated wallpaper extension tests, no OS activation
```

`Package.swift` supports SwiftPM and opening the source package in Xcode. Use `make build` for a runnable `.app`; `swift build` alone only produces an executable. Model/package tests are standalone executables run by `make test`, not XCTest targets. Smoke builds `build/Flua.app` with its provider catalog pointing to the fresh test library, replacing any previous build at that path. The smoke script acquires a shared per-user lock before checking for a running Flua, building, or launching the test app, whether started through `make smoke` or directly; concurrent smoke and native-host checks wait for the lock. Do not run a separate `make build` before `make smoke`. Quit any running Flua before smoke verification. Agents may gracefully quit it, including a normal library session, when needed without separate confirmation; wait for it to exit and do not force-quit a normal library session. The script refuses to start alongside another Flua process, runs its accessibility audit and background application check sequentially, and writes test data only to a fresh directory under `build/verification/`. GPU scene tests in `make test` render offscreen without launching Flua.

Run other GUI verification and native wallpaper procedures through `scripts/system-test-lock.py`, keeping the lock for the complete procedure, including restoration:

```sh
ui_check_dir=$(mktemp -d "$PWD/build/verification/ui-check.XXXXXX")
./scripts/system-test-lock.py "visual UI verification" \
    open -g -W build/Flua.app \
    --args \
    --data-dir "$ui_check_dir/library"
./scripts/system-test-lock.py "native wallpaper verification" /bin/zsh /path/to/native-wallpaper-check.zsh
```

The lock file lives in the system temporary directory, shared by Flua worktrees for the current user. The helper reports the active holder while waiting and the OS releases the lock when its process exits. Do not delete the lock file. A forced termination releases the lock but does not prove that native wallpaper settings were restored. `make wallpaper-test` runs standalone provider checks without OS activation and does not need the lock.

Opening a build made with `FLUA_CATALOG_PATH` without `--data-dir` opens the library that contains that catalog, including a smoke library. Its wallpapers, including the built-in scenes, can be applied. The standard Flua library stays closed. Passing `--data-dir` for a different library still blocks native wallpaper setup. Rebuild without `FLUA_CATALOG_PATH` before using the standard library.

Smoke launches in the background and treats application activation or an unexpected library error as a test failure. Library, Settings and editor checks use fully transparent parked windows; their snapshots are rendered from their views. The accessibility audit retains its nearly transparent parked windows so macOS exposes their accessibility elements. Live video and scene playback checks run consecutively in one 192 × 108-point nonactivating panel. The panel first stays behind other windows; only if it is occluded does verification raise it above other windows and allow it on the active fullscreen Space. Only playback windows use that behavior, one at a time, and the panel closes before export and editor checks continue. No fullscreen guard disables tests. Verification never activates Flua or explicitly switches Spaces. Playback checks record submitted scene frames and process CPU time, then check pause, hiding, window occlusion, resume and release. The same panel hosts the inspector to check video and scene Still/Animated transitions, independent surface modes and video resume, and saves four inspector screenshots for visual review when screen-recording access is available. Run `swift Tests/FluaTests/FullscreenVerificationTests.swift` to build and execute the full smoke while observing that only one playback window appears and the foreground application stays unchanged. It acquires the shared system-test lock and waits before observing windows or starting its timeout. Run it with fullscreen active to cover that setup; it is separate from `make test`. For a quick scene-only frame-rate check, use a fresh disposable directory:

```sh
preview_dir=$(mktemp -d "$PWD/build/verification/preview.XXXXXX")
./scripts/system-test-lock.py "scene preview verification" \
    open -g -W "$PWD/build/Flua.app" \
    --args \
    --data-dir "$preview_dir/library" \
    --preview-smoke "$preview_dir/results.json"
```

The preview check opens one visible window per scene in sequence and writes frame rate and CPU samples to `results.json`. On the built-in 60 Hz display under macOS 27.0.1, it measured 59.4–60.9 fps and 8.1–10.5% of one CPU core over 0.6-second samples. These short preview measurements do not represent long-run system-freeze or wallpaper-provider behavior.

Run `make scroll-test` for the opt-in scrolling performance regression check. It acquires the shared GUI lock, refuses to run alongside Flua, builds the app and opens one nonactivating 1440 × 900-point window with eight disposable wallpaper cards. ScreenCaptureKit requests 60 fps while the grid and inspector scroll separately. Each pane must deliver at least 45 fps with no captured-frame gap of 100 ms or longer; results and phase timings are saved under `build/verification/scroll.*/`. Screen-capture access is required, and display refresh rate or competing system load can affect the result. This checks sustained scrolling, not rare stalls outside the sampled intervals. Glass shadows belong on their background shapes: shadowing the entire control subtree reduced captured scrolling from about 58 to 29 fps in the isolated macOS 27.0.1 / built-in 60 Hz display comparison.

The build script updates the app bundle's modification time after signing so Launch Services can detect changed metadata and icon resources on subsequent launches.

Normal launches honor Settings → General → Show window on startup (enabled by default), independently of Open at login. Disabling it suppresses the initial library window; Dock reopen and Open Flua still open it.

The smoke launch suppresses automatic library-window creation to verify that the application opens it explicitly without activation. Reopen checks send a process-targeted system reopen event after closing and minimizing the library and verify that saved wallpaper assignments survive. Smoke requires an explicit `--data-dir`. It also launches separate disposable libraries with `--startup-smoke` to verify that normal startup shows or suppresses the library window according to the saved preference. Its library validates and saves choices using the real provider descriptor builder, but disables system Apply, Stop, restoration, refresh and provider removal. It does not call native provider registration or update the system wallpaper store; macOS can still discover the embedded extension when the app launches. Separate smoke checks confirm that missing saved choices fail validation and normal application mode still rejects a mismatched catalog. Actual native playback needs the separate OS integration procedure below, without `--smoke-test`.

UI smoke checks cover adaptive window layout, native window controls, scrolling, inspector hit targets and saved assignments. Desktop playlist and Stop checks must preserve the Lock Screen assignment, and surface assignments must survive persistence; a false or missing result fails smoke. `make test` exercises that failure aggregation without launching the app. Inspect the current build in a real window with a disposable `--data-dir` after every UI change; smoke captures alone do not replace that check. See [feature status](FEATURES.md) for the supported interface and [architecture](ARCHITECTURE.md) for component responsibilities.

## Layout

- `Sources/Flua/`: main application, rendering, persistence, media inspection, importer and editor.
- `Tests/FluaTests/`: deterministic model, library path and package validation tests.
- `Resources/`: bundle metadata and original application icon.
- `scripts/`: reproducible build, test and release entry points.
- `docs/`: architecture and feature status.
- `Sources/WallpaperExtension/`: wallpaper provider, compiled separately and embedded by `make build`.
- `.build/`, `build/`, `dist/`: ignored, generated artifacts.

## Changes and validation

Keep media and account information out of the repository. Test model/import changes with `make test`, and playback/UI/export changes with `make smoke`. Run `make wallpaper-test` when changing the provider protocol. Update [feature status](FEATURES.md) when support changes. Validation results belong in fresh generated output.

`make wallpaper-test` also verifies the boxed download-status reply over XPC. It does not register or select a wallpaper. Real-host playback and file-access checks use disposable containing apps, following the [provider verification and restoration procedure](../Sources/WallpaperExtension/README.md#playback-scoped-files-and-restoration). Keep their source copies, fixtures, local settings snapshots and logs outside Git.

Development and validation run locally; pushing changes is a separate developer action. No CI service, signing account or deployment credentials are required. Release bundles are ad-hoc signed, not notarized.

## Git workflow

Keep `main` linear with one squash commit per completed task. Work on a task branch in a separate worktree, then review the combined change and run its relevant checks before integration. Use an English Conventional Commit subject that describes the resulting change, such as `fix: restore wallpaper previews after selection`; summarize reasons or limitations in the body when needed.

Configure a squash command in each clone and prevent pulls from creating merge commits:

```sh
git config --local alias.squash "merge --squash"
git config --local pull.ff only
```

After reviewing the task branch, integrate from the `main` worktree:

```sh
git squash <task-branch>
# Review the staged diff and run the relevant checks before committing.
git commit
make build
```

A squash merge stages the combined change without creating a commit. Keep the task branch and worktree until the commit succeeds. After the commit is on `main`, run `make build` from that worktree with `FLUA_CATALOG_PATH` and `FLUA_WALLPAPER_IDENTIFIER` unset, so `build/Flua.app` matches `main` and the standard library. For GitHub pull requests, use **Squash and merge** or `gh pr merge --squash`, and edit the final title and body to describe the whole change. Update the local `main` checkout after that merge, then run the same build. Repository settings should enable squash merging and disable merge commits and rebase merging, using the pull request title and description for the squash message. The `git squash` alias runs `git merge --squash`; `pull.ff=only` rejects pulls that would merge diverged history. Local Git configuration is not copied by cloning; apply the commands above in every new clone. Rewriting published history and force-pushing require an explicit request.

## Lock Screen integration checks

`make build` embeds the sandboxed `local.flua.desktop.wallpaper` provider in `build/Flua.app`. The main app requires macOS 27+; the standalone extension currently has a macOS 26 deployment target. Native playback uses guarded wallpaper-store transactions and a retained restoration baseline, as described in [architecture](ARCHITECTURE.md#native-wallpaper-boundary).

For isolated integration checks, create a fresh library outside the normal application-support directory and build with its absolute catalog path:

```sh
FLUA_CATALOG_PATH=/absolute/path/to/disposable-library/catalog.json \
    FLUA_WALLPAPER_IDENTIFIER=local.flua.desktop.wallpaper.disposable-test \
    make build
open -g -n build/Flua.app \
    --args \
    --data-dir /absolute/path/to/disposable-library
```

The override is compiled into the extension’s plist and sandbox read exception. Without `--data-dir`, the app opens the directory containing that catalog. It refuses setup when an explicit library differs from that path. A build without the override uses the standard Flua library. After tests, rebuild without the override before using the app normally. `make wallpaper-test` checks the library-only catalog and repeated atomic catalog replacement over XPC. `make test` checks safe service PID parsing, media path containment, descriptor generation, all display/Space store updates, metadata preservation and unsupported-store rejection. These tests do not activate system wallpapers.

Before real-host selection, follow the [snapshot and restoration procedure](../Sources/WallpaperExtension/README.md#playback-scoped-files-and-restoration), using the disposable provider identifier and preserving existing registrations. Exercise **Set Wallpaper** (which assigns and applies to the native system) with saved independent and linked surface choices in both display modes and with a newly imported fixture and verify both the saved choice and host scoped-file acquisition. Check that closing the guard input resumes the paused agent. Restore both store plists while the agent is paused, then restart it; compare choices against the baseline while ignoring only system-maintained timestamps. Use Settings → Lock Screen → Remove native provider… to test restoration and exact-path unregistration. Also check Stop and removal with a missing or unusable baseline: affected surfaces should silently use the macOS default wallpaper. For manual cleanup, unregister the exact extension with `pluginkit -r <app>/Contents/Extensions/FluaWallpaperExtension.appex`, then the containing app with `lsregister -u <app>`. Restore previous wallpaper choices and provider paths, preserving concurrent user changes. Keep snapshots and logs out of Git.

Native removal was checked on arm64 macOS 27.0.1 (26A434) using a disposable catalog and provider identifier. The settings controls and confirmation were visually inspected. Two Apply/removal cycles restored `Index.plist` and `Index_v2.plist` apart from `LastSet`/`LastUse`, removed the exact test registration and preserved every unrelated provider path. A playback-speed edit left the original baseline unchanged. Temporarily withholding that baseline produced the recovery message without changing the active selection; restoring it allowed retry. Removal retained the library. The shared baseline now remains available for Stop and retry. The merged saved-assignment/Stop implementation also passed a Per Display Apply/removal cycle on the built-in display: both stores matched the pre-apply snapshot apart from timestamps, the provider was absent and the shared baseline remained. Removal repeats its guarded restoration after unregistration to clear cached host selections. This does not verify physical multi-display restoration or other OS versions.

Default-wallpaper fallback was checked separately on the built-in display using a disposable catalog and provider. Stop passed with missing and malformed baselines, including Desktop-only and Lock Screen-only fallback while retaining a foreign photo on the other surface. Removal without a baseline cleared test-provider choices in both the primary store and a deliberately seeded secondary store before unregistering the exact provider. Expected and actual stores matched apart from `LastSet`/`LastUse`; both original stores and the full provider-path list were restored afterwards. Generated fallback surfaces include both required timestamps. This checks native store acceptance and restoration, not visible Lock Screen output or physical multi-display behavior.

### Automatic saved-assignment routing

Use a disposable app bundle with a unique containing-app identifier, a unique `FLUA_WALLPAPER_IDENTIFIER`, a fresh `--data-dir`, and `FLUA_CATALOG_PATH` pointing into that library. Before applying, snapshot both wallpaper stores and record the existing provider paths.

1. Target Lock Screen with Northern lights selected and click **Set Wallpaper** once.
2. Select Deep space and target Lock Screen, without applying again. Require `nativePlayback` to remain active and every test-provider `Idle` descriptor in `Index.plist` to update automatically to contain the new scene. Confirm the Desktop remains unassigned and `Index_v2.plist` has no test-provider choice.
3. Use Settings → Lock Screen → Remove native provider… . Confirm the temporary provider and app registrations are gone, the pre-existing Flua provider registration is unchanged, and both stores match their snapshots ignoring only `LastSet` and `LastUse`.

This passed on arm64 macOS 27.0.1 (26A434) with one built-in display. Saving Deep space changed all 13 test-provider `Idle` descriptors from `aurora` to `cosmos` without a second Apply; the library retained active native intent. The Desktop remained unassigned, `Index_v2.plist` had no test-provider descriptor, both stores matched their original snapshots apart from system timestamps after removal, and the pre-existing Flua provider registration was unchanged. No renderer process was observed after the assignment change. The check targeted only the Lock Screen while the session was unlocked, so it verifies host-store routing, not visible Lock Screen output.

Native recovery checks use a separate provider identifier and disposable library, with both wallpaper stores and registrations recorded before selection. Apply a deliberately undecodable copied image, restore its original bytes at the same path and verify a recovered renderer in the host log without changing the saved descriptor. Terminate only that disposable provider process, then explicitly apply the unchanged assignments and verify a new host acquisition. Restore both stores apart from host timestamps and remove only the disposable registration. To check fresh wrappers, remove all POSIX permissions from the disposable image before Apply and require fallback with zero scoped files. Restore owner read/write permission, explicitly apply the unchanged choices and require a new provider process rendering the image with one wrapper and one active scope. This passed on macOS 27.0.1 (26A434) with one built-in display; it does not simulate revocation of an existing sandbox token. After terminating only that provider, no acquisition was observed during a 12-second wait; explicit Apply reacquired the image. If cleanup materializes the original default globally, verify it is the only non-timestamp difference and restore the original inheritance marker through the guarded transaction. Both stores and provider paths must match before finishing.

For provider-crash observation, require frame and loop progress first, record the exact disposable provider PID and WallpaperAgent PID, then kill only that provider and poll for a replacement without Apply or host restart. A 90-second check on 23 October 2026 observed no replacement while WallpaperAgent stayed alive; unchanged Apply subsequently recovered scoped playback. For a separate voluntary lease-release check, instrument only a disposable source copy to balance the renderer's active URL leases while retaining host wrappers, then probe a fresh POSIX open/read before and after release. On the same setup, a fresh open succeeded before release and failed with `EPERM` afterwards, preventing a new read, and unchanged Apply reacquired scoped playback. This narrower check does not revoke a still-active host-issued grant or establish automatic recovery after access loss. See the [results and rollback evidence](../Sources/WallpaperExtension/README.md#provider-termination-and-released-access-lease). Keep production sources unchanged and do not substitute lease release, POSIX permission changes or path removal for live host-token revocation.

For video recovery, replace a copied fixture with undecodable bytes before Apply, restore its original bytes at the same path without reapply, and require recovery in the same provider process followed by frame and loop progress with scoped access. Then terminate only that provider, reapply the unchanged assignment and require a new process with continued loops and an unchanged descriptor. This passed on the same OS and display setup, with both processes reaching 90 frames and three loops; both stores and original provider paths were restored. This does not test file loss during active playback.

For active decoder recovery, first require a disposable video session to advance frames, then truncate the copied media in place without replacing its inode. Require the existing context to switch to the static fallback, restore the bytes into the same file, and require recovery with frame and loop progress, scoped access and unchanged descriptors. `make wallpaper-test` runs the same truncation/recovery path outside the host. The real-host check passed on macOS 27.0.1 (26A434) with one built-in display: playback reached 90 frames / three loops before truncation and again after recovery, with one scoped file and active scope. `Index.plist` matched its snapshot apart from `LastSet`/`LastUse`, `Index_v2.plist` matched exactly, and original provider paths were restored. This verifies host-session fallback and recovery, not visible output or revoked sandbox tokens.

When investigating verification errors, capture the transformed store and the actual store at the verification read, before another transaction replaces `NativeWallpaperBackup.plist`. Compare those values apart from `LastSet`/`LastUse`; a later restored snapshot does not establish what failed. Before a subsequent guarded rollback, wait for the restarted wallpaper service to be available and resolve its new PID; reusing the just-terminated service can prevent the guard from becoming ready. Per Display Apply can copy a requested Desktop or Lock Screen choice into `SystemDefault` and some Space defaults. Its verifier accepts only that observed propagation of the exact requested surface choice; unrelated differences still fail. See the [Apply verification results](../Sources/WallpaperExtension/README.md#native-apply-verification).

Automatic media/player retries wait while suspended; missing or unusable host wrappers require reapply for fresh access. Catalog retries are covered by `make wallpaper-test`, including a failed access reply and deletion/recreation. Physical display reconnection still requires a real multi-display setup.

Native launch/edit checks use separate processes with the production `Library` startup and edit methods, an embedded disposable provider, a matching catalog grant and a fresh library. Follow the same snapshot and rollback procedure before starting:

1. Save independent video/Still Desktop and scene/Animated Lock Screen assignments with active native intent. Start a process, allow startup restoration to finish, and compare both system descriptors with `NativeWallpaperStore.assignments`. Require no desktop overlay and host acquisition of the disposable provider with an active scoped video file.
2. Exit and start another process from the saved library. Check the assignments and modes again. Make rapid speed edits followed by dimming, fit, video trim and thumbnail changes through `Library.edit`; wait for refresh to finish. Compare retained descriptors with the latest catalog, require the original baseline bytes to remain unchanged, and check fresh host acquisition without media errors.
3. In another process, invoke Stop and verify restoration and persisted stopped intent. Start once more and require no native selection or desktop overlay while retaining saved surface choices.
4. Restore only disposable-provider choices from the snapshot through the guarded transaction, unregister the exact extension and app, then repeat restoration if cached selections return. If Mirrored Stop materialized the original default as a global choice, verify that this is the only non-timestamp difference and restore the original global inheritance marker under the guard. Move the unregistered disposable extension out of the containing bundle to prevent rediscovery. Compare both stores ignoring only `LastSet`/`LastUse`, and require the original provider paths to match.

This sequence passed on macOS 27.0.1 (26A434), arm64, with one built-in display. The harness replaced the UI entrypoint in a disposable source copy; production library and provider code handled the transactions. It did not test Dock/window reopening, visible Lock Screen output, idle, sleep/wake or physical multi-display behavior. Detailed observations are in the [provider documentation](../Sources/WallpaperExtension/README.md#native-launch-restoration-and-edit-refresh).

For real transition checks, apply independent Animated Desktop and Still Lock Screen video/scene fixtures from a disposable containing harness, then let that process exit. Start the real screen saver with `open -g /System/Library/CoreServices/ScreenSaverEngine.app`; require a non-preview host acquisition followed by `idle=1` and `idle=0` updates. Record frame/loop counts to distinguish a held Still frame from Animated playback, and have the user confirm visible output. Explicit lock/unlock is a separate check requiring user unlock. Preserve password and idle-timeout preferences. Restore both stores and original provider paths as above. Video Animated/Still and aurora Still idle presentation, plus brief aurora Still lock/unlock, passed on macOS 27.0.1 with one built-in display; see the [recorded scope](../Sources/WallpaperExtension/README.md#native-locked-and-idle-transitions).

For automatic idle checks, record the original screen-saver timeout and leave the mouse and keyboard untouched until macOS starts the screen saver; do not launch it manually. If the user authorizes a shorter temporary timeout, restore and verify the original value before cleanup. Leave display-sleep and password preferences unchanged. Animated aurora passed this check with the containing harness exited on one built-in display on macOS 27.0.1; see the [recorded result and rollback evidence](../Sources/WallpaperExtension/README.md#native-locked-and-idle-transitions).

## Playback pause verification

`make test` checks preference export, legacy catalog compatibility and cached descriptor configuration. `make wallpaper-test` checks policy decisions and real video pause/resume without changing saved modes or overriding host suspension. These are isolated checks, not physical power-transition verification.

The Low Power Mode switch pauses when macOS Low Power Mode is enabled. The independent low battery switch pauses when the Mac is unplugged and its battery is at or below the selected threshold. The threshold picker appears only when low battery pause is enabled. Existing libraries retain their combined switch value for both preferences. The separate on-battery switch pauses at any battery level while unplugged. Fullscreen pause follows native fullscreen Spaces on the destination display; it does not infer fullscreen from a borderless window’s size. Display state is checked at 30 Hz so desktop and Mission Control transitions do not wait for the one-second power check. Power preferences apply to Desktop and Lock Screen playback; fullscreen pause applies only to Desktop. Preference pauses do not affect app previews or playlist timing.

For real-host verification, use the disposable matching-catalog build and wallpaper-store rollback procedure above. Apply Animated video and scene choices, exit Flua, and verify stopped frame counts and resumption after each condition clears. Cover unplug/reconnect, macOS Low Power Mode, the battery threshold boundary, Settings changes during playback, provider restart, native fullscreen entry/exit on each physical display, and locked/idle presentation. A host suspension must remain in effect when a preference condition clears. Preserve and restore the original power settings, Space/window state, wallpaper stores and provider registrations. Unknown battery readings do not trigger the threshold rule; unavailable Space APIs or a missing destination display ID do not trigger fullscreen pause.

## Keyboard verification

The library controls were checked on macOS 27.0.1 (26A434) with the existing macOS Keyboard navigation preference enabled, using disposable `--data-dir` libraries. Repeat this check after changes to browsing controls:

1. Use Tab and Shift-Tab to reach Search, the playback-type picker and all five filter menus. Use arrows and Space for the playback type; Space opens menus, then arrows and Return select values.
2. Choose filters or enter a search with no matches. Reach Clear search and Clear filters with Tab, activate with Space, and confirm results return.
3. From a fresh window, Tab to the Tags field in the right-hand details panel. Edit its comma-separated text and press Return. Confirm the saved tags remain after selecting another wallpaper and returning; no duplicate tag buttons appear below Motion intensity.
4. Open Settings with Command-comma. Tab to the blocked-tag field and submit with Return; also test Tab/Space on Block and Unblock. Confirm blocked entries disappear and unblocking restores them.

Favorite buttons identify the wallpaper in their accessible name (for example, “Add favorite: Northern lights”). Filter buttons expose “All” or the sorted selected values as their accessibility value. The accessibility audit checks these values for all five filters and invokes the favorite and remove-favorite accessibility actions, checking both the updated name and library state. These checks exercise the accessibility API; they do not verify spoken VoiceOver navigation.

For spoken verification, enable the VoiceOver Caption Panel and use a system-global key helper to activate the isolated Flua window and send VoiceOver commands. Send explicit `flagsChanged` events when pressing VoiceOver modifiers before a command and releasing them afterwards; app-targeted CUA input and modifier flags attached only to regular key events did not reach VoiceOver. Capture the full screen with `screencapture` so the caption output is retained. Restore the original VoiceOver state and input source after the check.

On macOS 27.0.1 (26A434), a fresh disposable library was used. VoiceOver captions announced **Search** as edit text and **Clear search** as a button; activating Clear search after a no-match query restored four cards. The filter menus announced their labels and values: **Category filter** changed from All to Nature, and Color, Motion, Resolution and Aspect opened with All and first choices Red, Low, Below 720p and Portrait. Activating **Clear filters** reset the category selection. The **Tags** field announced its current contents as selected text and edit text; submitting `voiceovercheck` persisted the tag. **Add favorite: Northern lights** changed to **Remove favorite: Northern lights** when activated, then returned after removal; the saved favorite value was false at the end.

The **Source** control selected Built-in. **Playback type** selected Still, which showed no matching cards, then All, which restored the four built-in scenes. Settings exposed **Blocked tags**; submitting `voiceovercheck` hid Northern lights and cleared its inspector selection, and **Unblock voiceovercheck** restored the wallpaper and cleared the blocked-tag setting. The saved disposable library retained the edited tag and had no favorite or blocked tag. VoiceOver also announced **Previous in playlist**, **Next in playlist**, **Stop on selected displays** and **Set Wallpapers**; these controls were read through the item chooser and not activated. The app build's catalog did not match the disposable library, so native Apply/Stop routing was unavailable; no system wallpaper changed. This verifies library navigation and editing plus playback-control discovery, not native playback through VoiceOver. The shared system-test lock covered the session; VoiceOver was restored to off, the original input source was restored, and the isolated app was closed. Captures and saved-state evidence remain outside Git in `/tmp/flua-voiceover-20261023`.

On macOS 27.0.1, `make smoke` also passed after the accessibility-name changes. It runs the offscreen name check, then the interactive suite. The names checked are Search, the five filter menus, Clear search, Clear filters, Remove tag filter, favorite and playback buttons, and Settings → Blocked tags. Repeat the name check after browsing-control changes:

```sh
audit_dir=$(mktemp -d "$PWD/build/verification/accessibility.XXXXXX")
./scripts/system-test-lock.py "accessibility audit" \
    build/Flua.app/Contents/MacOS/Flua \
    --data-dir "$audit_dir/library" \
    --accessibility-audit "$audit_dir/results.json"
```

The smoke suite checks filter reset, including preservation of persisted blocked tags. Its accessibility audit and the spoken-caption check provide separate evidence: the audit inspects names and values through the accessibility API, while the caption check confirms actual VoiceOver announcements and the exercised actions above.

## Local data and packages

The bundle ID is `local.flua.desktop`. Normal launches use `~/Library/Application Support/Flua/`; an explicit `--data-dir` selects a separate library. The app creates its library on first launch and retains existing Flua data. It does not search other application directories. Login startup is opt-in.

The library root contains `library.json`, `catalog.json` and a `Media/` directory of copied imports. `catalog.json` is rewritten on each successful save and lists image and video files for the wallpaper provider, plus the four built-in scenes with no media file. Rows include speed, dimming, fit, trim, still-frame time, desktop and Lock Screen modes, and playback preferences. The catalog also publishes the current playback preferences for existing provider sessions. Scene still time is 7. Removing a scene retains its media file. If `library.json` cannot be decoded, the app shows the initial scenes in memory and blocks saves and imports, preserving the unreadable manifest. Quit before inspecting or restoring that file. For isolated runtime verification, supply both `--data-dir` and `--smoke-test` or use `make smoke`, which supplies both automatically; `--smoke-test` alone does not select a separate library.

Video wallpaper exports use `.flua` folders containing a video, thumbnail and JSON manifest. Imports accept manifest folders, direct JSON manifests and ZIP archives. ZIP members and media paths are validated before import; source files remain intact. Interactive scene runtimes are unsupported.

A folder must contain exactly one `manifest.json` or `*-manifest.json`; a directly selected JSON file can have any name. A ZIP or `.bdpkg` archive may contain that layout at its root or inside a single top-level folder. The minimum manifest is:

```json
{
  "type": "video",
  "files": {"asset": "clip.mp4"}
}
```

The asset must be a regular `.mov`, `.mp4` or `.m4v` file within the package. Optional imported fields are `title`, `tags` (an array or comma-separated string), `details`, `categoryIdentifier`, `linkTitle`, `linkURL`, `color`, `motionIntensity` and `thumbnailTimestamp`. Imports measure media facts locally and generate their own thumbnails; a manifest's dimensions, duration, date added and thumbnail file are not used as those facts or the library thumbnail.

Manifests are limited to 1 MiB and archives to 512 MiB. Folder and ZIP validation also limits individual files to 512 MiB, expanded contents to 1 GiB and entries to 4,096. ZIP import accepts stored or deflated entries and rejects links, unsafe or conflicting paths, AppleDouble entries, encryption, streaming entries, ZIP64, archive comments and excessive expansion. Directly selected manifests validate the named asset without walking unrelated files beside the manifest or imposing these folder-size limits.

The video context menu offers Export Wallpaper…; package export refuses an existing destination. Exported video omits audio tracks without changing the source. The editor exposes only preview, trim and cover selection. Save Changes commits the draft, and Cancel closes it without saving. Video export helpers remain internal for package generation and verification; no quality, audio or separate MP4/preview/PNG export controls are shown.

Browsing rules and media bucket boundaries are tested in `ModelTests.swift`. Playlist checks block `nature` in Slow mornings, verify startup chooses the first remaining wallpaper, advance and rewind through eligible entries, skip a current item that becomes blocked, and preserve the saved playlist contents. Native descriptor catalogs use the same blocked-tag rule. The isolated smoke run additionally measures image/video imports and rotated video, exercises legacy metadata backfill, checks classification preservation through package export/import, and verifies blocked wallpaper entries, cleared selections, filter reset without clearing persisted blocked tags, and the VoiceOver names of the browsing controls. It saves filter, empty-result, wide and compact Wallpapers, Settings and editor screenshots (including light/dark control styling) alongside `smoke-results.json` for visual inspection.

The smoke run imports real PNG, MOV and MP4 fixtures, a video manifest folder, its direct JSON manifest, and ZIP and `.bdpkg` archives through the library importer. Each `fullImport*` result checks persistence, dimensions, media decoding, an independent byte-identical library copy, and preservation of the source media and selected file. These fixtures cover every advertised import category, not every image format or video codec supported by macOS.

Wallpaper-flow checks cover revealing a multi-file import from a filtered playlist, keeping global imports out of that playlist, temporarily revealing added wallpapers with blocked tags, Undo, existing-item playlist additions without duplicates, file additions to a specific playlist, and saving or cancelling a video trim while preserving source bytes. Drop verification supplies file URL item providers to the same handler used by the window; it does not simulate a Finder mouse drag. The suite clicks Set Wallpaper for a built-in wallpaper and an imported video, but the disposable catalog intentionally blocks system-provider activation. Wide and compact window captures require visual inspection after the run.
