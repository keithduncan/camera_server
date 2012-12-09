//
//  VirtualFileSystem.m
//  FTP Server
//
//  Created by Keith Duncan on 07/08/2012.
//  Copyright (c) 2012 Keith Duncan. All rights reserved.
//

#import "AFInMemoryFileSystem.h"

#import <libkern/OSAtomic.h>
#import "CoreNetworking/CoreNetworking.h"

#import "AFVirtualFileSystemNode+AFVirtualFileSystemPrivate.h"

@interface _AFInMemoryFileSystemNode : NSObject <NSLocking>

- (id)initWithName:(NSString *)name nodeType:(AFVirtualFileSystemNodeType)nodeType;

@property (readonly, copy, nonatomic) NSString *name;
@property (readonly, assign, nonatomic) AFVirtualFileSystemNodeType nodeType;

@end

@implementation _AFInMemoryFileSystemNode {
	NSLock *_lock;
}

- (id)initWithName:(NSString *)name nodeType:(AFVirtualFileSystemNodeType)nodeType {
	self = [self init];
	if (self == nil) return nil;
	
	_name = [name copy];
	_nodeType = nodeType;
	
	_lock = [[NSLock alloc] init];
	
	return self;
}

- (void)dealloc {
	[_name release];
	[_lock release];
	
	[super dealloc];
}

- (void)lock {
	[_lock lock];
}

- (void)unlock {
	[_lock unlock];
}

@end

@interface _AFInMemoryFileSystemObject : _AFInMemoryFileSystemNode

- (id)initWithName:(NSString *)name data:(NSData *)data;

@property (readonly, retain, nonatomic) NSData *data;

@end

@implementation _AFInMemoryFileSystemObject

@synthesize data=_data;

- (id)initWithName:(NSString *)name data:(NSData *)data {
	self = [self initWithName:name nodeType:AFVirtualFileSystemNodeTypeObject];
	if (self == nil) return nil;
	
	_data = [data retain];
	
	return self;
}

@end

#pragma mark -

@interface _AFInMemoryFileSystemOutputStream : NSOutputStream

+ (id)outputStreamToFileSystem:(AFInMemoryFileSystem *)fileSystem updateRequest:(AFVirtualFileSystemRequestUpdate *)updateRequest;

@property (retain, nonatomic) AFInMemoryFileSystem *fileSystem;
@property (copy, nonatomic) AFVirtualFileSystemRequestUpdate *updateRequest;

@end

@implementation _AFInMemoryFileSystemOutputStream {
	NSMutableData *_data;
	
	NSStreamStatus _status;
	
	id <NSStreamDelegate> _delegate;
}

@synthesize fileSystem=_fileSystem;
@synthesize updateRequest=_updateRequest;

+ (id)outputStreamToFileSystem:(AFInMemoryFileSystem *)fileSystem updateRequest:(AFVirtualFileSystemRequestUpdate *)updateRequest {
	_AFInMemoryFileSystemOutputStream *stream = [[[self alloc] init] autorelease];
	stream.fileSystem = fileSystem;
	stream.updateRequest = updateRequest;
	return stream;
}

- (id)init {
	self = [super init];
	if (self == nil) {
		return nil;
	}
	
	_data = [[NSMutableData alloc] init];
	
	return self;
}

- (void)dealloc {
	[_fileSystem release];
	[_updateRequest release];
	
	[super dealloc];
}

- (void)open {
	NSParameterAssert(self.streamStatus == NSStreamStatusNotOpen);
	[self _setStatusAndNotify:NSStreamStatusOpen];
	
#warning should we increment the operation count of the file system here instead of in the perform request method?
}

- (void)close {
	if (self.streamStatus == NSStreamStatusOpen) {
#warning perform the data swap in the file system
		
#warning decrement the transaction count of the file system too
	}
	
	[self _setStatusAndNotify:NSStreamStatusClosed];
}

- (id <NSStreamDelegate>)delegate {
	return _delegate;
}

- (void)setDelegate:(id <NSStreamDelegate>)delegate {
	_delegate = (delegate ? : (id)self);
}

- (void)_setStatusAndNotify:(NSStreamStatus)status {
	_status = status;
	
	if (![self.delegate respondsToSelector:@selector(stream:handleEvent:)]) {
		return;
	}
	
	struct StatusToEvent {
		NSStreamStatus status;
		NSStreamEvent event;
	} statusToEventMap[] = {
		{ .status = NSStreamStatusOpen, .event = NSStreamEventOpenCompleted },
		{ .status = NSStreamStatusAtEnd, .event = NSStreamEventEndEncountered },
		{ .status = NSStreamStatusError, .event = NSStreamEventErrorOccurred },
	};
	for (NSUInteger idx = 0; idx < sizeof(statusToEventMap)/sizeof(*statusToEventMap); idx++) {
		if (statusToEventMap[idx].status != status) {
			continue;
		}
		
		[self.delegate stream:self handleEvent:statusToEventMap[idx].event];
		break;
	}
}

