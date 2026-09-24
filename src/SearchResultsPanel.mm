#import "SearchResultsPanel.h"
#import "NppThemeManager.h"
#import "StyleConfiguratorWindowController.h"
#import "PreferencesWindowController.h"
#import "NppLocalizer.h"
#import "ScintillaView.h"
#import "Scintilla.h"
#import "SciLexer.h"
#include <vector>

// Forward-declare Lexilla's CreateLexer (statically linked)
#include "ILexer.h"
extern "C" Scintilla::ILexer5 *CreateLexer(const char *name);

// Fold levels matching LexSearchResult.cxx
enum { searchHeaderLevel = SC_FOLDLEVELBASE, fileHeaderLevel, resultLevel };

// ── Internal data for tracking results ───────────────────────────────────────

struct _SRLineInfo {
    std::string filePath;
    int lineNumber;       // 1-based, 0 = header line
};

// ── SearchResultsPanel ───────────────────────────────────────────────────────

@implementation SearchResultsPanel {
    ScintillaView *_sci;
    NSScrollView  *_scrollContainer;
    NSView        *_titleBar;

    // Parallel data — one entry per line in the ScintillaView
    std::vector<_SRLineInfo> _lineInfos;

    // SearchResultMarkings for the lexer
    std::vector<SearchResultMarkingLine> _markingLines;
    // One SearchResultLineKind per line. The lexer classifies by kind because
    // the panel writes flush-left lines (no "\t" / space prefixes) — see
    // src/LexSearchResult.cxx.
    std::vector<int> _lineKinds;
    SearchResultMarkings _markingsStruct;

    // Toggle states
    BOOL _wordWrapEnabled;
    BOOL _purgeBeforeSearch;

    // Filter bar (incremental search within results)
    NSView              *_filterBar;
    NSTextField         *_filterField;
    NSButton            *_filterMatchCase;
    NSButton            *_filterWholeWord;
    NSTextField         *_filterStatusLabel;
    NSLayoutConstraint  *_filterBarHeight;

    NSBox               *_filterSep;

    // Key event monitor for Cmd+C interception
    id _keyMonitor;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self _buildUI];
        [self _applyTheme];
        // Tahoe: rounded-card corners to match the editor / side panels. Gated —
        // Classic stays square.
        if ([NppThemeManager shared].usesGlassMaterials) {
            self.wantsLayer = YES;
            self.layer.cornerRadius  = 8.0;
            self.layer.masksToBounds = YES;
        }
        _markingsStruct._length    = 0;
        _markingsStruct._markings  = nullptr;
        _markingsStruct._lineKinds = nullptr;
        _wordWrapEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"SearchResultsWordWrap"];
        _purgeBeforeSearch = [[NSUserDefaults standardUserDefaults] boolForKey:@"SearchResultsPurge"];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_themeChanged:)
                                                     name:@"NPPPreferencesChanged" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_darkModeChanged:)
                                                     name:NPPDarkModeChangedNotification object:nil];

        // Intercept Cmd+C / Cmd+F while our ScintillaView has focus. Cmd+C
        // routes to the visibility-aware copy; Cmd+F opens the in-results
        // filter ("Find in these search results…") — the owner asked for that
        // context-sensitive reuse, so the editor keeps the global Find dialog.
        // ⇧⌘F still reaches Find in Files: charactersIgnoringModifiers keeps
        // the shifted form ("F"), which matches neither branch below.
        __weak typeof(self) wSelf = self;
        _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            typeof(self) sSelf = wSelf;
            if (!sSelf) return event;
            if (!(event.modifierFlags & NSEventModifierFlagCommand)) return event;

            // Is our ScintillaView (or its content view) the first responder?
            NSResponder *fr = event.window.firstResponder;
            NSView *v = [fr isKindOfClass:[NSView class]] ? (NSView *)fr : nil;
            BOOL inPanel = NO;
            while (v) {
                if (v == sSelf->_sci) { inPanel = YES; break; }
                v = v.superview;
            }
            if (!inPanel) return event;

            NSString *ch = event.charactersIgnoringModifiers;
            if ([ch isEqualToString:@"c"]) {
                [sSelf _copy:nil];
                return nil; // consume the event
            }
            if ([ch isEqualToString:@"f"]) {
                [sSelf _findInResults:nil];
                return nil; // consume the event
            }
            return event;
        }];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }

