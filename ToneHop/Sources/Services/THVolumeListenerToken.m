#import "THVolumeListenerToken.h"

@implementation THVolumeListenerToken {
    AudioObjectID _object;
    AudioObjectPropertyAddress _address;
    dispatch_queue_t _queue;
    AudioObjectPropertyListenerBlock _listener;
    THVolumeListenerOperation _add;
    THVolumeListenerOperation _remove;
}

- (instancetype)initWithObject:(AudioObjectID)object
                       address:(AudioObjectPropertyAddress)address
                         queue:(dispatch_queue_t)queue
                      callback:(AudioObjectPropertyListenerBlock)callback {
    return [self initWithObject:object address:address queue:queue callback:callback
                  addOperation:^OSStatus(AudioObjectID oid, const AudioObjectPropertyAddress *property,
                                         dispatch_queue_t deliveryQueue, AudioObjectPropertyListenerBlock listener) {
        return AudioObjectAddPropertyListenerBlock(oid, property, deliveryQueue, listener);
    } removeOperation:^OSStatus(AudioObjectID oid, const AudioObjectPropertyAddress *property,
                                dispatch_queue_t deliveryQueue, AudioObjectPropertyListenerBlock listener) {
        return AudioObjectRemovePropertyListenerBlock(oid, property, deliveryQueue, listener);
    }];
}

- (instancetype)initWithObject:(AudioObjectID)object
                       address:(AudioObjectPropertyAddress)address
                         queue:(dispatch_queue_t)queue
                      callback:(AudioObjectPropertyListenerBlock)callback
                  addOperation:(THVolumeListenerOperation)addOperation
               removeOperation:(THVolumeListenerOperation)removeOperation {
    self = [super init];
    if (self) {
        _object = object;
        _address = address;
        _queue = queue;
        _listener = [callback copy];
        _add = [addOperation copy];
        _remove = [removeOperation copy];
    }
    return self;
}

- (OSStatus)registerListener { return _add(_object, &_address, _queue, _listener); }
- (OSStatus)removeListener { return _remove(_object, &_address, _queue, _listener); }
@end