- (id)propertyForKey:(NSString *)key {
	return nil;
}

- (BOOL)setProperty:(id)property forKey:(NSString *)key {
	return NO;
}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode {
	//nop
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode {
	//nop
}

- (NSStreamStatus)streamStatus {
	return _status;
}

- (NSError *)streamError {
	return nil;
}

- (BOOL)hasSpaceAvailable {
	return YES;
}

- (NSInteger)write:(uint8_t const *)buffer maxLength:(NSUInteger)maxLength {
	[_data appendBytes:buffer length:maxLength];
	return maxLength;
}

@end

#pragma mark -

@interface AFInMemoryFileSystem ()
@property (assign, nonatomic) CFTreeRef treeRoot;
@property (assign, nonatomic) int64_t pendingTransactionCount;
@end

@implementation AFInMemoryFileSystem

static CFTreeContext const _AFInMemoryFileSystemTreeContext = {
	.retain = CFRetain,
	.release = CFRelease,
	.copyDescription = CFCopyDescription,
};

@synthesize treeRoot=_treeRoot;

- (id)init {
	self = [super init];
	if (self == nil) return nil;
	
	CFTreeContext treeRootContext = _AFInMemoryFileSystemTreeContext;
	treeRootContext.info = [[[_AFInMemoryFileSystemNode alloc] initWithName:@"/" nodeType:AFVirtualFileSystemNodeTypeContainer] autorelease];
	_treeRoot = CFTreeCreate(kCFAllocatorDefault, &treeRootContext);
	
	_pendingTransactionCount = -1;
	
	return self;
}

- (void)dealloc {
	CFRelease(_treeRoot);
	
	[super dealloc];
}

- (BOOL)_tryMount {
	/*
		Note
		
		the file system must be unmounted for mounting to succeed
	 */
	return OSAtomicCompareAndSwap64Barrier(-1, 0, &_pendingTransactionCount);
}

- (BOOL)mount:(NSError **)errorRef {
	if (![self _tryMount]) {
		if (errorRef != NULL) {
			NSDictionary *errorInfo = @{
				NSLocalizedDescriptionKey : NSLocalizedString(@"Cannot mount while already mounted", @"AFInMemoryFileSystem mount from unknown state error description"),
			};
			*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeBusy userInfo:errorInfo];
		}
		return NO;
	}
	return YES;
}

- (BOOL)_tryUnmount {
	/*
		Note
		
		there must be 0 outstanding transactions for unmounting to succeed
	 */
	return OSAtomicCompareAndSwap64Barrier(0, -1, &_pendingTransactionCount);
}

- (BOOL)unmount:(NSError **)errorRef {
	if (![self _tryUnmount]) {
		if (errorRef != NULL) {
			NSDictionary *errorInfo = @{
				NSLocalizedDescriptionKey : NSLocalizedString(@"Cannot unmount while node operations are pending", @"AFInMemoryFileSystem unmount pending transactions error description"),
			};
			*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeBusy userInfo:errorInfo];
		}
		return NO;
	}
	
	return YES;
}

- (BOOL)_tryIncreasePendingTransactionCount {
	int64_t volatile *pendingTransactionCountRef = &_pendingTransactionCount;
	while (1) {
		int64_t pendingTransactionCount = *pendingTransactionCountRef;
		if (pendingTransactionCount == -1) {
			return NO;
		}
		
		bool swap = OSAtomicCompareAndSwap64Barrier(pendingTransactionCount, pendingTransactionCount + 1, pendingTransactionCountRef);
		if (!swap) {
			continue;
		}
		
		return YES;
	}
}

- (void)_decrementPendingTransactionCount {
	OSAtomicDecrement64Barrier(&_pendingTransactionCount);
}

static id _AFTreeGetInfo(CFTreeRef node) {
	CFTreeContext context = {};
	CFTreeGetContext(node, &context);
	return [[(id)context.info retain] autorelease];
}

- (CFTreeRef)_childOfLockedNode:(CFTreeRef)root withPathComponent:(NSString *)pathComponent CF_RETURNS_RETAINED {
	CFTreeRef child = NULL;
	NSUInteger childCount = CFTreeGetChildCount(root);
	for (NSUInteger idx = 0; idx < childCount; idx++) {
		CFTreeRef currentChild = CFTreeGetChildAtIndex(root, idx);
		
		_AFInMemoryFileSystemNode *node = _AFTreeGetInfo(currentChild);
		if (![node.name isEqualToString:pathComponent]) {
			continue;
		}
		
		child = currentChild;
	}
	
	if (child != NULL) {
		CFRetain(child);
	}
	
	return child;
}