- (void)dealloc {
    if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Construction

- (void)_buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _sci = [[ScintillaView alloc] initWithFrame:NSZeroRect];
    _sci.translatesAutoresizingMaskIntoConstraints = NO;

    // Install LexSearchResult lexer
    Scintilla::ILexer5 *lexer = CreateLexer("searchResult");
    if (lexer) {
        [_sci message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];
    }

    // Read-only
    [_sci message:SCI_SETREADONLY wParam:1];

    // Folding setup
    [_sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
    [_sci message:SCI_SETMARGINTYPEN  wParam:2 lParam:SC_MARGIN_SYMBOL];
    [_sci message:SCI_SETMARGINMASKN  wParam:2 lParam:SC_MASK_FOLDERS];
    // Margin 2 is the fold margin: keep it wide enough for the clickable +/-
    // markers (owner request: the text itself must start right here — the old
    // "\t" indent pushed result lines to 88px, the fold margin alone is 16px).
    [_sci message:SCI_SETMARGINWIDTHN wParam:2 lParam:16];
    [_sci message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
    [_sci message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];

    // Fold markers: box style
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN    lParam:SC_MARK_BOXMINUS];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER        lParam:SC_MARK_BOXPLUS];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB     lParam:SC_MARK_VLINE];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL    lParam:SC_MARK_LCORNER];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND     lParam:SC_MARK_BOXPLUSCONNECTED];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:SC_MARK_BOXMINUSCONNECTED];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:SC_MARK_TCORNER];

    // Fold marker colors
    for (int i = SC_MARKNUM_FOLDEREND; i <= SC_MARKNUM_FOLDEROPEN; i++) {
        [_sci message:SCI_MARKERSETFORE wParam:i lParam:0xFFFFFF];
        [_sci message:SCI_MARKERSETBACK wParam:i lParam:0x808080];
    }

    // Hide line number margin, show only fold margin
    [_sci message:SCI_SETMARGINWIDTHN wParam:0 lParam:0];
    [_sci message:SCI_SETMARGINWIDTHN wParam:1 lParam:0];

    // Horizontal scrolling must follow the longest result line. Scintilla's
    // default scroll width is a fixed 2000px, which silently clamps long log
    // lines — the bottom scrollbar stops dragging partway through the line.
    // Windows NPP sets exactly this pair at view init
    // (ScintillaEditView.cpp: SCI_SETSCROLLWIDTHTRACKING(true); SCI_SETSCROLLWIDTH(1)),
    // and our EditorView does the same (EditorView.mm applyDefaultTheme).
    [_sci message:SCI_SETSCROLLWIDTHTRACKING wParam:1];
    [_sci message:SCI_SETSCROLLWIDTH wParam:1];

    // No caret line highlight by default
    [_sci message:SCI_SETCARETLINEVISIBLE wParam:1];

    // EOL-filled styles for headers
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:1];
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:1];

    // Set self as ScintillaView delegate to receive notifications
    _sci.delegate = (id)self;

    // Replace default Scintilla context menu with our custom one
    _sci.menu = [self _buildContextMenu];

    // Apply persisted word wrap setting
    if (_wordWrapEnabled)
        [_sci message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];

    // Apply persisted zoom level
    NSInteger savedZoom = [[NSUserDefaults standardUserDefaults] integerForKey:@"PanelZoom_SearchResults"];
    if (savedZoom != 0)
        [_sci message:SCI_SETZOOM wParam:(uptr_t)savedZoom];

    // ── Title bar with close button ─────────────────────────────────────
    _titleBar = [[NSView alloc] init];
    _titleBar.translatesAutoresizingMaskIntoConstraints = NO;
    _titleBar.wantsLayer = YES;
    _titleBar.layer.backgroundColor = [NppThemeManager shared].panelBackground.CGColor;
    NSView *titleBar = _titleBar;

    NSTextField *titleLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Search results"]];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [NSFont systemFontOfSize:11];
    [titleBar addSubview:titleLabel];

    NSButton *closeBtn = [[NSButton alloc] init];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    closeBtn.bezelStyle = NSBezelStyleSmallSquare;
    closeBtn.bordered = NO;
    closeBtn.title = @"\u2715";
    closeBtn.font = [NSFont systemFontOfSize:10];
    closeBtn.toolTip = [[NppLocalizer shared] translate:@"Close Search Results"];
    closeBtn.target = self;
    closeBtn.action = @selector(_closePanel:);
    [closeBtn.widthAnchor constraintEqualToConstant:18].active = YES;
    [closeBtn.heightAnchor constraintEqualToConstant:18].active = YES;
    [titleBar addSubview:closeBtn];

    [NSLayoutConstraint activateConstraints:@[
        [titleBar.heightAnchor constraintEqualToConstant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:titleBar.leadingAnchor constant:6],
        [titleLabel.centerYAnchor constraintEqualToAnchor:titleBar.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:titleBar.trailingAnchor constant:-4],
        [closeBtn.centerYAnchor constraintEqualToAnchor:titleBar.centerYAnchor],
    ]];

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Filter bar (incremental search within results) ─────────────────
    _filterBar = [[NSView alloc] init];
    _filterBar.translatesAutoresizingMaskIntoConstraints = NO;
    _filterBar.wantsLayer = YES;
    _filterBar.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

    NppLocalizer *loc = [NppLocalizer shared];

    NSTextField *filterLabel = [NSTextField labelWithString:[loc translate:@"Find:"]];
    filterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    filterLabel.font = [NSFont systemFontOfSize:11];
    [_filterBar addSubview:filterLabel];

    _filterField = [[NSTextField alloc] init];
    _filterField.translatesAutoresizingMaskIntoConstraints = NO;
    _filterField.font = [NSFont systemFontOfSize:11];
    _filterField.placeholderString = [loc translate:@"Type to search\u2026"];
    _filterField.delegate = (id)self;
    // Let the field absorb every spare point of the bar (owner request: at its
    // 150pt minimum it stayed tiny inside a wide panel). Everything else in the
    // row keeps the default hugging, so the field is the one that grows.
    [_filterField setContentHuggingPriority:1
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_filterBar addSubview:_filterField];

    _filterMatchCase = [NSButton checkboxWithTitle:[loc translate:@"Match case"] target:nil action:nil];
    _filterMatchCase.translatesAutoresizingMaskIntoConstraints = NO;
    _filterMatchCase.font = [NSFont systemFontOfSize:11];
    _filterMatchCase.target = self;
    _filterMatchCase.action = @selector(_filterChanged:);
    [_filterBar addSubview:_filterMatchCase];

    _filterWholeWord = [NSButton checkboxWithTitle:[loc translate:@"Whole word"] target:nil action:nil];
    _filterWholeWord.translatesAutoresizingMaskIntoConstraints = NO;
    _filterWholeWord.font = [NSFont systemFontOfSize:11];
    _filterWholeWord.target = self;
    _filterWholeWord.action = @selector(_filterChanged:);
    [_filterBar addSubview:_filterWholeWord];

    _filterStatusLabel = [NSTextField labelWithString:@""];
    _filterStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _filterStatusLabel.font = [NSFont systemFontOfSize:11];
    _filterStatusLabel.textColor = [NSColor secondaryLabelColor];
    [_filterBar addSubview:_filterStatusLabel];

    NSButton *filterClose = [[NSButton alloc] init];
    filterClose.translatesAutoresizingMaskIntoConstraints = NO;
    filterClose.bezelStyle = NSBezelStyleSmallSquare;
    filterClose.bordered = NO;
    filterClose.title = @"\u2715";
    filterClose.font = [NSFont systemFontOfSize:10];
    filterClose.target = self;
    filterClose.action = @selector(_closeFilterBar:);
    [filterClose.widthAnchor constraintEqualToConstant:18].active = YES;
    [filterClose.heightAnchor constraintEqualToConstant:18].active = YES;
    [_filterBar addSubview:filterClose];

    // Close the row: tie its tail to the close button so the label … close
    // chain spans the whole bar. The input field (content hugging 1) is then
    // the only view that can stretch and takes all the free space — without
    // this pin Auto Layout just left the gap empty and the field stayed at its
    // 150pt minimum (owner request: make the field longer).
    NSLayoutConstraint *filterStatusPin =
        [_filterStatusLabel.trailingAnchor constraintEqualToAnchor:filterClose.leadingAnchor constant:-8];
    filterStatusPin.priority = NSLayoutPriorityDefaultHigh; // yields to the field's 150pt minimum on narrow panels

    [NSLayoutConstraint activateConstraints:@[
        filterStatusPin,
        [filterLabel.leadingAnchor constraintEqualToAnchor:_filterBar.leadingAnchor constant:6],
        [filterLabel.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterField.leadingAnchor constraintEqualToAnchor:filterLabel.trailingAnchor constant:4],
        [_filterField.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterField.widthAnchor constraintGreaterThanOrEqualToConstant:150],
        [_filterMatchCase.leadingAnchor constraintEqualToAnchor:_filterField.trailingAnchor constant:8],
        [_filterMatchCase.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterWholeWord.leadingAnchor constraintEqualToAnchor:_filterMatchCase.trailingAnchor constant:8],
        [_filterWholeWord.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterStatusLabel.leadingAnchor constraintEqualToAnchor:_filterWholeWord.trailingAnchor constant:8],
        [_filterStatusLabel.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterStatusLabel.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [filterClose.trailingAnchor constraintEqualToAnchor:_filterBar.trailingAnchor constant:-4],
        [filterClose.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
    ]];

    NSBox *sep2 = [[NSBox alloc] init];
    sep2.boxType = NSBoxSeparator;
    sep2.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Layout ───────────────────────────────────────────────────────────
    [self addSubview:titleBar];
    [self addSubview:sep];
    [self addSubview:_sci];
    [self addSubview:sep2];
    [self addSubview:_filterBar];

    _filterBarHeight = [_filterBar.heightAnchor constraintEqualToConstant:0];
    _filterBar.hidden = YES;
    sep2.hidden = YES;
    _filterSep = sep2;

    [NSLayoutConstraint activateConstraints:@[
        [titleBar.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [titleBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [titleBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [sep.topAnchor           constraintEqualToAnchor:titleBar.bottomAnchor],
        [sep.leadingAnchor       constraintEqualToAnchor:self.leadingAnchor],
        [sep.trailingAnchor      constraintEqualToAnchor:self.trailingAnchor],
        [sep.heightAnchor        constraintEqualToConstant:1],
        [_sci.topAnchor          constraintEqualToAnchor:sep.bottomAnchor],
        [_sci.leadingAnchor      constraintEqualToAnchor:self.leadingAnchor],
        [_sci.trailingAnchor     constraintEqualToAnchor:self.trailingAnchor],
        [_sci.bottomAnchor       constraintEqualToAnchor:sep2.topAnchor],
        [sep2.leadingAnchor      constraintEqualToAnchor:self.leadingAnchor],
        [sep2.trailingAnchor     constraintEqualToAnchor:self.trailingAnchor],
        [sep2.heightAnchor       constraintEqualToConstant:1],
        [_filterBar.topAnchor    constraintEqualToAnchor:sep2.bottomAnchor],
        [_filterBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_filterBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_filterBar.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        _filterBarHeight,
    ]];
}

#pragma mark - Theme

/// Convert NSColor to Scintilla BGR integer.
static sptr_t _srSciColor(NSColor *c) {
    // Must match ScintillaView's -setColorProperty:parameter:value: (used by
    // EditorView for the same theme colours): that converts to DEVICE RGB
    // before reading components. Converting to genericRGB instead (as this
    // helper used to) yields different integers for the same theme colour, so
    // the results panel rendered a different shade than the editor.
    c = [c colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!c) return 0;
    long r = (long)([c redComponent]   * 255);
    long g = (long)([c greenComponent] * 255);
    long b = (long)([c blueComponent]  * 255);
    return (b << 16) | (g << 8) | r;
}

- (void)_applyTheme {
    BOOL dark = [NppThemeManager shared].isDark;
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSAppearance *panelAppearance = [NSAppearance appearanceNamed:
        dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    // Background & foreground from the editor theme, with the same "Global
    // override" substitution the editor applies (issue #149). Windows pins the
    // finder view's defaults to the Default Style values *after* running them
    // through the override (FindReplaceDlg.cpp:6095-6114), so an enabled
    // override colours the results panel exactly like the editor instead of
    // letting the panel drift to the un-overridden Default Style.
    NPPStyleEntry *gov = [store globalStyleNamed:@"Global override"];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL ovFg       = gov && [ud boolForKey:kPrefGlobalOverrideEnableFg];
    BOOL ovBg       = gov && [ud boolForKey:kPrefGlobalOverrideEnableBg];
    BOOL ovFont     = gov && [ud boolForKey:kPrefGlobalOverrideEnableFont]     && gov.fontName.length > 0;
    BOOL ovFontSize = gov && [ud boolForKey:kPrefGlobalOverrideEnableFontSize] && gov.fontSize > 0;

    NSColor *bgColor = [store globalBg];
    NSColor *fgColor = [store globalFg];
    NSString *fontName = store.globalFontName.length ? store.globalFontName : @"Menlo";
    int fontSize = store.globalFontSize > 0 ? store.globalFontSize : 12;
    if (ovFg && gov.fgColor)   fgColor  = gov.fgColor;
    if (ovBg && gov.bgColor)   bgColor  = gov.bgColor;
    if (ovFont)                fontName = gov.fontName;
    if (ovFontSize)            fontSize = gov.fontSize;

    sptr_t bg = _srSciColor(bgColor);
    sptr_t fg = _srSciColor(fgColor);
    CGFloat bgBrightness = bgColor.brightnessComponent;

    // The theme's Default Style font (what the editor's document uses) beats
    // Scintilla's built-in default: CJK text has no glyphs in the primary font,
    // so it renders through the fallback chain of whatever font is active —
    // with a different base font the panel's Chinese came out visibly lighter
    // than the editor's. STYLECLEARALL then makes every style inherit it.
    [_sci message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)fontName.UTF8String];
    [_sci message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:fontSize];
    [_sci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:bg];
    [_sci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:fg];
    [_sci message:SCI_STYLECLEARALL];

    // Search header: purple-ish bg #bebefc, dark blue fg #01057e
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:(dark ? 0xFCBEBE : 0x7E0501)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:(dark ? 0x3A3A50 : 0xFCBEBE)];
    [_sci message:SCI_STYLESETBOLD  wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:1];

    // File header: green bg #d0f0d0, green fg #007000
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:(dark ? 0x80FF80 : 0x007000)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:(dark ? 0x2E4A2E : 0xD0F0D0)];
    [_sci message:SCI_STYLESETBOLD  wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:1];

    // Line number: green
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_LINE_NUMBER lParam:(dark ? 0x808080 : 0x008000)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_LINE_NUMBER lParam:bg];

    // Matched text: red fg #ff0b05, yellow bg #ffffbf
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:(dark ? 0x00AAFF : 0x050BFF)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:(dark ? 0x404000 : 0xBFFFFF)];
    [_sci message:SCI_STYLESETBOLD  wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:1];

    // Default text
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_DEFAULT lParam:fg];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_DEFAULT lParam:bg];

    // Current line highlight
    sptr_t caretBg = dark ? 0x404040 : 0xE8E8E8;
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_CURRENT_LINE lParam:caretBg];
    [_sci message:SCI_SETCARETLINEBACK wParam:caretBg];

    // ── Result styles from the active style theme ────────────────────────
    // The palette above is only a fallback. The searchResult lexer is defined
    // in stylers.xml / every theme like any other language, so whatever the
    // user configures in the Style Configurator (or a non-default theme) must
    // win — that is what the editor shows. Applied after the defaults, so a
    // theme that omits an entry keeps the fallback value.
    for (NPPStyleEntry *e in [store stylesForLexer:@"searchResult"]) {
        int sid = e.styleID;
        if (sid < 0 || sid > SCE_SEARCHRESULT_CURRENT_LINE || sid == 5) continue; // 5 = unused (HIGHLIGHT_LINE)
        // An enabled override pins SCE_SEARCHRESULT_DEFAULT — a theme entry for
        // it must not undo that (Windows re-pins the style after applying the
        // lexer styles, FindReplaceDlg.cpp:6110).
        BOOL pinned = (sid == SCE_SEARCHRESULT_DEFAULT);
        if (e.fgColor && !(pinned && ovFg)) [_sci message:SCI_STYLESETFORE wParam:(uptr_t)sid lParam:_srSciColor(e.fgColor)];
        if (e.bgColor && !(pinned && ovBg)) {
            sptr_t bgVal = _srSciColor(e.bgColor);
            [_sci message:SCI_STYLESETBACK wParam:(uptr_t)sid lParam:bgVal];
            if (sid == SCE_SEARCHRESULT_CURRENT_LINE)
                [_sci message:SCI_SETCARETLINEBACK wParam:bgVal];
        }
        [_sci message:SCI_STYLESETBOLD   wParam:(uptr_t)sid lParam:e.bold   ? 1 : 0];
        [_sci message:SCI_STYLESETITALIC wParam:(uptr_t)sid lParam:e.italic ? 1 : 0];
    }

    // The hit word stays bold: the panel's own palette has always emphasised the
    // matched text, and the theme's model leaves "Hit Word" at fontStyle 0,
    // which would clear it. Colours still come from the theme.
    [_sci message:SCI_STYLESETBOLD wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:1];

    // EOL-filled for headers
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:1];
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:1];

    // ── Fold markers: match editor theme ─────────────────────────────────
    // Fold margin background
    NPPStyleEntry *gsFoldMargin = [store globalStyleNamed:@"Fold margin"];
    sptr_t foldMarginBGR;
    if (gsFoldMargin && gsFoldMargin.bgColor) {
        foldMarginBGR = _srSciColor(gsFoldMargin.bgColor);
    } else {
        foldMarginBGR = dark ? 0x2D2D2D : 0xF2F2F2;
    }
    [_sci message:SCI_SETFOLDMARGINCOLOUR   wParam:1 lParam:foldMarginBGR];
    [_sci message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:foldMarginBGR];

    // Fold marker fore/back colors from "Fold" global style
    NPPStyleEntry *gsFold = [store globalStyleNamed:@"Fold"];
    NSColor *foldFore = gsFold.fgColor ?: (bgBrightness > 0.5 ? [NSColor blackColor]
                                                                : [NSColor colorWithWhite:0.80 alpha:1.0]);
    NSColor *foldBack = gsFold.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.82 alpha:1.0]
                                                                : [NSColor colorWithWhite:bgBrightness + 0.22 alpha:1.0]);
    for (int mn = SC_MARKNUM_FOLDEREND; mn <= SC_MARKNUM_FOLDEROPEN; mn++) {
        [_sci message:SCI_MARKERSETFORE wParam:mn lParam:_srSciColor(foldFore)];
        [_sci message:SCI_MARKERSETBACK wParam:mn lParam:_srSciColor(foldBack)];
    }

    // ── Title bar and filter bar background ─────────────────────────────
    // Use a concrete color here, not a dynamic NSColor bridged to CGColor:
    // layer colors are resolved at assignment time and can otherwise pick up
    // the system appearance instead of Nextpad++'s forced light/dark mode.
    NSColor *panelBg = [NppThemeManager shared].statusBarBackground;
    _titleBar.layer.backgroundColor = panelBg.CGColor;
    _filterBar.layer.backgroundColor = panelBg.CGColor;
    self.appearance = panelAppearance;
    _titleBar.appearance = panelAppearance;
    _filterBar.appearance = panelAppearance;
    _filterField.appearance = panelAppearance;

    // ── Appearance for dark/light disclosure triangles ────────────────────
    _sci.appearance = panelAppearance;

    // Re-colourise if we have content
    if ([_sci message:SCI_GETLENGTH] > 0)
        [_sci message:SCI_COLOURISE wParam:0 lParam:-1];
}

