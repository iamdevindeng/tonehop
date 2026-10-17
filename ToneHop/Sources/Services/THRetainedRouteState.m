#import "THRetainedRouteState.h"

void THRReleaseOperation(THROperation *operation) {
    if (!operation || atomic_fetch_sub(&operation->references, 1) != 1) return;
    CFRelease(operation->aggregate); CFRelease(operation->leaf);
    CFRelease(operation->context); CFRelease(operation->manager); free(operation);
}
void THRComplete(CFTypeRef aggregate, CFTypeRef leaf, uint64_t word2, uint64_t word3, SInt32 status, void *refcon) {
    (void)word2; (void)word3;
    THROperation *operation = refcon;
    atomic_store(&operation->objectsMatch, aggregate == operation->aggregate && leaf == operation->leaf);
    atomic_store(&operation->status, status);
    atomic_store(&operation->done, true);
    THRReleaseOperation(operation);
}
THROperation *THRNewOperation(CFTypeRef aggregate, CFTypeRef leaf, CFTypeRef context, CFTypeRef manager) {
    THROperation *operation = calloc(1, sizeof(*operation));
    if (!operation) return NULL;
    atomic_init(&operation->references, 2); atomic_init(&operation->done, false);
    atomic_init(&operation->objectsMatch, false); atomic_init(&operation->status, INT32_MIN);
    operation->aggregate = CFRetain(aggregate); operation->leaf = CFRetain(leaf);
    operation->context = CFRetain(context); operation->manager = CFRetain(manager);
    return operation;
}

@implementation THRetainedRouteSession
- (void)adoptContext:(CFTypeRef)context { if (_context) CFRelease(_context); _context = context; }
- (void)adoptManager:(CFTypeRef)manager { if (_manager) CFRelease(_manager); _manager = manager; }
- (void)adoptAggregate:(CFTypeRef)aggregate leaf:(CFTypeRef)leaf {
    [self releaseCapture]; _aggregate = aggregate; _leaf = leaf;
}
- (void)copyReferencesFrom:(THRetainedRouteSession *)other {
    if (other == self) return;
    [self releaseAll];
    _context = other.context ? CFRetain(other.context) : NULL;
    _manager = other.manager ? CFRetain(other.manager) : NULL;
    _aggregate = other.aggregate ? CFRetain(other.aggregate) : NULL;
    _leaf = other.leaf ? CFRetain(other.leaf) : NULL;
    _contextID = [other.contextID copy]; _aggregateID = [other.aggregateID copy];
    _identifier = [other.identifier copy]; _name = [other.name copy];
    _captureStreamUID = [other.captureStreamUID copy];
}
- (void)releaseCapture {
    if (_aggregate) CFRelease(_aggregate); if (_leaf) CFRelease(_leaf);
    _aggregate = NULL; _leaf = NULL;
    _aggregateID = nil; _contextID = nil; _identifier = nil; _name = nil; _captureStreamUID = nil;
}
- (void)releaseAll {
    [self releaseCapture];
    if (_context) CFRelease(_context); if (_manager) CFRelease(_manager);
    _context = NULL; _manager = NULL;
}
- (void)dealloc { [self releaseAll]; }
@end

@implementation THOwnedRouteTransaction
- (BOOL)removeAttempted { return self.removePhase != THRetainedRemovePhaseNotAttempted; }
- (BOOL)removeSubmissionFailed { return self.removePhase == THRetainedRemovePhaseSubmissionFailed; }
- (void)forgetRouteIdentity { self.ownStreamUID = nil; self.returnLocalUID = nil; }
- (void)clear {
    THRReleaseOperation(_add); THRReleaseOperation(_remove); _add = NULL; _remove = NULL;
    _owned = NO; _mustClean = NO; [self forgetRouteIdentity];
    _removePhase = THRetainedRemovePhaseNotAttempted; _removeSubmittedAt = 0;
}
- (void)dealloc { THRReleaseOperation(_add); THRReleaseOperation(_remove); }
@end
