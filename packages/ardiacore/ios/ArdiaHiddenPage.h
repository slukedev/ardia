#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ArdiaHiddenPage : NSObject

+ (nullable instancetype)openURL:(NSString *)url profile:(NSString *)profile config:(NSString *)configJSON NS_SWIFT_NAME(open(url:profile:config:));

@property(nonatomic, copy, nullable) void (^onMessage)(NSString *kind, NSString *json, NSString *origin, BOOL main);
@property(nonatomic, copy, nullable) void (^onCommit)(NSString *url);
@property(nonatomic, copy, nullable) void (^onFail)(NSString *url, NSInteger code);
@property(nonatomic, copy, nullable) void (^onClosed)(void);
@property(nonatomic, readonly) NSString *url;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) BOOL revealed;

- (void)blockDownloadsFrom:(NSString *)origin NS_SWIFT_NAME(blockDownloads(from:));
- (void)load:(NSString *)url;
- (void)evaluate:(NSString *)code completion:(void (^)(NSString *_Nullable json))completion;
- (void)send:(NSString *)kind json:(NSString *)json;
- (BOOL)revealWithTitle:(NSString *)title onDismiss:(void (^)(void))dismissed;
- (void)conceal;
- (void)close;

@end

NS_ASSUME_NONNULL_END
