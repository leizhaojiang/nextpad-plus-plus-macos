# AGENTS.md

Native macOS port of the Notepad++ codebase: C++17 + Objective-C++ (ARC), programmatic AppKit (no XIBs), CMake, GPL-3.0. Windows Notepad++ semantics are the reference for behavior, config formats, shortcuts and the plugin API — parity is the default argument for any design choice.

## Build & test

```bash
cmake -S . -B build-release -DCMAKE_BUILD_TYPE=Release
cmake --build build-release -j            # bundle: build-release/Notepad++.app

bash regex/test/run.sh                    # regex backend self-tests (exit non-zero on failure)
bash regex/test/run_boost.sh
```

No CI and no unit-test framework. Those two scripts plus `test_plugins/` (dlopen/dlsym load tester) are the only automated checks.

A full rebuild still emits **deprecation warnings** (`NSFilenamesPboardType`, `-openFile:`, `-openURLs:withAppBundleIdentifier:…`, `CC_MD5`). They are pre-existing and do not fail the build — `CC_MD5` in particular must stay, it backs the user-visible MD5 hash feature. The build is green; do not treat warnings as errors.

Installer (local script — `tools/` is gitignored): `tools/build-release.sh` builds universal Release and produces `downloads/Notepad++v<version>.dmg` with the Finder layout. `CODESIGN_IDENTITY` / `NOTARY_PROFILE` env vars add Developer ID signing and notarization; without them the DMG keeps the ad-hoc signature and opens on this Mac only. Details: `docs/PROJECT_SCAN.md` §8 (打包与发布).

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
- `lexilla/lexers/LexSearchResult.cxx` is excluded from the build too — the results panel writes flush-left lines (no "Line NNNN:" prefix, no tab/space indent) and passes a per-line kind in `SearchResultMarkings._lineKinds` instead of the upstream first-character convention. The lexer is compiled from `src/LexSearchResult.cxx` (`// LOCAL CHANGE` markers). Edit that copy when the results format changes.
- `scintilla/` carries local patches marked `// LOCAL CHANGE` (plus RTL changes in `scintilla/src/EditView.cxx`). Keep the markers accurate — they are the sync contract with upstream.
- `src/LexUserStub.cxx` is dead code; adding it to a build would collide with `lmUserDefine`.

