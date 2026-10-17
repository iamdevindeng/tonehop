#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// The operations stay in Objective-C so the same native block, rather than a
/// freshly bridged Swift closure, reaches both Core Audio calls.
typedef OSStatus (^THVolumeListenerOperation)(AudioObjectID object,
                                            const AudioObjectPropertyAddress *address,
                                            dispatch_queue_t queue,
                                            AudioObjectPropertyListenerBlock listener);

@interface THVolumeListenerToken : NSObject
- (instancetype)initWithObject:(AudioObjectID)object
                       address:(AudioObjectPropertyAddress)address
                         queue:(dispatch_queue_t)queue
                      callback:(AudioObjectPropertyListenerBlock)callback
    NS_SWIFT_NAME(init(object:address:queue:callback:));

/// Narrow native-call injection for identity/lifetime regression tests.
- (instancetype)initWithObject:(AudioObjectID)object
                       address:(AudioObjectPropertyAddress)address
                         queue:(dispatch_queue_t)queue
                      callback:(AudioObjectPropertyListenerBlock)callback
                  addOperation:(THVolumeListenerOperation)addOperation
               removeOperation:(THVolumeListenerOperation)removeOperation NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (OSStatus)registerListener;
- (OSStatus)removeListener;
@end

NS_ASSUME_NONNULL_END
