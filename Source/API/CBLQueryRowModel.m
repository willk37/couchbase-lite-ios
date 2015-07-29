//
//  CBLQueryRowModel.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 9/26/14.
//
//

#import "CBLQueryRowModel.h"
#import "CBLObject_Internal.h"
#import "CBLQuery.h"


@interface CBLQueryRowModelMetadata : NSObject
{
    @public
    CBLPropertyInfo* keyProperty;   // Info for property representing entire key
    NSDictionary* keyProperties;    // Maps @# --> info for property representing item of key array
    CBLPropertyInfo* valueProperty; // Info for property representing entire value
    NSDictionary* valueProperties;  // Info for properties representing items of value array/dict
}
@end

@implementation CBLQueryRowModelMetadata
@end




@implementation CBLQueryRowModel

@synthesize row=_row;


static NSMutableDictionary* sMetadata;


+ (void) initialize {
    [super initialize];
    
    if (self == [CBLQueryRowModel class]) {
        sMetadata = [NSMutableDictionary new];
    } else {
        // Analyze the instance properties and figure out how they correspond to the key/value:
        CBLQueryRowModelMetadata* metadata = [CBLQueryRowModelMetadata new];
        NSMutableDictionary* keyProperties = [NSMutableDictionary new];
        NSMutableDictionary* valueProperties = [NSMutableDictionary new];
        for (CBLPropertyInfo* info in [self persistentPropertyInfo]) {
            NSString* docProperty = info->docProperty;
            if ([docProperty isEqualToString: @"key"]) {
                metadata->keyProperty = info;
            } else if ([docProperty hasPrefix: @"key"]) {
                NSInteger index = [[docProperty substringFromIndex: 3] integerValue];
                keyProperties[@(index)] = info;
            } else if ([docProperty isEqualToString: @"value"]) {
                metadata->valueProperty = info;
            } else if ([docProperty hasPrefix: @"value"]) {
                NSInteger index = [[docProperty substringFromIndex: 3] integerValue];
                valueProperties[@(index)] = info;
            } else {
                valueProperties[docProperty] = info;
            }
        }
        if (keyProperties.count > 0)
            metadata->keyProperties = keyProperties;
        if (valueProperties.count > 0)
            metadata->valueProperties = valueProperties;
        @synchronized(sMetadata) {
            sMetadata[(id)self] = metadata;
        }
    }
}


+ (CBLQueryRowModelMetadata*) propertyMetadata {
    @synchronized(sMetadata) {
        return sMetadata[(id)self];
    }
}


- (instancetype) initWithQueryRow: (CBLQueryRow*)row {
    self = [super init];
    if (self) {
        _row = row;
        [self turnIntoFault];  // Avoid doing any work until/unless my properties are accessed
    }
    return self;
}


- (void) awokeFromFault {
    CBLQueryRowModelMetadata* meta = [[self class] propertyMetadata];
    id key = _row.key;
    // Set "key" property:
    if (meta->keyProperty)
        [self setValue: key forPersistentProperty: meta->keyProperty];
    NSInteger index = 0;
    for (id keyItem in $castIf(NSArray, key)) {
        // Set "key#" properties:
        CBLPropertyInfo* info = meta->keyProperties[@(index++)];
        if (info)
            [self setValue: keyItem forPersistentProperty: info];
    }

    id value = _row.value;
    if (value) {
        // Set "value" property:
        if (meta->valueProperty)
            [self setValue: value forPersistentProperty: meta->valueProperty];
        index = 0;
        for (id valueItem in $castIf(NSArray, value)) {
            // Set "value#" properties:
            CBLPropertyInfo* info = meta->valueProperties[@(index++)];
            if (info)
                [self setValue: valueItem forPersistentProperty: info];
        }
        for (id valueProp in $castIf(NSDictionary, value)) {
            // Set other properties, named after keys in value dict:
            CBLPropertyInfo* info = meta->valueProperties[valueProp];
            if (info)
                [self setValue: [value objectForKey: valueProp] forPersistentProperty: info];
        }
    }
}


@end