**Adding features**
- New preference: constant in `PreferencesWindowController.h/.mm` → tagged control → `prefChanged:` switch → consumer (`EditorView applyPreferencesFromDefaults` is the main one). Extend `writeConfigXML`/`readConfigXML` in `MainWindowController.mm` too if it must survive in `config.xml` — only a curated subset does today.
- New built-in language: `src/NppBuiltinLanguages.mm` + `resources/langs.model.xml` (+ styler entries). Check the LexHTML keyword-slot override in `EditorView.mm` and the `languageDisplayName` table in `MainWindowController.mm`.
- New plugin API: macOS-only messages start at `NPPMSG + 500`; plugins are always UTF-8 (no `isUnicode`); compatibility shims live in `NppPluginInterfaceMac.h`.
- New menu command: `target:nil` item in `MenuBuilder`; implement the selector on `EditorView` (document-scoped), `MainWindowController` (window-scoped), or the focused panel (panel-scoped — e.g. `SearchResultsPanel findInSearchResults:`, which auto-disables elsewhere through the responder chain and is therefore assignable in the Shortcut Mapper).
- Shortcut mapping: always go through `NppApplyShortcutToMenuItem` — four callers share it by design.
- Localization: menus are translated in place; match by tag or stashed English title, never by the localized string. macOS↔Windows wording aliases live in `NppLocalizer.mm`.
- Localization of new UI: build labels through `[[NppLocalizer shared] translate:…]` **in shared helpers** where a window has them (e.g. `UserDefineDialog`'s `L`/`groupBox`/`chk`/`stylerBtn`). `translate:` matches by normalized English title, so any wording that also exists in the Windows nativeLang files translates automatically; macOS-only wording finds no entry and falls back to English (no mechanism yet — see `docs/PROJECT_SCAN.md` §5.12 for the inventory).
- New UI language: XML into `resources/localization/` + BCP-47 code in `NPP_BUNDLE_LANGUAGES` (`CMakeLists.txt`).
- Sessions/backups: `session.plist` and `backup/` are app-scoped — save once per quit via `AppDelegate`; allocate backup names through `EditorView uniqueBackupPathInDirectory:`.
- Dropped / OS-provided paths go through `+[AppDelegate expandFolderPaths:recursive:]`: files pass through, folders expand to their files, hidden entries and package directories (.app, .bundle …) are skipped, the result is sorted, and more than 20 files asks for confirmation first (nil = user cancelled, so callers must do nothing). Folder **drops** use `recursive:YES`; the CLI / Finder-service / open-document paths keep `recursive:NO` (the documented bare-folder behaviour, issue #131). `NppDropView.dropHandler` is wired on all three editor panes.

**Style**
- Comments explain *why*, often with the GitHub issue number. Match that; a fix should say which issue it closes.
- When a fix depends on a subtle invariant, write the invariant down in the comment (repo convention, e.g. backup uniqueness, session save ordering).

**Theming / style application**
- "Default Style" (style 32) only paints the canvas. Every language style carries its own `bgColor` in `stylers.xml` (shipped files say `FFFFFF`), so changing only the Default Style background leaves white glyph backgrounds in every syntax-highlighted language — Windows NPP behaves identically. The knob that repaints everything is **Global override → background** (`Force background color for all styles` / 中文 "使用全局背景色"); it persists as `config.xml <GUIConfig name="globalOverride" bg="yes">`, which `readConfigXML` re-imposes over NSUserDefaults at launch, so both stores must agree. Decorative styles follow NPP: indent guide (37) and brace highlight (34) are overridden, the line-number margin (33) deliberately is not.
- Style saving (`StyleConfiguratorWindowController` / `NPPStyleStore`) has three invariants; breaking any of them silently loses or shifts a user's settings: the configurator's working copy must start from **theme + saved overrides** (`applySavedOverridesToLexers:`); `commitLexers:` must diff against the **effective state** (`lexersForTheme:` + the saved overrides) and **merge** the result into the saved dictionary, never rebuild it — a value that happens to equal the shipped default (e.g. the model's "Courier New" font on the Global override row) is still a real change when the user's `stylers.xml` still holds an older value, and comparing against the bundled model silently dropped it (the font reverted after the next launch); and `hexFromColor` must serialise in **sRGB**, the space `NPPColorFromHex` parses (`genericRGB` shifted every colour on every save).
- Every path that pushes per-style attributes must apply the override through `-[NPPStyleStore styleByApplyingGlobalOverride:]` — Windows pushes built-in lexer styles *and* UDL styles through `ScintillaEditView::setStyle()`. Current callers: `EditorView applyLexerColors:` and `UserDefineLangManager applyLanguage:toScintillaView:` (markdown ships as a UDL, so it needs the same treatment). The helper returns the same object when no force-flag is on; an unset override attribute comes back cleared, meaning "skip the `SCI_STYLESET*` call and keep `STYLE_DEFAULT`". See `docs/PROJECT_SCAN.md` §5.14.

**Performance**
- `SCN_UPDATEUI` runs on every scroll / cursor / content tick: keep per-update work bounded to the visible viewport. `updateSmartHighlight` and `updateClickableLinks` are the models — both bound their scan (NPP parity: `SmartHighlighter.cpp` scans visible lines only, `MAXLINEHIGHLIGHT 400`). A whole-document scan here costs hundreds of ms per scroll frame on a 50 MB log. See `docs/PROJECT_SCAN.md` §5.5 for measurements and the re-measure recipe.
- `updateClickableLinks` is additionally **debounced** (80 ms, `_scheduleClickableLinksUpdate`) because its `NSDataDetector` + regex scan is ~55% of a scroll frame's paint time and a trackpad fires 60-120 updates/s — do not move it back to the synchronous per-update path.
- Measured with an injected-dylib scroll burst + `sample`: before the debounce, `updateClickableLinks` accounted for 38 of the samples inside `SCIContentView drawRect:`; after, 4. Re-measure with the ready-made burst/sample recipe in `docs/PROJECT_SCAN.md` §5.10.

**Menus**
- The menu bar mixes the Windows Notepad++ layout with the macOS-HIG reorganization (`f517dc6`), on explicit user request: `Settings`, `Encoding` and `Tools` are top-level menus again, in the Windows order (编码 between View and Language, 设置 after Language, 工具 after Settings).
- `Encoding` and `Tools` are **moves**: their HIG homes (`Edit > Encoding`, `Plugins > MD5/SHA-1/SHA-256/SHA-512`) are gone — each command has exactly one route.
- `Settings` is the exception: its commands are **intentionally duplicated** (app menu `Settings…`/⌘,`, `View > Appearance`, `Edit > Shortcut Mapper…`) and those HIG copies stay. Do not deduplicate or re-duplicate any of these menus without asking.
- All three translate via nativeLang `menuId "settings"/"encoding"/"tools"` and `subMenuId "settings-import"/"tools-md5"…`. Titles the HIG rename left without an alias stay English (`Help`, `Character sets`).

**Search results panel**
- Double-clicking a result calls `MainWindowController searchResultsPanel:navigateToFile:atLine:matchText:matchCase:` → `EditorView -goToLineNumber:`, which must leave the **caret at column 1** (reversed selection: anchor at the line end, caret at the line start) and reset `xOffset` to 0. The unreversed selection it used to do put the caret at the line end, so `SCI_SCROLLCARET` dragged long log lines to their tail.
- `NPPSearchResult.matchStart/matchLength` are **UTF-8 byte offsets** (NPP's `start_mark = targetStart - lstart`). `SearchEngine` normalises every producer to bytes (`nppByteRangeForCharRange` for `NSRegularExpression`/`-rangeOfString` results); never treat them as character indices.
- Result lines are truncated to `SC_SEARCHRESULT_LINEBUFFERMAXLENGTH - 4` bytes like Windows NPP — the result lexer mis-styles (and re-marks) lines longer than its 2048-byte line buffer. Matches past the cut get no highlight, matching NPP.
- The truncation is **display-only**: `addResults:` keeps the cut tail in `_SRLineInfo.tailUTF8`, and the copy paths (`_copy:`, `_copyLines:`, through `_lineText:requireVisible:` → `_fullLineTextForLine:displayText:`) splice it back, so ⌘C / select-all / Copy Line(s) paste the **full** line. Whole-line selections are rebuilt line by line (a partial selection still copies exactly the selected characters). `_copyLines:` picks rows by `_lineKinds` and keeps result lines only — its old `\t` prefix test silently matched nothing once the prefix was dropped.
- Result lines are written **flush left**: the source line's text alone — no NPP "Line NNNN:" prefix and no tab/space indent (owner request; text starts right after the 16px fold margin, which stays so the +/- fold markers remain clickable). The line number is not displayed but still drives navigation via `_lineInfos`, so double-click still jumps to it. Marking offsets are `matchStart` in UTF-8 bytes. Because there is no first-character convention any more, the panel passes a `SearchResultLineKind` per line through `SearchResultMarkings._lineKinds` (LOCAL CHANGE in `scintilla/include/Scintilla.h`) and the lexer copy (`src/LexSearchResult.cxx`) classifies by it — keep the two in sync (result / file header / search header).
- The panel must keep `SCI_SETSCROLLWIDTHTRACKING(1)` + `SCI_SETSCROLLWIDTH(1)`: Scintilla's default 2000px scroll width clamps the bottom scrollbar so long result lines cannot be scrolled to the end (NPP sets the same pair in `ScintillaEditView::init`; our EditorView does too).
- Result colours come from the active style theme via `stylesForLexer:@"searchResult"` (the hardcoded palette is only a fallback). The colour helper must convert NSColor to **deviceRGB** before reading components — that is what `ScintillaView -setColorProperty:parameter:value:` (the editor's path) does; genericRGB yields different integers and makes the panel shades differ from the editor.
- The panel's **base background follows the Global override** like the editor does: `_applyTheme` substitutes the override row's fg/bg/font/size into its `STYLE_DEFAULT` colours and pins `SCE_SEARCHRESULT_DEFAULT` so a theme entry cannot undo it. Windows does the same for the finder view — it re-pins the Default Style values after pushing the lexer styles (`FindReplaceDlg.cpp:6095-6114`). Without this the panel followed the *un-overridden* Default Style while the editor followed the override, so changing the background only moved one of them. Header / hit-word / current-line styles deliberately keep their theme colours (the highlight boxes stay).
- The **filter bar** ("Find in these search results…", `_applyFilter`) must classify lines by `_lineKinds` too — it used to test the first character (`\t` = result line, space = file header, anything else = search header), which broke the moment result lines lost their prefixes: every result line looked like a search header (always visible) and the filter silently did nothing.
- **⌘F is context-sensitive**: while the results panel has focus the panel's local key monitor consumes ⌘F and opens the filter bar; elsewhere the event reaches the Search menu's `Find…` (the global Find dialog) unchanged. ⇧⌘F keeps reaching Find in Files — `charactersIgnoringModifiers` preserves the shifted form, so only the unshifted "f" is intercepted. The Search menu also exposes `Find in these search results...` (panel-scoped, auto-disabled elsewhere, no default key equivalent) so a user can assign a different shortcut in Settings → Shortcut Mapper.
- The panel's **base font** must be the theme's Default Style font (`store.globalFontName`/`globalFontSize`) applied to `STYLE_DEFAULT` before `STYLECLEARALL`, like the editor does: CJK renders through the fallback chain of the active font, so a different base font makes the panel's Chinese come out visibly lighter. The hit word stays **bold** (re-asserted after the theme-colour pass; the model's "Hit Word" entry is `fontStyle="0"` and would otherwise clear it).
- A new search **folds every previous search block** before appending its own (`addResults:` collapses each line whose `_lineKinds` entry is `SearchResultLineKindSearchHeader`; the nested fold levels then hide the file headers and hits). Skipped when "Purge for every search" is on — those lines are already gone. The new block is expanded by the trailing "Expand all folds in new results" loop.
- The results panel height persists in `config.xml` as `<GUIConfig name="DockingManager" bottomHeight="…">` (same slot as NPP's docked finder); first use defaults to half the split.
- Find in Files / Projects must keep the `nppSearchableFileContents` fallback chain (UTF-8 → charset detection → lossy UTF-8): a single invalid byte must not hide a whole file from search.

## Traps (verified)

- Pinned tabs can still be closed through the tab-bar × or double-click; only the menu paths check pin state (`NppTabBar.mm`, `MainWindowController.mm`).
- Diagnostics always show "Periodic Backup: OFF" — literal string key instead of the constant at `MainWindowController.mm:10729`.
- With multiple windows, Find routes to the first window that opened it (`_ensureFindWindow` sets the delegate only when nil).
- Version numbers live in `CMakeLists.txt` and `resources/Info.plist` (currently 1.0.8) while release tags are already v1.1.x.
- `docs/` is gitignored (local-only notes), as are `tools/` and `.claude/`.

Deeper reference — architecture internals, full bug/dead-code inventory, hardcoded lists that need manual syncing: **`docs/PROJECT_SCAN.md`**. Read it before refactoring the large controllers, before touching a subsystem you have not worked in yet, or when investigating one of the traps above.