- (CFTreeRef)_childOfNode:(CFTreeRef)root withPathComponent:(NSString *)pathComponent CF_RETURNS_RETAINED {
	_AFInMemoryFileSystemNode *rootNode = _AFTreeGetInfo(root);
	[rootNode lock];
	
	CFTreeRef child = [self _childOfLockedNode:root withPathComponent:pathComponent];
	
	[rootNode unlock];
	return child;
}

- (CFTreeRef)_childOfNode:(CFTreeRef)root withPath:(NSString *)path CF_RETURNS_RETAINED {
	CFTreeRef currentNode = NULL;
	for (NSString *currentPathComponent in [path pathComponents]) {
		CFTreeRef newNode = [self _childOfNode:(currentNode ? : root) withPathComponent:currentPathComponent];
		
		if (currentNode != NULL) {
			CFRelease(currentNode);
			currentNode = NULL;
		}
		
		if (newNode == NULL) {
			break;
		}
		
		currentNode = newNode;
	}
	
	return currentNode;
}

- (CFTreeRef)_nodeWithPath:(NSString *)path CF_RETURNS_RETAINED {
	NSArray *pathComponents = [path pathComponents];
	if ([pathComponents count] == 0) {
		return NULL;
	}
	
	if (![pathComponents[0] isEqualToString:@"/"]) {
		return NULL;
	}
	
	CFTreeRef root = self.treeRoot;
	if ([pathComponents count] == 1) {
		return (CFTreeRef)CFRetain(root);
	}
	else {
		NSString *subpath = [[pathComponents subarrayWithRange:NSMakeRange(1, [pathComponents count] - 1)] componentsJoinedByString:@"/"];
		return [self _childOfNode:root withPath:subpath];
	}
}

- (CFTreeRef)_containerWithPath:(NSString *)path error:(NSError **)errorRef CF_RETURNS_RETAINED {
	CFTreeRef container = (CFTreeRef)[(id)[self _nodeWithPath:path] autorelease];
	if (container == NULL) {
		if (errorRef != NULL) {
			*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNoNodeExists userInfo:nil];
		}
		return NULL;
	}
	
	_AFInMemoryFileSystemNode *containerNode = _AFTreeGetInfo(container);
	if (containerNode.nodeType != AFVirtualFileSystemNodeTypeContainer) {
		if (errorRef != NULL) {
			*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNotContainer userInfo:nil];
		}
		return NULL;
	}
	
	return container;
}

- (CFTreeRef)_objectWithPath:(NSString *)path error:(NSError **)errorRef CF_RETURNS_RETAINED {
	NSString *containerPath = [path stringByDeletingLastPathComponent];
	CFTreeRef container = (CFTreeRef)[(id)[self _containerWithPath:containerPath error:errorRef] autorelease];
	if (container == NULL) {
		return NULL;
	}
	
	NSString *objectName = [path lastPathComponent];
	CFTreeRef object = (CFTreeRef)[(id)[self _childOfNode:container withPathComponent:objectName] autorelease];
	if (object == NULL) {
		if (errorRef != NULL) {
			*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNoNodeExists userInfo:nil];
		}
		return NULL;
	}
	
	_AFInMemoryFileSystemObject *objectNode = _AFTreeGetInfo(object);
	if (objectNode.nodeType != AFVirtualFileSystemNodeTypeObject) {
		if (errorRef != NULL) {
			*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNotObject userInfo:nil];
		}
		return NULL;
	}
	
	return object;
}

#warning ensure we can create and update child object nodes of the root node

