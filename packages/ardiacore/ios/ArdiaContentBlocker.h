#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ArdiaContentBlocker : NSObject
+ (void)state:(void (^)(NSDictionary<NSString *, id> *state))completion NS_SWIFT_NAME(state(_:));
+ (void)setEnabled:(BOOL)enabled completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(setEnabled(_:completion:));
+ (void)setList:(NSString *)listId enabled:(BOOL)enabled completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(setList(_:enabled:completion:));
+ (void)addList:(NSString *)url completion:(void (^)(NSDictionary<NSString *, id> *_Nullable added, NSString *_Nullable error))completion NS_SWIFT_NAME(addList(_:completion:));
+ (void)removeList:(NSString *)listId completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(removeList(_:completion:));
+ (void)isAllowedOnHost:(NSString *)host completion:(void (^)(BOOL allowed))completion NS_SWIFT_NAME(isAllowed(host:completion:));
+ (void)setAllowed:(BOOL)allowed onHost:(NSString *)host completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(setAllowed(_:host:completion:));
+ (void)userFilters:(void (^)(NSDictionary<NSString *, id> *_Nullable filters, NSString *_Nullable error))completion NS_SWIFT_NAME(userFilters(_:));
+ (void)hiddenElementsInProfile:(NSString *)profile completion:(void (^)(NSArray<NSString *> *_Nullable filters, NSString *_Nullable error))completion NS_SWIFT_NAME(hiddenElements(profile:completion:));
+ (void)hideElements:(NSArray<NSString *> *)filters inProfile:(NSString *)profile completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(hideElements(_:profile:completion:));
+ (void)restoreElements:(NSArray<NSString *> *)filters inProfile:(NSString *)profile completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(restoreElements(_:profile:completion:));
+ (void)devFailNextMessage;
+ (void)devDelayNextLoad:(double)ms;
@end

NS_ASSUME_NONNULL_END
