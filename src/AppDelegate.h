#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class MainWindowController;
@class NppCommandLineParams;

@interface AppDelegate : NSObject <NSApplicationDelegate>

/// The primary window controller (first window opened).
@property (nonatomic, strong) MainWindowController *mainWindowController;

/// All open window controllers (including mainWindowController).
@property (nonatomic, strong, readonly) NSMutableArray<MainWindowController *> *windowControllers;

/// Command line parameters parsed in main(). Set before NSApplication runs.
@property (nonatomic, strong, nullable) NppCommandLineParams *cliParams;

/// Launch timestamp for -loadingTime display.
@property (nonatomic, strong, nullable) NSDate *launchStart;

/// YES once -applicationShouldTerminate: has begun tearing windows down.
/// Windows consult this so they don't re-save the session per-window while the
/// app is quitting — that save has already happened once, for all windows.
@property (nonatomic, readonly) BOOL isTerminating;

/// Create and show a new editor window. Returns the new controller.
- (MainWindowController *)openNewWindow;

/// Check GitHub for a newer release. If userInitiated is YES, shows alert even if up-to-date.
- (void)checkForUpdateUserInitiated:(BOOL)userInitiated;

/// Action wired to "Check for Updates..." menu item.
- (void)checkForUpdates:(id)sender;

/// Expand a mixed list of dropped / OS-provided paths for opening: plain files
/// pass through, folders expand to the files they contain. With `recursive` the
/// whole tree is walked (what a folder drop means); without it only the folder's
/// top level is taken (the documented bare-folder CLI behaviour, issue #131).
/// Hidden entries and package directories (.app, .bundle, …) are skipped either
/// way. Shows a confirmation when the expansion exceeds the folder-open
/// threshold; returns nil when the user cancels, so callers must treat nil as
/// "do nothing".
+ (nullable NSArray<NSString *> *)expandFolderPaths:(NSArray<NSString *> *)paths
                                          recursive:(BOOL)recursive;

@end

NS_ASSUME_NONNULL_END
