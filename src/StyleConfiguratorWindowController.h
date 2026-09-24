#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// ── Style data model (also used by EditorView) ────────────────────────────────

/// One style slot for a language (e.g. "COMMENT" → styleID=1 in cpp lexer).
@interface NPPStyleEntry : NSObject <NSCopying>
@property (nonatomic, copy)     NSString            *name;
@property (nonatomic)           int                  styleID;
@property (nonatomic, nullable) NSColor             *fgColor;   // nil = not set
@property (nonatomic, nullable) NSColor             *bgColor;
@property (nonatomic, copy)     NSString            *fontName;  // @"" = inherit
@property (nonatomic)           int                  fontSize;  // 0 = inherit
@property (nonatomic)           BOOL                 bold, italic, underline;
@property (nonatomic)           BOOL                 fontStyleExplicit; // fontStyle attr was set in XML
@end

/// All styles for a single language/lexer.
@interface NPPLexer : NSObject <NSCopying>
@property (nonatomic, copy)   NSString                        *lexerID;       // @"cpp", @"global"
@property (nonatomic, copy)   NSString                        *displayName;   // @"C++", @"Global Styles"
@property (nonatomic, strong) NSMutableArray<NPPStyleEntry *> *styles;
- (nullable NPPStyleEntry *)styleForID:(int)sid;
@end

/// Parse an NPP "RRGGBB" colour string (the form used by stylers.xml and the
/// UDL XML files) into an NSColor. Returns nil for nil / empty / malformed input.
NSColor * _Nullable NPPColorFromHex(NSString * _Nullable hex);

// ── Style store (singleton) ───────────────────────────────────────────────────

@interface NPPStyleStore : NSObject

+ (NPPStyleStore *)sharedStore;

/// Parse the bundled XML and apply any saved overrides.  Call once at launch.
- (void)loadFromDefaults;

/// Return all style entries for a lexer (resolved = theme + user override).
- (nullable NSArray<NPPStyleEntry *> *)stylesForLexer:(NSString *)lexerID;

/// Ordered list of all lexers (Global Styles first, then alphabetical).
@property (readonly, nonatomic) NSArray<NPPLexer *> *allLexers;

/// Name of the currently active theme (updated on preview and commit).
@property (nonatomic, copy) NSString *activeThemeName;

/// Names of all available themes: "Default (stylers.xml)" + bundled theme files.
@property (readonly, nonatomic) NSArray<NSString *> *availableThemeNames;

/// Convenience: global "Default Style" resolved properties.
@property (readonly, nonatomic) NSColor  *globalFg;
@property (readonly, nonatomic) NSColor  *globalBg;
@property (readonly, nonatomic) NSString *globalFontName;
@property (readonly, nonatomic) int       globalFontSize;

/// Look up a Global Style (WidgetStyle) entry by name.
/// Names: "Caret colour", "Line number margin", "Brace highlight style",
/// "Current line background colour", "Selected text colour", "Fold", "Fold margin",
/// "White space symbol", "Bad brace colour", etc.
- (nullable NPPStyleEntry *)globalStyleNamed:(NSString *)name;

/// NPP's "Global override" substitution (Windows parity: ScintillaEditView.cpp
/// — setStyle()/setSpecialStyle(), issue #149). For every enabled force-flag
/// the matching attribute of the "Global override" row replaces the style's own
/// value; when the override row leaves an attribute unset ("transparent") the
/// returned entry clears that attribute (nil colour, empty font, 0 size,
/// NO flags) so the caller skips its SCI_STYLESET* call and the attribute stays
/// at STYLE_DEFAULT. Returns a copy — `style` is never modified. Every path
/// that pushes per-style attributes must go through this method: built-in
/// lexers (EditorView) *and* UDL languages (UserDefineLangManager), because
/// Windows applies both through setStyle().
- (NPPStyleEntry *)styleByApplyingGlobalOverride:(NPPStyleEntry *)style;

/// Load a fresh set of lexers for the given theme name (Default or XML file name).
/// Returns a fully-merged array (model defaults + theme overrides).
- (NSArray<NPPLexer *> *)lexersForTheme:(NSString *)themeName;

/// Update in-memory state + notify EditorViews (no NSUserDefaults write).
- (void)previewLexers:(NSArray<NPPLexer *> *)lexers;

/// Persist to NSUserDefaults + notify EditorViews.
- (void)commitLexers:(NSArray<NPPLexer *> *)lexers themeName:(NSString *)themeName;

@end

// ── Window controller ─────────────────────────────────────────────────────────

@interface StyleConfiguratorWindowController : NSWindowController

+ (instancetype)sharedController;

/// Show the configurator and optionally trigger an import sheet.
- (void)importTheme:(id)sender;

@end

NS_ASSUME_NONNULL_END
