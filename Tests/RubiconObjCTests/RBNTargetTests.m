@import XCTest;
@import RubiconObjC;
#if __has_include(<UIKit/UIKit.h>)
@import UIKit;
#endif

/// The Objective-C wrapper from Objective-C (step 7.7, iOS Public API 1, D16). Compiling this file is
/// half the test: a method that does not import fails the build. The rest exercises one real
/// instance through the selectors an app would use, with the uploads pointed at a closed local port.
/// The conversions and the raising blocks are checked in detail from Swift (RBNWrapperTests).

static NSMutableArray<NSString *> *gLogLines;
static NSMutableArray<RBNEventUpdate *> *gUpdates;
static RBNAnalytics *gAnalytics;

#if __has_include(<UIKit/UIKit.h>)
@interface RBNLegacyScreenViewController : UIViewController <RBNScreenNamed>
@end

@implementation RBNLegacyScreenViewController
+ (NSString *)rbnScreenName {
    return @"legacy";
}
@end
#endif

@interface RBNTargetTests : XCTestCase
@end

@implementation RBNTargetTests

+ (void)setUp {
    [super setUp];
    gLogLines = [NSMutableArray array];
    gUpdates = [NSMutableArray array];
    RBNConfiguration *config = [[RBNConfiguration alloc] initWithApiKey:@"rk_objc_target"];
    config.host = @"http://127.0.0.1:9";
    config.debug = NO;
    config.flush.at = 100;
    config.flush.intervalMs = 600000;
    config.logging.sendDiagnostics = NO;
    config.logging.level = RBNLogLevelWarn;
    config.logging.logger = ^(RBNLogLevel level, NSString *message, NSError *error) {
        @synchronized(gLogLines) {
            [gLogLines addObject:message];
        }
    };
    config.logging.eventObserver = ^(RBNEventUpdate *update) {
        @synchronized(gUpdates) {
            [gUpdates addObject:update];
        }
    };
    [config addBeforeSend:^RBNEvent *(RBNEvent *event) {
        if ([event isKindOfClass:[RBNTrackEvent class]]) {
            RBNTrackEvent *track = (RBNTrackEvent *)event;
            if ([track.name isEqualToString:@"Raises"]) {
                [NSException raise:@"RBNTestException" format:@"from a block"];
            }
            if ([track.name isEqualToString:@"Dropped"]) {
                return nil;
            }
            if ([track.name isEqualToString:@"Renamed"]) {
                track.name = @"Renamed By Hook";
                NSMutableDictionary *properties = [track.properties mutableCopy];
                properties[@"hooked"] = @YES;
                track.properties = properties;
            }
        }
        return event;
    }];
    gAnalytics = [RBNAnalytics makeWithConfiguration:config];
}

- (RBNEventUpdate *)waitForQueuedEventNamed:(NSString *)name {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([deadline timeIntervalSinceNow] > 0) {
        @synchronized(gUpdates) {
            for (RBNEventUpdate *update in gUpdates) {
                if (update.kind != RBNEventUpdateKindQueued) continue;
                if ([update.event isKindOfClass:[RBNTrackEvent class]]
                    && [((RBNTrackEvent *)update.event).name isEqualToString:name]) {
                    return update;
                }
                if ([update.event isKindOfClass:[RBNScreenEvent class]]
                    && [((RBNScreenEvent *)update.event).name isEqualToString:name]) {
                    return update;
                }
            }
        }
        [NSThread sleepForTimeInterval:0.02];
    }
    return nil;
}

- (BOOL)waitUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (condition()) return YES;
        [NSThread sleepForTimeInterval:0.02];
    }
    return condition();
}