- (id)executeRequest:(AFVirtualFileSystemRequest *)request error:(NSError **)errorRef {
	if ([request isKindOfClass:[AFVirtualFileSystemRequestCreate class]]) {
		AFVirtualFileSystemRequestCreate *createRequest = (id)request;
		NSString *createPath = createRequest.path;
		
		NSString *containerPath = [createPath stringByDeletingLastPathComponent];
		CFTreeRef container = [self _containerWithPath:containerPath error:errorRef];
		if (container == NULL) {
			if (errorRef != NULL) {
				*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNoNodeExists userInfo:nil];
			}
			return nil;
		}
		
		_AFInMemoryFileSystemNode *containerNode = _AFTreeGetInfo(container);
		
		/*
			Note
			
			container lock taken to atomically search for a node with matching `nodeName` and create if absent
			
			mutual exclusion prevents concurrent callers from simultaneously creating a node with `nodeName` in the same container
		 */
		[containerNode lock];
		
		NSString *objectName = [createPath lastPathComponent];
		CFTreeRef existingChild = (CFTreeRef)[(id)[self _childOfLockedNode:container withPathComponent:objectName] autorelease];
		if (existingChild != NULL) {
			[containerNode unlock];
			
			_AFInMemoryFileSystemNode *existingChildNode = _AFTreeGetInfo(existingChild);
			
			if (errorRef != NULL) {
				if (existingChildNode.nodeType == createRequest.nodeType) {
					*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNodeExists userInfo:nil];
				}
				else if (existingChildNode.nodeType == AFVirtualFileSystemNodeTypeObject) {
					*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNotContainer userInfo:nil];
				}
				else if (existingChildNode.nodeType == AFVirtualFileSystemNodeTypeContainer) {
					*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeNotObject userInfo:nil];
				}
				else {
					*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeUnknown userInfo:nil];
				}
			}
			return nil;
		}
		
		CFTreeContext newChildContext = _AFInMemoryFileSystemTreeContext;
		newChildContext.info = [[[_AFInMemoryFileSystemNode alloc] initWithName:objectName nodeType:createRequest.nodeType] autorelease];
		CFTreeRef newChild = (CFTreeRef)[(id)CFTreeCreate(kCFAllocatorDefault, &newChildContext) autorelease];
		
		CFTreeAppendChild(container, newChild);
		
		[containerNode unlock];
		
		return [[[AFVirtualFileSystemNode alloc] initWithAbsolutePath:createPath nodeType:createRequest.nodeType] autorelease];
	}
	
	if ([request isKindOfClass:[AFVirtualFileSystemRequestRead class]]) {
		AFVirtualFileSystemRequestRead *readRequest = (id)request;
		NSString *readPath = readRequest.path;
		
		CFTreeRef object = (CFTreeRef)[(id)[self _objectWithPath:readPath error:errorRef] autorelease];
		if (object == NULL) {
			return nil;
		}
		
		_AFInMemoryFileSystemObject *objectNode = _AFTreeGetInfo(object);
		
		return [NSInputStream inputStreamWithData:objectNode.data];
	}
	
	if ([request isKindOfClass:[AFVirtualFileSystemRequestList class]]) {
		AFVirtualFileSystemRequestList *listRequest = (id)request;
		NSString *listPath = listRequest.path;
		
		CFTreeRef container = (CFTreeRef)[(id)[self _containerWithPath:listPath error:errorRef] autorelease];
		if (container == NULL) {
			return nil;
		}
		
		_AFInMemoryFileSystemNode *containerNode = _AFTreeGetInfo(container);
		[containerNode lock];
		
		NSUInteger childCount = CFTreeGetChildCount(container);
		
		NSMutableSet *children = [NSMutableSet setWithCapacity:childCount];
		for (NSUInteger childIdx = 0; childIdx < childCount; childIdx++) {
			CFTreeRef currentChild = CFTreeGetChildAtIndex(container, childIdx);
			_AFInMemoryFileSystemNode *currentChildNode = _AFTreeGetInfo(currentChild);
			
			NSString *absolutePath = [listPath stringByAppendingPathComponent:currentChildNode.name];
			AFVirtualFileSystemNode *fullNode = [[[AFVirtualFileSystemNode alloc] initWithAbsolutePath:absolutePath nodeType:currentChildNode.nodeType] autorelease];
			[children addObject:fullNode];
		}
		
		[containerNode unlock];
		
		return children;
	}
	
	if ([request isKindOfClass:[AFVirtualFileSystemRequestUpdate class]]) {
		AFVirtualFileSystemRequestUpdate *updateRequest = (id)request;
		NSString *updatePath = updateRequest.path;
		
		CFTreeRef object = (CFTreeRef)[(id)[self _objectWithPath:updatePath error:errorRef] autorelease];
		if (object == NULL) {
			return nil;
		}
		
		NSParameterAssert([self _tryIncreasePendingTransactionCount]);
#warning we should track 'open' child nodes in the parent directory node so that we can prevent them from being deleted
		
		return [_AFInMemoryFileSystemOutputStream outputStreamToFileSystem:self updateRequest:updateRequest];
	}
	
	if (errorRef != NULL) {
		NSDictionary *errorInfo = @{
			NSLocalizedDescriptionKey : NSLocalizedStringFromTableInBundle(@"Cannot process file system request", nil, [NSBundle mainBundle], @"AFInMemoryFileSystem unknown request type error description"),
		};
		*errorRef = [NSError errorWithDomain:AFVirtualFileSystemErrorDomain code:AFVirtualFileSystemErrorCodeUnknown userInfo:errorInfo];
	}
	return nil;
}

@end