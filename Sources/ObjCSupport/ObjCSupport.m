#import "ObjCSupport.h"

NSError * _Nullable UKMCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
        info[@"ExceptionName"] = exception.name;
        return [NSError errorWithDomain:@"UniversalKM.ObjCException" code:1 userInfo:info];
    }
}