- (void)testConfigurationDefaultsAndSetters {
    RBNConfiguration *config = [[RBNConfiguration alloc] initWithApiKey:@"rk"];
    XCTAssertEqualObjects(config.apiKey, @"rk");
    XCTAssertEqual(config.flush.at, 30);
    XCTAssertEqual(config.flush.intervalMs, 60000);
    XCTAssertEqual(config.session.backgroundTimeoutMs, 300000);
    XCTAssertTrue([config.autocapture isEnabled:RBNAutocaptureSessions]);
    XCTAssertFalse([config.autocapture isEnabled:RBNAutocaptureDeepLinks]);
    XCTAssertFalse([config.context isDisabled:RBNContextFieldLocale]);
    XCTAssertEqual(config.privacy.defaultConsent, RBNConsentGranted);
    XCTAssertTrue(config.privacy.persistConsent);
    XCTAssertEqual(config.logging.level, RBNLogLevelWarn);
    XCTAssertNil(config.logging.logger);
    XCTAssertNil(config.logging.eventObserver);
    XCTAssertTrue(config.logging.sendDiagnostics);
    XCTAssertEqual(config.network.headers.count, 0u);
    XCTAssertEqual(config.beforeSendCount, 0);

    config.host = @"https://collect.example.com";
    config.debug = YES;
    config.flush.at = 5;
    config.flush.intervalMs = 1000;
    config.flush.immediateEvents = [NSSet setWithObject:@"Purchase Completed"];
    config.session.backgroundTimeoutMs = 10000;
    [config.autocapture disable:RBNAutocaptureScreenViews];
    [config.autocapture enable:RBNAutocaptureDeepLinks];
    [config.context disable:RBNContextFieldLocale];
    [config.context enable:RBNContextFieldLocale];
    [config.context disable:RBNContextFieldTimezone];
    config.privacy.defaultConsent = RBNConsentPending;
    config.privacy.persistConsent = NO;
    config.logging.level = RBNLogLevelDebug;
    config.logging.logger = ^(RBNLogLevel level, NSString *message, NSError *error) {};
    config.logging.eventObserver = ^(RBNEventUpdate *update) {};
    config.logging.sendDiagnostics = NO;
    config.network.headers = @{@"X-Gateway": @"a"};
    [config addBeforeSend:^RBNEvent *(RBNEvent *event) { return event; }];

    XCTAssertEqualObjects(config.host, @"https://collect.example.com");
    XCTAssertTrue(config.debug);
    XCTAssertEqual(config.flush.at, 5);
    XCTAssertEqual(config.flush.intervalMs, 1000);
    XCTAssertEqualObjects(config.flush.immediateEvents, [NSSet setWithObject:@"Purchase Completed"]);
    XCTAssertEqual(config.session.backgroundTimeoutMs, 10000);
    XCTAssertFalse([config.autocapture isEnabled:RBNAutocaptureScreenViews]);
    XCTAssertTrue([config.autocapture isEnabled:RBNAutocaptureDeepLinks]);
    XCTAssertFalse([config.context isDisabled:RBNContextFieldLocale]);
    XCTAssertTrue([config.context isDisabled:RBNContextFieldTimezone]);
    XCTAssertEqual(config.privacy.defaultConsent, RBNConsentPending);
    XCTAssertFalse(config.privacy.persistConsent);
    XCTAssertEqual(config.logging.level, RBNLogLevelDebug);
    XCTAssertNotNil(config.logging.logger);
    XCTAssertNotNil(config.logging.eventObserver);
    XCTAssertFalse(config.logging.sendDiagnostics);
    XCTAssertEqualObjects(config.network.headers, @{@"X-Gateway": @"a"});
    XCTAssertEqual(config.beforeSendCount, 1);
    [config removeAllBeforeSend];
    XCTAssertEqual(config.beforeSendCount, 0);
}

- (void)testEnumCasesAreComplete {
    XCTAssertEqual(RBNLogLevelOff, 4);
    XCTAssertEqual(RBNAutocaptureNetworkRequests, 5);
    XCTAssertEqual(RBNContextFieldTimezone, 15);
    XCTAssertEqual(RBNConsentPending, 1);
    XCTAssertEqual(RBNEventSourceAuto, 1);
    XCTAssertEqual(RBNDropReasonRetryExhausted, 9);
    XCTAssertEqual(RBNEventUpdateKindDropped, 2);
}

