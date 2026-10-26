#import "ForgeChromeScriptingGlue.h"

@implementation ForgeChromeApplication
// ScriptingBridge must create the correct scriptable subclasses for 'cwin'
// and 'CrTb'. SBApplication's untyped base class does not know these names.
- (NSDictionary<NSNumber *, NSString *> *)classNamesForCodes {
    return @{
        @('capp'): @"ForgeChromeApplication",
        @('cwin'): @"ForgeChromeWindow",
        @('CrTb'): @"ForgeChromeTab"
    };
}
@end

@implementation ForgeChromeWindow
@end

@implementation ForgeChromeTab
// Codes are derived from Chrome's installed public sdef (CrSu/ExJa/JvSc,
// core/clos, CrSu/Rlod), not generated or guessed selectors.
- (id)executeJavascript:(NSString *)javascript {
    return [self sendEvent:'CrSu' id:'ExJa' parameters:'JvSc', javascript, 0];
}
- (void)close {
    [self sendEvent:'core' id:'clos' parameters:0];
}
- (void)reload {
    [self sendEvent:'CrSu' id:'Rlod' parameters:0];
}
@end

id ForgeChromeExecuteJavascript(SBObject *tab, NSString *javascript) {
    return [tab sendEvent:'CrSu' id:'ExJa' parameters:'JvSc', javascript, 0];
}
void ForgeChromeCloseTab(SBObject *tab) {
    [tab sendEvent:'core' id:'clos' parameters:0];
}
void ForgeChromeReloadTab(SBObject *tab) {
    [tab sendEvent:'CrSu' id:'Rlod' parameters:0];
}
