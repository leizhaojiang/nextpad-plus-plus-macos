# AGENTS.md

Native macOS port of the Notepad++ codebase: C++17 + Objective-C++ (ARC), programmatic AppKit (no XIBs), CMake, GPL-3.0. Windows Notepad++ semantics are the reference for behavior, config formats, shortcuts and the plugin API — parity is the default argument for any design choice.

## Build & test

```bash
cmake -S . -B build-release -DCMAKE_BUILD_TYPE=Release
cmake --build build-release -j            # bundle: build-release/Nextpad++.app

bash regex/test/run.sh                    # regex backend self-tests (exit non-zero on failure)
bash regex/test/run_boost.sh
```

No CI and no unit-test framework. Those two scripts plus `test_plugins/` (dlopen/dlsym load tester) are the only automated checks.

A full rebuild still emits **deprecation warnings** (`NSFilenamesPboardType`, `-openFile:`, `-openURLs:withAppBundleIdentifier:…`, `CC_MD5`). They are pre-existing and do not fail the build — `CC_MD5` in particular must stay, it backs the user-visible MD5 hash feature. The build is green; do not treat warnings as errors.

Installer (local script — `tools/` is gitignored): `tools/build-release.sh` builds universal Release and produces `downloads/Nextpad++v<version>.dmg` with the Finder layout. `CODESIGN_IDENTITY` / `NOTARY_PROFILE` env vars add Developer ID signing and notarization; without them the DMG keeps the ad-hoc signature and opens on this Mac only. Details: `docs/PROJECT_SCAN.md` §8 (打包与发布).

Source lists in `CMakeLists.txt` are explicit (`APP_SRCS` / `APP_HEADERS`): a new source file needs a CMake edit. Scintilla/Lexilla sources are globbed without `CONFIGURE_DEPENDS`, so re-run cmake after touching those trees.

## Code map

| Path | Contents |
|---|---|
| `src/MainWindowController.mm` (~11k lines) | window shell: splits, panels, sessions, config.xml, search wiring, macros |
| `src/EditorView.mm` (~7k lines) | Scintilla bridge, encodings, backups, macros, autocomplete, git gutter |
| `src/TabManager.mm` + `NppTabBar.mm` | custom tab bar, drag/reorder, split-pane tab moves |
| `src/NppPluginManager.mm` + `NppPluginInterfaceMac.h` | plugin loading, `NPPM_*` dispatch, notification forwarding |
| `src/MenuBuilder.mm` | all menus, `target:nil` responder-chain dispatch |
| `src/SearchEngine.mm` + `FindWindow.mm` + `SearchResultsPanel.mm` | find/replace/find-in-files |
| `src/NppLocalizer.mm` | nativeLang XML → in-place menu translation |
| `src/StyleConfiguratorWindowController.mm` | `NPPStyleStore`: editor colour themes |
| `regex/` | dual regex backend behind `SCI_OWNREGEX` |
| `scintilla/`, `lexilla/` | vendored upstream editing engine + lexers |

Both big controllers have `#pragma mark` section maps — use them instead of reading top to bottom.

## Rules that change how you edit

**Vendored code**
- `lexilla/` is pristine upstream. `lexilla/lexers/LexUser.cxx` is excluded from the build; the UDL lexer is compiled from `src/LexUser.cxx` (macOS header shim). Edit that copy.
- `scintilla/` carries local patches marked `// LOCAL CHANGE` (plus RTL changes in `scintilla/src/EditView.cxx`). Keep the markers accurate — they are the sync contract with upstream.
- `src/LexUserStub.cxx` is dead code; adding it to a build would collide with `lmUserDefine`.

**Adding features**
- New preference: constant in `PreferencesWindowController.h/.mm` → tagged control → `prefChanged:` switch → consumer (`EditorView applyPreferencesFromDefaults` is the main one). Extend `writeConfigXML`/`readConfigXML` in `MainWindowController.mm` too if it must survive in `config.xml` — only a curated subset does today.
- New built-in language: `src/NppBuiltinLanguages.mm` + `resources/langs.model.xml` (+ styler entries). Check the LexHTML keyword-slot override in `EditorView.mm` and the `languageDisplayName` table in `MainWindowController.mm`.
- New plugin API: macOS-only messages start at `NPPMSG + 500`; plugins are always UTF-8 (no `isUnicode`); compatibility shims live in `NppPluginInterfaceMac.h`.
- New menu command: `target:nil` item in `MenuBuilder`; implement the selector on `EditorView` (document-scoped) or `MainWindowController` (window-scoped).
- Shortcut mapping: always go through `NppApplyShortcutToMenuItem` — four callers share it by design.
- Localization: menus are translated in place; match by tag or stashed English title, never by the localized string. macOS↔Windows wording aliases live in `NppLocalizer.mm`.
- New UI language: XML into `resources/localization/` + BCP-47 code in `NPP_BUNDLE_LANGUAGES` (`CMakeLists.txt`).
- Sessions/backups: `session.plist` and `backup/` are app-scoped — save once per quit via `AppDelegate`; allocate backup names through `EditorView uniqueBackupPathInDirectory:`.