- (void)testFactoryReturnsOneInstanceAndTheVersion {
    RBNConfiguration *other = [[RBNConfiguration alloc] initWithApiKey:@"rk_other"];
    other.debug = NO;  // with debug on, a second make is a developer error and traps (iOS Configuration 2)
    XCTAssertEqual([RBNAnalytics makeWithConfiguration:other], gAnalytics);
    XCTAssertEqual(gAnalytics.deviceId.length, 36u);
    XCTAssertTrue([RBNAnalytics sdkVersion].length > 0);
    XCTAssertFalse(gAnalytics.isOptedOut);
}

- (void)testTrackReachesTheObserverWithBooleansKeptApart {
    [gAnalytics trackEvent:@"Purchase Completed" properties:@{@"flag": @YES, @"count": @1, @"amount": @49.9}];
    [gAnalytics trackEvent:@"Plain"];

    RBNEventUpdate *update = [self waitForQueuedEventNamed:@"Purchase Completed"];
    XCTAssertNotNil(update);
    RBNTrackEvent *event = (RBNTrackEvent *)update.event;
    XCTAssertEqual(event.source, RBNEventSourceApp);
    XCTAssertEqual(event.messageId.length, 36u);
    XCTAssertEqualObjects(update.messageIds, @[event.messageId]);
    XCTAssertEqualObjects(event.deviceId, gAnalytics.deviceId);
    XCTAssertNotNil(event.timestamp);
    XCTAssertEqualObjects(event.context[@"library"][@"name"], @"rubicon-ios");
    XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)event.properties[@"flag"]), CFBooleanGetTypeID());
    XCTAssertNotEqual(CFGetTypeID((__bridge CFTypeRef)event.properties[@"count"]), CFBooleanGetTypeID());
    XCTAssertEqualObjects(event.properties[@"count"], @1);
    XCTAssertEqualObjects(event.properties[@"amount"], @49.9);
    XCTAssertNotNil([self waitForQueuedEventNamed:@"Plain"]);
}

- (void)testScreenIdentifySuperPropertiesAndDeepLinks {
    [gAnalytics registerSuperProperty:@"tier" value:@"gold"];
    [gAnalytics registerSuperProperty:@"gone" value:[NSNull null]];
    [gAnalytics unregisterSuperProperty:@"gone"];
    [gAnalytics identifyUser:@"user-1" traits:@{@"plan": @"pro"}];
    [gAnalytics identifyUser:@"user-1"];
    [gAnalytics trackScreen:@"Home" properties:@{@"tab": @2}];
    [gAnalytics trackScreen:@"Settings"];
    [gAnalytics trackEvent:@"With Super"];
    [gAnalytics trackDeepLink:[NSURL URLWithString:@"rubicon://offer/1"] referrer:@"com.apple.mobilesafari"];
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = [NSURL URLWithString:@"https://example.com/offer/2"];
    [gAnalytics trackDeepLinkWithActivity:activity];
    [gAnalytics flush];

    RBNEventUpdate *screen = [self waitForQueuedEventNamed:@"Home"];
    XCTAssertTrue([screen.event isKindOfClass:[RBNScreenEvent class]]);
    XCTAssertEqualObjects(((RBNScreenEvent *)screen.event).properties[@"tab"], @2);
    RBNEventUpdate *withSuper = [self waitForQueuedEventNamed:@"With Super"];
    XCTAssertEqualObjects(((RBNTrackEvent *)withSuper.event).properties[@"tier"], @"gold");
    XCTAssertNil(((RBNTrackEvent *)withSuper.event).properties[@"gone"]);
    XCTAssertEqualObjects(withSuper.event.userId, @"user-1");
    BOOL identified = [self waitUntil:^BOOL {
        @synchronized(gUpdates) {
            for (RBNEventUpdate *update in gUpdates) {
                if ([update.event isKindOfClass:[RBNIdentifyEvent class]]
                    && [((RBNIdentifyEvent *)update.event).traits[@"plan"] isEqual:@"pro"]) {
                    return YES;
                }
            }
        }
        return NO;
    }];
    XCTAssertTrue(identified);
    // Deep links are off by default (Lifecycle 6): the two calls produce nothing.
    XCTAssertNil([self waitForQueuedEventNamed:@"Deep Link Opened"]);
}