- (void)_themeChanged:(NSNotification *)n {
    [self _applyTheme];
}

- (void)_darkModeChanged:(NSNotification *)n {
    [self _applyTheme];
}

#pragma mark - Scintilla notifications

// ScintillaNotificationProtocol
- (void)notification:(SCNotification *)scn {
    if (scn->nmhdr.code == SCN_DOUBLECLICK) {
        sptr_t line = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)scn->position];
        [self _navigateToResultLine:line];
    }
}

- (void)_navigateToResultLine:(sptr_t)lineIdx {
    if (lineIdx < 0 || (size_t)lineIdx >= _lineInfos.size()) return;

    const _SRLineInfo &info = _lineInfos[lineIdx];
    if (info.lineNumber <= 0) return; // header line — don't navigate

    NSString *path = [NSString stringWithUTF8String:info.filePath.c_str()];
    [_delegate searchResultsPanel:self navigateToFile:path atLine:info.lineNumber
                        matchText:@"" matchCase:NO];
}

- (void)_closePanel:(id)sender {
    [_delegate searchResultsPanel:self navigateToFile:@"" atLine:0 matchText:@"" matchCase:NO];
    // Notify delegate to collapse the panel — we use a special "close" signal
    if ([_delegate respondsToSelector:@selector(searchResultsPanelDidRequestClose:)])
        [(id)_delegate searchResultsPanelDidRequestClose:self];
}

