@import XCTest;
@import RubiconObjC;

/// Objective-C test target in SwiftPM (D16). Compiling this file against the wrapper module is half
/// the test (iOS Public API 1); the wrapper's own tests arrive in step 7.7.
@interface RBNTargetTests : XCTestCase
@end

@implementation RBNTargetTests

- (void)testModuleImports {
    XCTAssertTrue(YES);
}

@end