- (void)testHookCanRenameDropAndRaise {
    [gAnalytics trackEvent:@"Renamed" properties:@{@"original": @YES}];
    [gAnalytics trackEvent:@"Dropped"];
    [gAnalytics trackEvent:@"Raises"];

    RBNEventUpdate *renamed = [self waitForQueuedEventNamed:@"Renamed By Hook"];
    XCTAssertNotNil(renamed);
    XCTAssertEqualObjects(((RBNTrackEvent *)renamed.event).properties[@"hooked"], @YES);
    XCTAssertEqualObjects(((RBNTrackEvent *)renamed.event).properties[@"original"], @YES);

    BOOL dropped = [self waitUntil:^BOOL {
        NSUInteger count = 0;
        @synchronized(gUpdates) {
            for (RBNEventUpdate *update in gUpdates) {
                if (update.kind == RBNEventUpdateKindDropped && update.dropReason == RBNDropReasonBeforeSend) count++;
            }
        }
        return count >= 2;
    }];
    XCTAssertTrue(dropped);
    BOOL logged = [self waitUntil:^BOOL {
        @synchronized(gLogLines) {
            for (NSString *line in gLogLines) {
                if ([line containsString:@"HOOK_THREW"] && [line containsString:@"RBNTestException"]) return YES;
            }
        }
        return NO;
    }];
    XCTAssertTrue(logged);
    @synchronized(gUpdates) {
        for (RBNEventUpdate *update in gUpdates) {
            if (update.kind == RBNEventUpdateKindDropped) {
                XCTAssertEqualObjects(update.dropReasonName, @"before_send");
                XCTAssertNil(update.event);
            }
        }
    }
}

- (void)testConsentAndReset {
    [gAnalytics optOut];
    XCTAssertTrue(gAnalytics.isOptedOut);
    [gAnalytics optIn];
    XCTAssertFalse(gAnalytics.isOptedOut);
    [gAnalytics reset];
    NSString *before = gAnalytics.deviceId;
    [gAnalytics clearLocalData];
    BOOL renewed = [self waitUntil:^BOOL { return ![gAnalytics.deviceId isEqualToString:before]; }];
    XCTAssertTrue(renewed);
}

- (void)testNetworkObserverCompilesAndForwards {
    RBNNetworkObserver *observer = [[RBNNetworkObserver alloc] initWithAnalytics:gAnalytics
                                                                            hosts:[NSSet setWithObject:@"api.example.com"]];
    RBNNetworkObserver *unmasked = [[RBNNetworkObserver alloc] initWithAnalytics:gAnalytics
                                                                            hosts:[NSSet setWithObject:@"*.example.com"]
                                                                      maskPathIds:NO];
    XCTAssertNotNil(unmasked);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:@"https://api.example.com/users/1"]];
    [observer URLSession:session task:task didCompleteWithError:nil];
    [session invalidateAndCancel];
}

#if __has_include(<UIKit/UIKit.h>)
- (void)testScreenNamedProtocolIsAClassMethod {
    XCTAssertTrue([RBNLegacyScreenViewController conformsToProtocol:@protocol(RBNScreenNamed)]);
    XCTAssertTrue([RBNLegacyScreenViewController respondsToSelector:@selector(rbnScreenName)]);
    XCTAssertEqualObjects([RBNLegacyScreenViewController rbnScreenName], @"legacy");
}
#endif

@end