#pragma mark - Public API

- (void)addResults:(NSArray<NPPFileResults *> *)fileResults
     forSearchText:(NSString *)searchText
           options:(NPPFindOptions *)opts
      filesSearched:(NSInteger)filesSearched {
    if (!fileResults.count) return;

    // Purge previous results if enabled
    if (_purgeBeforeSearch) [self clearAll];

    [_sci message:SCI_SETREADONLY wParam:0];

    // Count total hits
    NSInteger totalHits = 0;
    for (NPPFileResults *fr in fileResults)
        totalHits += (NSInteger)fr.results.count;

    // Search mode label
    NSString *modeLabel = @"Normal";
    if (opts.searchType == NPPSearchExtended) modeLabel = @"Extended";
    else if (opts.searchType == NPPSearchRegex) modeLabel = @"Regex";

    NSMutableString *optLabel = [NSMutableString string];
    if (opts.matchCase) [optLabel appendString:@"Case"];
    if (opts.wholeWord) {
        if (optLabel.length) [optLabel appendString:@"/"];
        [optLabel appendString:@"Word"];
    }

    NSString *suffix = @"";
    if (optLabel.length) suffix = [NSString stringWithFormat:@" [%@: %@]", modeLabel, optLabel];
    else suffix = [NSString stringWithFormat:@" [%@]", modeLabel];

    // Timestamp (date + time to the second) appended at the end of the
    // search-header line. The lexer classifies a line solely by its first
    // character, so trailing content is safe.
    static NSDateFormatter *tsFormatter;
    static dispatch_once_t tsOnce;
    dispatch_once(&tsOnce, ^{
        tsFormatter = [[NSDateFormatter alloc] init];
        // Fixed locale so the 12-hour clock and the AM/PM marker are
        // deterministic regardless of the user's region settings.
        tsFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        tsFormatter.dateFormat = @"yyyy-MM-dd hh:mm:ss a";
    });
    // Lowercase so the marker reads "am" / "pm".
    NSString *timestamp = [[tsFormatter stringFromDate:[NSDate date]] lowercaseString];

    // Search header
    NSString *header = [NSString stringWithFormat:@"Search \"%@\" (%ld hit%@ in %ld file%@ of %ld searched)%@  %@\n",
        searchText,
        (long)totalHits, totalHits == 1 ? @"" : @"s",
        (long)fileResults.count, fileResults.count == 1 ? @"" : @"s",
        (long)filesSearched,
        suffix,
        timestamp];

    sptr_t startPos = [_sci message:SCI_GETLENGTH];
    // SCI_APPENDTEXT wParam is the UTF-8 BYTE count, not the NSString character
    // count. For non-ASCII content these differ (Punjabi/Cyrillic/CJK etc.), and
    // passing .length truncates the buffer mid-byte — Scintilla drops the
    // trailing newline, the next APPENDTEXT concatenates inline, and the
    // results view looks "scrambled" (issue #46). lengthOfBytesUsingEncoding:
    // returns the exact UTF-8 byte count and is correct for any string.
    [_sci message:SCI_APPENDTEXT
                 wParam:[header lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                 lParam:(sptr_t)header.UTF8String];

    // Add line info for search header
    _SRLineInfo headerInfo = {};
    headerInfo.lineNumber = 0;
    _lineInfos.push_back(headerInfo);

    // Empty marking for header line
    SearchResultMarkingLine emptyMarking = {};
    _markingLines.push_back(emptyMarking);
    _lineKinds.push_back(SearchResultLineKindSearchHeader);

    for (NPPFileResults *fileRes in fileResults) {
        // File header — flush left like every other line (owner request).
        NSString *fileHeader = [NSString stringWithFormat:@"%@ (%ld hit%@)\n",
            fileRes.filePath,
            (long)fileRes.results.count,
            fileRes.results.count == 1 ? @"" : @"s"];
        // wParam = UTF-8 byte count, not character count — see issue #46 note above.
        [_sci message:SCI_APPENDTEXT
                     wParam:[fileHeader lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                     lParam:(sptr_t)fileHeader.UTF8String];

        _SRLineInfo fileInfo = {};
        fileInfo.filePath = fileRes.filePath.UTF8String ?: "";
        fileInfo.lineNumber = 0;
        _lineInfos.push_back(fileInfo);
        _markingLines.push_back(SearchResultMarkingLine{});
        _lineKinds.push_back(SearchResultLineKindFileHeader);

        for (NPPSearchResult *r in fileRes.results) {
            // Result line: the source line's text alone, flush left. NPP writes
            // "\t" + find-result-line-prefix + padded line number + ": " + text
            // (Finder::foundLine — FindReplaceDlg.cpp:5805); the owner asked for
            // the text without the prefix and without left whitespace. The line
            // number still drives navigation via _lineInfos, and the lexer gets
            // the line kind from _lineKinds (src/LexSearchResult.cxx).
            size_t prefixBytes = 0;

            // NPP truncates result lines to the search-result lexer's line buffer
            // (SC_SEARCHRESULT_LINEBUFFERMAXLENGTH - 4, Scintilla.h). Appending a
            // longer line makes the lexer split it: the continuation is
            // reclassified as a header and the marking is re-painted at bogus
            // offsets (measured: a duplicate mark at +2048 on a long log line).
            // Truncate on a UTF-8 character boundary so every appended line stays
            // one lexer line.
            static const NSUInteger kSearchResultLineBufferMax = 2048; // SC_SEARCHRESULT_LINEBUFFERMAXLENGTH
            NSUInteger budget = kSearchResultLineBufferMax - 4;
            NSUInteger allowedTextBytes = budget > prefixBytes ? budget - prefixBytes : 0;

            NSString *text = r.lineText ?: @"";
            NSUInteger textBytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (textBytes > allowedTextBytes) {
                NSUInteger end = text.length;
                while (textBytes > allowedTextBytes && end > 0) {
                    NSRange last = [text rangeOfComposedCharacterSequenceAtIndex:end - 1];
                    textBytes -= [[text substringWithRange:last]
                                     lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    end = last.location;
                }
                text = [text substringToIndex:end];
            }

            NSString *resultLine = [NSString stringWithFormat:@"%@\n", text];

            // matchStart/matchLength are UTF-8 byte offsets (NPP convention:
            // start_mark = targetStart - lstart; SearchEngine normalises every
            // producer to bytes). Treating them as character indices — as this
            // code used to — over-highlights any line whose match follows a
            // multibyte character. A match past the truncation point cannot be
            // shown, so it gets no marking (NPP: "The occurrence is NOT
            // displayed in the line").
            SearchResultMarkingLine marking = {};
            if (r.matchStart >= 0 && r.matchLength > 0 &&
                (NSUInteger)r.matchStart + (NSUInteger)r.matchLength <= textBytes) {
                // LexSearchResult: ColourTo(startLine + mi.first - 1, DEFAULT) then
                // ColourTo(startLine + mi.second - 1, WORD2SEARCH).
                // So mi.first = offset of first highlighted byte (0-based within line buffer)
                // and mi.second = offset of last highlighted byte + 1
                intptr_t segStart = (intptr_t)(prefixBytes + (NSUInteger)r.matchStart);
                intptr_t segEnd   = (intptr_t)(prefixBytes + (NSUInteger)r.matchStart + (NSUInteger)r.matchLength);
                marking._segmentPostions.push_back(std::make_pair(segStart, segEnd));
            }
            _markingLines.push_back(marking);
            _lineKinds.push_back(SearchResultLineKindResult);

            // wParam = UTF-8 byte count, not character count — see issue #46 note above.
            [_sci message:SCI_APPENDTEXT
                         wParam:[resultLine lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                         lParam:(sptr_t)resultLine.UTF8String];

            _SRLineInfo lineInfo = {};
            lineInfo.filePath = r.filePath.UTF8String ?: "";
            lineInfo.lineNumber = (int)r.lineNumber;
            _lineInfos.push_back(lineInfo);
        }
    }

    // Update markings struct pointer for lexer
    _markingsStruct._length    = (intptr_t)_markingLines.size();
    _markingsStruct._markings  = _markingLines.data();
    _markingsStruct._lineKinds = _lineKinds.data();

    // Pass pointer to lexer
    char ptrStr[64];
    snprintf(ptrStr, sizeof(ptrStr), "%p", &_markingsStruct);
    [_sci message:SCI_SETPROPERTY wParam:(uptr_t)"@MarkingsStruct" lParam:(sptr_t)ptrStr];

    [_sci message:SCI_SETREADONLY wParam:1];

    // Trigger re-colourise
    [_sci message:SCI_COLOURISE wParam:0 lParam:-1];

    // Scroll to show the new results
    sptr_t lastLine = [_sci message:SCI_GETLINECOUNT] - 1;
    sptr_t firstNewLine = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)startPos];
    [_sci message:SCI_GOTOLINE wParam:(uptr_t)firstNewLine];

    // Expand all folds in new results
    for (sptr_t line = firstNewLine; line <= lastLine; line++) {
        sptr_t level = [_sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if (level & SC_FOLDLEVELHEADERFLAG) {
            if (!([_sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line]))
                [_sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
        }
    }
}

- (void)clearAll {
    [_sci message:SCI_SETREADONLY wParam:0];
    [_sci message:SCI_CLEARALL];
    [_sci message:SCI_SETREADONLY wParam:1];
    _lineInfos.clear();
    _markingLines.clear();
    _lineKinds.clear();
    _markingsStruct._length    = 0;
    _markingsStruct._markings  = nullptr;
    _markingsStruct._lineKinds = nullptr;
}

/// Select an entire line in the search results panel so it stays highlighted.
- (void)_selectResultLine:(sptr_t)line {
    sptr_t lineStart = [_sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    sptr_t lineEnd   = [_sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
    [_sci message:SCI_SETSEL wParam:(uptr_t)lineStart lParam:lineEnd];
    [_sci message:SCI_SCROLLCARET];
}

- (BOOL)navigateToNextResult {
    sptr_t currentLine = [_sci message:SCI_LINEFROMPOSITION
                                wParam:(uptr_t)[_sci message:SCI_GETCURRENTPOS]];
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];

    for (sptr_t line = currentLine + 1; line < lineCount; line++) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    // Wrap to beginning
    for (sptr_t line = 0; line <= currentLine && line < lineCount; line++) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    return NO;
}

- (BOOL)navigateToPreviousResult {
    sptr_t currentLine = [_sci message:SCI_LINEFROMPOSITION
                                wParam:(uptr_t)[_sci message:SCI_GETCURRENTPOS]];
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];

    for (sptr_t line = currentLine - 1; line >= 0; line--) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    // Wrap to end
    for (sptr_t line = lineCount - 1; line > currentLine; line--) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    return NO;
}

- (void)foldAll {
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    for (sptr_t line = 0; line < lineCount; line++) {
        sptr_t level = [_sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if ((level & SC_FOLDLEVELHEADERFLAG) && [_sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line])
            [_sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
    }
}

- (void)unfoldAll {
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    for (sptr_t line = 0; line < lineCount; line++) {
        sptr_t level = [_sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if ((level & SC_FOLDLEVELHEADERFLAG) && !([_sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line]))
            [_sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
    }
}

#pragma mark - Context menu

- (NSMenu *)_buildContextMenu {
    NSMenu *m = [[NSMenu alloc] init];
    m.delegate = (id)self;
    NppLocalizer *loc = [NppLocalizer shared];

    // 1. Find in these search results...
    [m addItemWithTitle:[loc translate:@"Find in these search results..."]
                 action:@selector(_findInResults:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 2-3. Fold/Unfold
    [m addItemWithTitle:[loc translate:@"Fold all"]   action:@selector(_foldAll:)   keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Unfold all"] action:@selector(_unfoldAll:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 4-8. Copy, Copy Lines, Copy Paths, Select all, Clear all
    [m addItemWithTitle:[loc translate:@"Copy"]                      action:@selector(_copy:)          keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Copy Selected Line(s)"]     action:@selector(_copyLines:)     keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Copy Selected Pathname(s)"] action:@selector(_copyPathnames:) keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Select all"]                action:@selector(_selectAll:)     keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Clear all"]                 action:@selector(_clearAll:)      keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 9. Open Selected Pathname(s)
    [m addItemWithTitle:[loc translate:@"Open Selected Pathname(s)"] action:@selector(_openPathnames:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 10-11. Toggles
    NSMenuItem *wrapItem = [[NSMenuItem alloc] initWithTitle:[loc translate:@"Word wrap long lines"]
                                                     action:@selector(_toggleWordWrap:) keyEquivalent:@""];
    wrapItem.tag = 1001;
    [m addItem:wrapItem];

    NSMenuItem *purgeItem = [[NSMenuItem alloc] initWithTitle:[loc translate:@"Purge for every search"]
                                                      action:@selector(_togglePurge:) keyEquivalent:@""];
    purgeItem.tag = 1002;
    [m addItem:purgeItem];

    for (NSMenuItem *mi in m.itemArray) {
        if (!mi.isSeparatorItem) mi.target = self;
    }
    return m;
}

// Update checkmarks before menu is shown
- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.tag == 1001) mi.state = _wordWrapEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        if (mi.tag == 1002) mi.state = _purgeBeforeSearch ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

#pragma mark - Context menu actions

/// Get text of a single line, or nil if line is hidden or empty.
- (NSString *)_visibleLineText:(sptr_t)line {
    if (![_sci message:SCI_GETLINEVISIBLE wParam:(uptr_t)line]) return nil;
    sptr_t linePos = [_sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    sptr_t lineEndPos = [_sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
    sptr_t len = lineEndPos - linePos;
    if (len <= 0) return nil;
    char *buf = (char *)calloc(len + 1, 1);
    struct Sci_TextRangeFull tr = {};
    tr.chrg.cpMin = linePos;
    tr.chrg.cpMax = lineEndPos;
    tr.lpstrText = buf;
    [_sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    NSString *text = [NSString stringWithUTF8String:buf] ?: @"";
    free(buf);
    return text;
}

- (void)_copy:(id)sender {
    // Respect the actual selection: copying a partial selection must copy just
    // that text, not the whole line (issue: "复制会复制整行"). The line-based
    // walk below stays for the no-selection case, where it skips hidden/filtered
    // lines — that behaviour is what the ⌘C interceptor was built for.
    sptr_t selStart = [_sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [_sci message:SCI_GETSELECTIONEND];
    if (selEnd > selStart) {
        NSString *selected = _sci.selectedString;
        if (selected.length) {
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:selected
                                                 forType:NSPasteboardTypeString];
            return;
        }
    }

    // No selection — copy only visible lines in the caret's line range.
    sptr_t lineStart = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t lineEnd   = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];

    NSMutableString *result = [NSMutableString string];
    for (sptr_t line = lineStart; line <= lineEnd; line++) {
        NSString *text = [self _visibleLineText:line];
        if (text) [result appendFormat:@"%@\n", text];
    }
    if (result.length > 0) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:result forType:NSPasteboardTypeString];
    }
}

- (void)_selectAll:(id)sender { [_sci message:SCI_SELECTALL]; }

- (void)_clearAll:(id)sender { [self clearAll]; }

- (void)_foldAll:(id)sender { [self foldAll]; }

- (void)_unfoldAll:(id)sender { [self unfoldAll]; }

- (void)_copyLines:(id)sender {
    // Copy only visible result lines WITH line numbers (exactly as shown)
    sptr_t selStart = [_sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [_sci message:SCI_GETSELECTIONEND];
    sptr_t lineStart = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t lineEnd   = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];

    NSMutableString *result = [NSMutableString string];
    for (sptr_t line = lineStart; line <= lineEnd; line++) {
        NSString *lineText = [self _visibleLineText:line];
        if (!lineText) continue;

        // Include result lines (tab-prefixed) with their line numbers
        if ([lineText hasPrefix:@"\t"]) {
            // Remove leading tab, keep "Line NNN: content"
            [result appendFormat:@"%@\n", [lineText substringFromIndex:1]];
        }
    }

    if (result.length > 0) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:result forType:NSPasteboardTypeString];
    }
}

- (void)_copyPathnames:(id)sender {
    NSArray<NSString *> *paths = [self _selectedPathnames];
    if (paths.count == 0) return;
    NSString *joined = [paths componentsJoinedByString:@"\n"];
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:joined forType:NSPasteboardTypeString];
}

- (void)_openPathnames:(id)sender {
    NSArray<NSString *> *paths = [self _selectedPathnames];
    for (NSString *path in paths) {
        [_delegate searchResultsPanel:self navigateToFile:path atLine:1 matchText:@"" matchCase:NO];
    }
}

- (void)_toggleWordWrap:(id)sender {
    _wordWrapEnabled = !_wordWrapEnabled;
    [_sci message:SCI_SETWRAPMODE wParam:_wordWrapEnabled ? SC_WRAP_WORD : SC_WRAP_NONE];
    [[NSUserDefaults standardUserDefaults] setBool:_wordWrapEnabled forKey:@"SearchResultsWordWrap"];
}

- (void)_togglePurge:(id)sender {
    _purgeBeforeSearch = !_purgeBeforeSearch;
    [[NSUserDefaults standardUserDefaults] setBool:_purgeBeforeSearch forKey:@"SearchResultsPurge"];
}

- (void)findInSearchResults:(id)sender {
    [self _findInResults:sender];
}

- (void)_findInResults:(id)sender {
    // Show the filter bar
    _filterBarHeight.constant = 30;
    _filterBar.hidden = NO;
    _filterSep.hidden = NO;
    [self.window makeFirstResponder:_filterField];
}

- (void)_closeFilterBar:(id)sender {
    _filterBarHeight.constant = 0;
    _filterBar.hidden = YES;
    _filterSep.hidden = YES;
    _filterField.stringValue = @"";
    _filterStatusLabel.stringValue = @"";
    // Unhide all lines
    [self _showAllLines];
}

- (void)_filterChanged:(id)sender {
    [self _applyFilter];
}

// NSTextFieldDelegate — live filtering as user types
- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == _filterField) {
        [self _applyFilter];
    }
}

// Handle Escape key in filter field
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (control == _filterField && commandSelector == @selector(cancelOperation:)) {
        [self _closeFilterBar:nil];
        return YES;
    }
    return NO;
}

- (void)_applyFilter {
    NSString *filter = _filterField.stringValue;
    if (!filter.length) {
        [self _showAllLines];
        _filterStatusLabel.stringValue = @"";
        return;
    }

    BOOL matchCase = (_filterMatchCase.state == NSControlStateValueOn);
    BOOL wholeWord = (_filterWholeWord.state == NSControlStateValueOn);
    NSStringCompareOptions cmpOpts = matchCase ? 0 : NSCaseInsensitiveSearch;

    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    NSInteger matchCount = 0;

    // First pass: determine which result lines match
    // Track which file headers have matching children
    NSMutableIndexSet *matchingLines = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *fileHeadersWithMatches = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *searchHeaders = [NSMutableIndexSet indexSet];

    sptr_t currentFileHeader = -1;

    for (sptr_t line = 0; line < lineCount; line++) {
        sptr_t linePos = [_sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
        sptr_t lineEndPos = [_sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
        sptr_t len = lineEndPos - linePos;
        if (len <= 0) continue;

        // Classify by the kind recorded while appending (addResults:), not by
        // the first character: result lines no longer carry the "\t" / space
        // prefixes, so a first-character test made every result line look like
        // a "search header" (always visible) — the filter silently did nothing
        // — and lines whose text begins with a space looked like file headers
        // (they disappeared).
        int kind = ((size_t)line < _lineKinds.size())
                 ? _lineKinds[(size_t)line] : SearchResultLineKindResult;

        if (kind == SearchResultLineKindSearchHeader) {
            // Search header — always visible
            [searchHeaders addIndex:(NSUInteger)line];
            [matchingLines addIndex:(NSUInteger)line];
            continue;
        }

        if (kind == SearchResultLineKindFileHeader) {
            // File header — remember it, show later if children match
            currentFileHeader = line;
            continue;
        }

        // Result line — check if it matches filter
        char *buf = (char *)calloc(len + 1, 1);
        struct Sci_TextRangeFull tr = {};
        tr.chrg.cpMin = linePos;
        tr.chrg.cpMax = lineEndPos;
        tr.lpstrText = buf;
        [_sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
        NSString *lineText = [NSString stringWithUTF8String:buf] ?: @"";
        free(buf);

        NSRange matchRange = [lineText rangeOfString:filter options:cmpOpts];
        BOOL matched = (matchRange.location != NSNotFound);

        // Whole word check
        if (matched && wholeWord) {
            NSCharacterSet *wordChars = [NSCharacterSet alphanumericCharacterSet];
            if (matchRange.location > 0) {
                unichar c = [lineText characterAtIndex:matchRange.location - 1];
                if ([wordChars characterIsMember:c] || c == '_') matched = NO;
            }
            NSUInteger endPos = matchRange.location + matchRange.length;
            if (matched && endPos < lineText.length) {
                unichar c = [lineText characterAtIndex:endPos];
                if ([wordChars characterIsMember:c] || c == '_') matched = NO;
            }
        }

        if (matched) {
            [matchingLines addIndex:(NSUInteger)line];
            matchCount++;
            if (currentFileHeader >= 0) {
                [fileHeadersWithMatches addIndex:(NSUInteger)currentFileHeader];
            }
        }
    }

    // Add file headers that have matching children
    [matchingLines addIndexes:fileHeadersWithMatches];

    // Second pass: show/hide lines
    [_sci message:SCI_SETREADONLY wParam:0];
    for (sptr_t line = 0; line < lineCount; line++) {
        if ([matchingLines containsIndex:(NSUInteger)line]) {
            [_sci message:SCI_SHOWLINES wParam:(uptr_t)line lParam:(uptr_t)line];
        } else {
            [_sci message:SCI_HIDELINES wParam:(uptr_t)line lParam:(uptr_t)line];
        }
    }
    [_sci message:SCI_SETREADONLY wParam:1];

    // Update status
    if (matchCount > 0) {
        _filterStatusLabel.stringValue = [NSString stringWithFormat:@"%ld match%@",
            (long)matchCount, matchCount == 1 ? @"" : @"es"];
        _filterStatusLabel.textColor = [NSColor secondaryLabelColor];
    } else {
        _filterStatusLabel.stringValue = [[NppLocalizer shared] translate:@"Not found"];
        _filterStatusLabel.textColor = [NSColor systemRedColor];
    }
}

- (void)_showAllLines {
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    [_sci message:SCI_SETREADONLY wParam:0];
    [_sci message:SCI_SHOWLINES wParam:0 lParam:(uptr_t)(lineCount - 1)];
    [_sci message:SCI_SETREADONLY wParam:1];
}

#pragma mark - Helpers

- (NSArray<NSString *> *)_selectedPathnames {
    sptr_t selStart = [_sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [_sci message:SCI_GETSELECTIONEND];
    sptr_t lineStart = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t lineEnd   = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];

    // If nothing selected, use all lines
    if (selStart == selEnd) {
        lineStart = 0;
        lineEnd = (sptr_t)_lineInfos.size() - 1;
    }

    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (sptr_t line = lineStart; line <= lineEnd; line++) {
        // Skip hidden lines
        if (![_sci message:SCI_GETLINEVISIBLE wParam:(uptr_t)line]) continue;
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].filePath.length() > 0) {
            NSString *path = [NSString stringWithUTF8String:_lineInfos[line].filePath.c_str()];
            if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [paths addObject:path];
            }
        }
    }
    return [paths array];
}

#pragma mark - Panel Zoom

- (void)panelZoomIn   { [_sci message:SCI_ZOOMIN]; [[NSUserDefaults standardUserDefaults] setInteger:[_sci message:SCI_GETZOOM] forKey:@"PanelZoom_SearchResults"]; }
- (void)panelZoomOut  { [_sci message:SCI_ZOOMOUT]; [[NSUserDefaults standardUserDefaults] setInteger:[_sci message:SCI_GETZOOM] forKey:@"PanelZoom_SearchResults"]; }
- (void)panelZoomReset { [_sci message:SCI_SETZOOM wParam:0]; [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"PanelZoom_SearchResults"]; }

@end
