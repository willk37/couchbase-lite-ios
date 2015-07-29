//
//  CBLInterface.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 2/18/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import "MYDynamicObject.h"


/** Base interface for use with the CBLInterface class. */
@protocol CBLInterface

// Supports subscript-style access to arbitrary named properties:
- (id) objectForKeyedSubscript: (NSString*)key;
- (void) setObject: (id)object forKeyedSubscript: (NSString*)key;

/** Removes all properties, i.e. resets the underlying object to an empty dictionary. */
- (void) erase;

/** A JSON-compatible dictionary of all the object's properties. */
@property (copy) NSDictionary* $allProperties;

@end



@interface CBLInterface : MYDynamicObject <CBLInterface>

/** Returns an object implementing the given protocol, whose property values are based on the
    contents of the NSDictionary. The dictionary is read-only, so even if the protocol declares
    settable properties, attempting to set them will just raise an exception. */
+ (id) accessObject: (NSDictionary*)object
    throughProtocol: (Protocol*)protocol;

/** Returns an object implementing the given protocol, whose property values are based on the
    contents of the NSMutableDictionary. Setting properties of the object will update the
    values of the corresponding dictionary keys. */
+ (id) accessMutableObject: (NSMutableDictionary*)object
           throughProtocol: (Protocol*)protocol;

/** Returns an object implementing the given protocol, backed by an empty mutable dictionary. */
+ (id) mutableInstanceOfProtocol: (Protocol*)protocol;

// internal use only
+ (NSDictionary*) propertyInfo;
- (instancetype) initWithObject:(NSDictionary *)object mutable: (BOOL)mutable;

@end
