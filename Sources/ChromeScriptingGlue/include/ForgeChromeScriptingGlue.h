#import <Foundation/Foundation.h>
#import <ScriptingBridge/ScriptingBridge.h>

NS_ASSUME_NONNULL_BEGIN

// Minimal Chrome sdef glue. This is a *single*, PID-bound ScriptingBridge
// transport, not an additional AppleScript or CDP automation provider.
@interface ForgeChromeApplication : SBApplication
@end

@interface ForgeChromeWindow : SBObject
@end

@interface ForgeChromeTab : SBObject
- (id)executeJavascript:(NSString *)javascript;
- (void)close;
- (void)reload;
@end

// Typed, PID-bound Apple Events on an exact SBObject Tab specifier. Generic
// SBObject instances do not implement Chrome-specific Objective-C selectors.
FOUNDATION_EXPORT id _Nullable ForgeChromeExecuteJavascript(SBObject *tab, NSString *javascript);
FOUNDATION_EXPORT void ForgeChromeCloseTab(SBObject *tab);
FOUNDATION_EXPORT void ForgeChromeReloadTab(SBObject *tab);

NS_ASSUME_NONNULL_END
