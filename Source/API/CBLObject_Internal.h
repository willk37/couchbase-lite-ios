//
//  CBLObject_Internal.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/17/14.
//
//

#import "CBLObject.h"
#import <objc/runtime.h>


/** Metadata about a persistent property defined by a CBLObject subclass. */
@interface CBLPropertyInfo : NSObject
{
@public
    Class definedInClass;       // Class that defines this property
    NSString* name;             // Property name
    NSString* docProperty;      // Document (JSON) property name
    objc_property_t property;   // Obj-C property metadata
    Ivar ivar;                  // Obj-C instance variable metadata
    const char* ivarType;       // Encoded ivar type string (a la @encode)
    uint8_t index;              // Order in which property was declared (starts at 0 in base class)
    BOOL readOnly;              // Read-only property?

@private
    Class _propertyClass;       // Property's class, if it's an object type
}

@property (readonly) Class propertyClass;

@end




@interface CBLObject ()
{
    @protected
    Class _realClass; // used only by CBLFault
}

+ (NSArray*) persistentPropertyInfo;

+ (void) forEachProperty: (void (^)(CBLPropertyInfo*))block;

@property (readwrite) BOOL needsSave;
@property (readwrite, nonatomic) NSMutableDictionary* extraProperties;

#if DEBUG
@property (readonly) uint64_t dirtyFlags;
#endif

- (id) internalizeValue: (id)rawValue forProperty: (CBLPropertyInfo*)info;

- (void) setValue:(id)value forPersistentProperty: (CBLPropertyInfo*)prop;

- (void) turnIntoFault;
- (void) awokeFromFault;

@end



// A CBLObject subclass used to represent an object of a different class that hasn't yet had its
// data loaded. After the object's initializer finishes, its class is swizzled to CBLFault.
// CBLFault has a -forwardInvocation: method that handles any unknown method (i.e. one declared
// by the real class) by switching the object back to its real class and loading its data.
@interface CBLFault : CBLObject
- (BOOL) isReallyKindOfClass: (Class)klass;
@end
