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

SBObject * _Nullable ForgeChromeElementAtIndex(
    SBElementArray * _Nullable elements, NSUInteger index, NSError * _Nullable * _Nullable error) {
    if (!elements) return nil;
    @try {
        id object = [elements objectAtIndex:index];
        if (![object isKindOfClass:[SBObject class]]) {
            if (error) *error = [NSError errorWithDomain:@"ForgeChromeScriptingBridge"
                                                      code:4
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Indexed collection item was not an SBObject"}];
            return nil;
        }
        return (SBObject *)object;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"ForgeChromeScriptingBridge"
                                                  code:5
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"Indexed collection lookup failed: %@", exception.name]}];
        return nil;
    }
}

NSArray<SBObject *> * _Nullable ForgeChromeSnapshotElements(
    SBElementArray * _Nullable elements, NSUInteger limit, NSError * _Nullable * _Nullable error) {
    if (!elements) return @[];
    @try {
        id resolved = [elements get];
        if (!resolved) return @[];
        if (![resolved isKindOfClass:[NSArray class]]) {
            if (error) *error = [NSError errorWithDomain:@"ForgeChromeScriptingBridge"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Native collection was not an NSArray"}];
            return nil;
        }
        NSArray *live = (NSArray *)resolved;
        NSUInteger count = MIN(live.count, limit);
        NSMutableArray<SBObject *> *stable = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger index = 0; index < count; index++) {
            // Do not enumerate a live SBElementArray or copy it through
            // Foundation: concurrent removal can raise NSRangeException.
            id object = [live objectAtIndex:index];
            if (![object isKindOfClass:[SBObject class]]) {
                if (error) *error = [NSError errorWithDomain:@"ForgeChromeScriptingBridge"
                                                          code:3
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Native collection contained a non-SBObject"}];
                return nil;
            }
            [stable addObject:object];
        }
        return [stable copy];
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"ForgeChromeScriptingBridge"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"Native collection changed: %@", exception.name]}];
        return nil;
    }
}
