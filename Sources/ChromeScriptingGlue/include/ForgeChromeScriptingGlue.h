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

// Resolve one indexed object without materializing the complete live collection.
// Objective-C exceptions are converted to NSError at the bridge boundary.
FOUNDATION_EXPORT SBObject * _Nullable ForgeChromeElementAtIndex(
    SBElementArray * _Nullable elements, NSUInteger index, NSError * _Nullable * _Nullable error);

// Convert a live ScriptingBridge collection to a bounded ordinary NSArray.
// A concurrent Chrome window/tab mutation must fail closed, not crash the provider.
FOUNDATION_EXPORT NSArray<SBObject *> * _Nullable ForgeChromeSnapshotElements(
    SBElementArray * _Nullable elements, NSUInteger limit, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
