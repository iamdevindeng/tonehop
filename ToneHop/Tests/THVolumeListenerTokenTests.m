#import <XCTest/XCTest.h>
#import "../Sources/Services/THVolumeListenerToken.h"

/// These operations replace both HAL functions. All block comparisons happen
/// on the Objective-C side of the ABI, where they compare the native objects
/// actually submitted for registration and removal.
@interface THVolumeListenerTokenTests : XCTestCase
@end

@implementation THVolumeListenerTokenTests

- (void)testCopiedCallbackAndRegistrationTupleStayStableAcrossRemovalRetry {
    AudioObjectID object = 41;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0
    };
    AudioObjectPropertyAddress originalAddress = address;
    dispatch_queue_t queue = dispatch_queue_create("test.volume.native-listener", DISPATCH_QUEUE_SERIAL);
    __block NSUInteger adds = 0;
    __block NSUInteger removes = 0;
    __block NSUInteger callbacks = 0;
    __block AudioObjectPropertyListenerBlock installedBlock = nil;
    AudioObjectPropertyListenerBlock callback = ^(UInt32 count, const AudioObjectPropertyAddress *changed) {
        XCTAssertEqual(count, 1u);
        XCTAssertEqual(changed->mSelector, originalAddress.mSelector);
        callbacks += 1;
    };
    THVolumeListenerOperation add = ^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                                            dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
        adds += 1;
        XCTAssertEqual(value, object);
        XCTAssertEqual(property->mSelector, originalAddress.mSelector);
        XCTAssertEqual(property->mScope, originalAddress.mScope);
        XCTAssertEqual(property->mElement, originalAddress.mElement);
        XCTAssertTrue(submittedQueue == queue);
        installedBlock = [block copy];
        return noErr;
    };
    THVolumeListenerOperation remove = ^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                                               dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
        removes += 1;
        XCTAssertEqual(value, object);
        XCTAssertEqual(property->mSelector, originalAddress.mSelector);
        XCTAssertEqual(property->mScope, originalAddress.mScope);
        XCTAssertEqual(property->mElement, originalAddress.mElement);
        XCTAssertTrue(submittedQueue == queue);
        XCTAssertTrue(block == installedBlock, @"Every retry must pass the original native block object.");
        return removes == 1 ? -701 : noErr;
    };
    THVolumeListenerToken *token = [[THVolumeListenerToken alloc]
        initWithObject:object address:address queue:queue callback:callback addOperation:add removeOperation:remove];
    callback = nil;
    address.mSelector = kAudioDevicePropertyMute;
    address.mElement = 2;
    XCTAssertEqual(adds, 0u, @"Constructing a token must not register with HAL.");
    XCTAssertEqual(removes, 0u);

    XCTAssertEqual([token registerListener], noErr);
    XCTAssertNotNil(installedBlock);
    installedBlock(1, &originalAddress);
    XCTAssertEqual(callbacks, 1u, @"The token must retain a copied, callable callback.");
    XCTAssertEqual([token removeListener], -701);
    XCTAssertEqual([token removeListener], noErr);
    XCTAssertEqual(adds, 1u, @"A failed removal never re-registers.");
    XCTAssertEqual(removes, 2u);
}

- (void)testFailedRegistrationRetryStillUsesTheSameNativeBlock {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, 1
    };
    dispatch_queue_t queue = dispatch_queue_create("test.volume.native-listener.retry", DISPATCH_QUEUE_SERIAL);
    __block NSUInteger adds = 0;
    __block NSUInteger removes = 0;
    __block NSUInteger callbacks = 0;
    __block AudioObjectPropertyListenerBlock firstBlock = nil;
    THVolumeListenerToken *token = [[THVolumeListenerToken alloc]
        initWithObject:42 address:address queue:queue
        callback:^(UInt32 count, const AudioObjectPropertyAddress *changed) { callbacks += count; }
        addOperation:^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                               dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
            adds += 1;
            if (firstBlock == nil) firstBlock = [block copy];
            else XCTAssertTrue(block == firstBlock);
            return adds == 1 ? -702 : noErr;
        }
        removeOperation:^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                                  dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
            removes += 1;
            XCTAssertTrue(block == firstBlock);
            return noErr;
        }];

    XCTAssertEqual([token registerListener], -702);
    XCTAssertEqual([token registerListener], noErr);
    firstBlock(1, &address);
    XCTAssertEqual(callbacks, 1u);
    XCTAssertEqual([token removeListener], noErr);
    XCTAssertEqual(adds, 2u);
    XCTAssertEqual(removes, 1u);
}

- (void)testSeparateTokensDoNotShareCallbackIdentity {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0
    };
    dispatch_queue_t queue = dispatch_queue_create("test.volume.native-listener.separate", DISPATCH_QUEUE_SERIAL);
    __block NSUInteger firstCalls = 0;
    __block NSUInteger secondCalls = 0;
    __block AudioObjectPropertyListenerBlock firstBlock = nil;
    __block AudioObjectPropertyListenerBlock secondBlock = nil;
    THVolumeListenerToken *first = [[THVolumeListenerToken alloc]
        initWithObject:41 address:address queue:queue
        callback:^(UInt32 count, const AudioObjectPropertyAddress *changed) { firstCalls += count; }
        addOperation:^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                               dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
            firstBlock = [block copy]; return noErr;
        }
        removeOperation:^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                                  dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
            XCTAssertTrue(block == firstBlock); XCTAssertTrue(block != secondBlock); return noErr;
        }];
    THVolumeListenerToken *second = [[THVolumeListenerToken alloc]
        initWithObject:42 address:address queue:queue
        callback:^(UInt32 count, const AudioObjectPropertyAddress *changed) { secondCalls += count; }
        addOperation:^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                               dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
            secondBlock = [block copy]; return noErr;
        }
        removeOperation:^OSStatus(AudioObjectID value, const AudioObjectPropertyAddress *property,
                                  dispatch_queue_t submittedQueue, AudioObjectPropertyListenerBlock block) {
            XCTAssertTrue(block == secondBlock); XCTAssertTrue(block != firstBlock); return noErr;
        }];

    XCTAssertEqual([first registerListener], noErr);
    XCTAssertEqual([second registerListener], noErr);
    XCTAssertTrue(firstBlock != secondBlock);
    firstBlock(1, &address);
    XCTAssertEqual(firstCalls, 1u);
    XCTAssertEqual(secondCalls, 0u);
    secondBlock(2, &address);
    XCTAssertEqual(firstCalls, 1u);
    XCTAssertEqual(secondCalls, 2u);
    XCTAssertEqual([first removeListener], noErr);
    XCTAssertEqual([second removeListener], noErr);
}
@end