**Style**
- Comments explain *why*, often with the GitHub issue number. Match that; a fix should say which issue it closes.
- When a fix depends on a subtle invariant, write the invariant down in the comment (repo convention, e.g. backup uniqueness, session save ordering).

**Performance**
- `SCN_UPDATEUI` runs on every scroll / cursor / content tick: keep per-update work bounded to the visible viewport. `updateSmartHighlight` and `updateClickableLinks` are the models — both bound their scan (NPP parity: `SmartHighlighter.cpp` scans visible lines only, `MAXLINEHIGHLIGHT 400`). A whole-document scan here costs hundreds of ms per scroll frame on a 50 MB log. See `docs/PROJECT_SCAN.md` §5.5 for measurements and the re-measure recipe.

**Menus**
- The menu bar mixes the Windows Notepad++ layout with the macOS-HIG reorganization (`f517dc6`), on explicit user request: `Settings`, `Encoding` and `Tools` are top-level menus again, in the Windows order (编码 between View and Language, 设置 after Language, 工具 after Settings).
- `Encoding` and `Tools` are **moves**: their HIG homes (`Edit > Encoding`, `Plugins > MD5/SHA-1/SHA-256/SHA-512`) are gone — each command has exactly one route.
- `Settings` is the exception: its commands are **intentionally duplicated** (app menu `Settings…`/⌘,`, `View > Appearance`, `Edit > Shortcut Mapper…`) and those HIG copies stay. Do not deduplicate or re-duplicate any of these menus without asking.
- All three translate via nativeLang `menuId "settings"/"encoding"/"tools"` and `subMenuId "settings-import"/"tools-md5"…`. Titles the HIG rename left without an alias stay English (`Help`, `Character sets`).

**Search results panel**
- Double-clicking a result calls `MainWindowController searchResultsPanel:navigateToFile:atLine:matchText:matchCase:` → `EditorView -goToLineNumber:`, which must leave the **caret at column 1** (reversed selection: anchor at the line end, caret at the line start) and reset `xOffset` to 0. The unreversed selection it used to do put the caret at the line end, so `SCI_SCROLLCARET` dragged long log lines to their tail.
- `NPPSearchResult.matchStart/matchLength` are **UTF-8 byte offsets** (NPP's `start_mark = targetStart - lstart`). `SearchEngine` normalises every producer to bytes (`nppByteRangeForCharRange` for `NSRegularExpression`/`-rangeOfString` results); never treat them as character indices.
- Result lines are truncated to `SC_SEARCHRESULT_LINEBUFFERMAXLENGTH - 4` bytes like Windows NPP — the result lexer mis-styles (and re-marks) lines longer than its 2048-byte line buffer. Matches past the cut get no highlight, matching NPP.
- The panel must keep `SCI_SETSCROLLWIDTHTRACKING(1)` + `SCI_SETSCROLLWIDTH(1)`: Scintilla's default 2000px scroll width clamps the bottom scrollbar so long result lines cannot be scrolled to the end (NPP sets the same pair in `ScintillaEditView::init`; our EditorView does too).
- Result colours come from the active style theme via `stylesForLexer:@"searchResult"` (the hardcoded palette is only a fallback). The colour helper must convert NSColor to **deviceRGB** before reading components — that is what `ScintillaView -setColorProperty:parameter:value:` (the editor's path) does; genericRGB yields different integers and makes the panel shades differ from the editor.
- The results panel height persists in `config.xml` as `<GUIConfig name="DockingManager" bottomHeight="…">` (same slot as NPP's docked finder); first use defaults to half the split.
- Find in Files / Projects must keep the `nppSearchableFileContents` fallback chain (UTF-8 → charset detection → lossy UTF-8): a single invalid byte must not hide a whole file from search.

## Traps (verified)

- Pinned tabs can still be closed through the tab-bar × or double-click; only the menu paths check pin state (`NppTabBar.mm`, `MainWindowController.mm`).
- Diagnostics always show "Periodic Backup: OFF" — literal string key instead of the constant at `MainWindowController.mm:10729`.
- With multiple windows, Find routes to the first window that opened it (`_ensureFindWindow` sets the delegate only when nil).
- Version numbers live in `CMakeLists.txt` and `resources/Info.plist` (currently 1.0.8) while release tags are already v1.1.x.
- `docs/` is gitignored (local-only notes), as are `tools/` and `.claude/`.

Deeper reference — architecture internals, full bug/dead-code inventory, hardcoded lists that need manual syncing: **`docs/PROJECT_SCAN.md`**. Read it before refactoring the large controllers, before touching a subsystem you have not worked in yet, or when investigating one of the traps above.
