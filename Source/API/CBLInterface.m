//
//  CBLInterface.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 2/18/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import "CBLInterface.h"
#import "ValueConverter.h"
#import <objc/runtime.h>


@implementation CBLInterface
{
    BOOL _mutable;
}

@synthesize $allProperties=_object;


static NSMutableDictionary* sImplementations;   // Maps protocol name -> Class
static NSMutableDictionary* sPropertyInfo;      // Maps class name -> NSDictionary(property->info)

+ (void)initialize
{
    if (self == [CBLInterface class]) {
        sImplementations = [NSMutableDictionary dictionary];
        sPropertyInfo = [NSMutableDictionary dictionary];
        [self setPropertyInfo: @{}];
    }
}


+ (id) accessObject: (NSDictionary*)object
    throughProtocol: (Protocol*)protocol
{
    Class klass = [self classForProtocol: protocol];
    return [[klass alloc] initWithObject: object mutable: NO];
}


+ (id) accessMutableObject: (NSMutableDictionary*)object
           throughProtocol: (Protocol*)protocol
{
    Class klass = [self classForProtocol: protocol];
    return [[klass alloc] initWithObject: object mutable: YES];
}


+ (id) mutableInstanceOfProtocol: (Protocol*)protocol {
    return [self accessMutableObject: [NSMutableDictionary dictionary] throughProtocol: protocol];
}


+ (Class) existingClassForProtocol: (Protocol*)protocol {
    @synchronized(sImplementations) {
        return sImplementations[NSStringFromProtocol(protocol)];
    }
}


+ (Class) classForProtocol: (Protocol*)protocol {
    NSString* protoName = NSStringFromProtocol(protocol);
    Class klass;
    @synchronized(sImplementations) {
        klass = sImplementations[protoName];
        if (!klass) {
            klass = [self createClass: protocol];
            NSAssert(klass, @"Couldn't create CBLInterface from protocol %@", protocol);
            sImplementations[protoName] = klass;
        }
    }
    return klass;
}


+ (NSDictionary*) propertyInfo {
    @synchronized(sPropertyInfo) {
        return sPropertyInfo[NSStringFromClass(self)];
    }
}

+ (void) setPropertyInfo: (NSDictionary*)info {
    @synchronized(sPropertyInfo) {
        sPropertyInfo[NSStringFromClass(self)] = [info copy];
    }
}


#pragma mark - MAGIC CLASS SYNTHESIS:


+ (Class) createClass: (Protocol*)protocol {
    // Class's superclass will be based on protocol's parent protocol; specifically, the first
    // parent protocol that inherits from CBLInterface:
    __block Protocol* parentProtocol = nil;
    __block Class parentClass = Nil;
    forEachParent(protocol, ^(Protocol* parent) {
        if (protocol_conformsToProtocol(parent, @protocol(CBLInterface))) {
            if (parent == @protocol(CBLInterface))
                parentClass = self;
            else
                parentClass = [self classForProtocol: parent];  // May create the parent class!
            parentProtocol = parent;
            return NO; // found parent, so stop
        } else {
            return YES;
        }
    });
    NSAssert(parentClass, @"Protocol %@ does not conform to CBLInterface",
             NSStringFromProtocol(protocol));

    // Create the class:
    NSString* className = [NSStringFromProtocol(protocol) stringByAppendingString: @"__Synth"];
    Log(@"Creating class %@ subclassing %@", className, parentClass);
    Class klass = objc_allocateClassPair(parentClass, className.UTF8String, 0);
    if (!klass)
        return Nil;
    class_addProtocol(klass, protocol);

    // Add the protocol's properties to the class:
    NSMutableDictionary* propertyInfo = [[parentClass propertyInfo] mutableCopy];
    copyProperties(klass, protocol, [NSMutableArray arrayWithObject: parentProtocol], propertyInfo);

    objc_registerClassPair(klass);
    [klass setPropertyInfo: propertyInfo];
    return klass;
}


// Copies properties of `protocol` into `klass`, including properties introduced in parent
// protocols that descend from CBLInterface. Ignores protocols found in the array `skip`.
static BOOL copyProperties(Class klass, Protocol* protocol, NSMutableArray* skip,
                           NSMutableDictionary* propertyInfo) {
    if (protocol == @protocol(CBLInterface) || [skip containsObject: protocol])
        return YES; // no-op

    // First copy parent-defined properties:
    __block BOOL inheritsFromCBLInterface = NO;
    forEachParent(protocol, ^(Protocol *parent) {
            if (copyProperties(klass, parent, skip, propertyInfo))
                inheritsFromCBLInterface = YES;
        return YES;
    });
    if (!inheritsFromCBLInterface)
        return NO; // `protocol` doesn't inherit from CBLInterface

    // Now copy mine:
    objc_property_t* props = protocol_copyPropertyList(protocol, NULL);
    for (objc_property_t* prop = props; prop && *prop; ++prop) {
        const char* name = property_getName(*prop);
        Log(@"    %s.%s -> %s", protocol_getName(protocol), name, property_getAttributes(*prop));
        unsigned nAttrs;
        objc_property_attribute_t* attrs = property_copyAttributeList(*prop, &nAttrs);
        class_addProperty(klass, name, attrs, nAttrs);
        free(attrs);

        NSString* attrStr =  @(property_getAttributes(*prop));
        if (protocol_getProperty(protocol, name, YES, YES) == NULL)//FIX: This doesn't work!
            attrStr = [attrStr stringByAppendingString: @",OPT"];
        propertyInfo[@(name)] = attrStr;
    }
    free(props);
    [skip addObject: protocol];
    return YES;
}


// Iterates over every direct parent of a protocol.
static void forEachParent(Protocol* protocol, BOOL (^block)(Protocol* parent)) {
    unsigned n;
    Protocol*__unsafe_unretained* parents = protocol_copyProtocolList(protocol, &n);
    for (unsigned i = 0; i < n; i++) {
        if (!block(parents[i]))
            break;
    }
    free(parents);
}


#pragma mark - DYNAMIC METHOD GENERATORS:


+ (Class) itemClassForArrayProperty: (NSString*)property {
    return nil; //??? How to make this extensible?
}


// Generates a method for a property getter.
+ (IMP) impForGetterOfProperty: (NSString*)property ofClass: (Class)propertyClass {
    id (^impBlock)(CBLInterface*) = nil;
    
    if (propertyClass == Nil) {
        // Untyped
        return [super impForGetterOfProperty: property ofClass: propertyClass];
    } else if (propertyClass == [NSString class]
               || propertyClass == [NSNumber class]
               || propertyClass == [NSDictionary class]) {
        // String, number, dictionary: do some type-checking:
        impBlock = ^id(CBLInterface* receiver) {
            return [receiver getValueOfProperty: property ofClass: propertyClass];
        };
    } else if (propertyClass == [NSArray class]) {
        Class itemClass = [self itemClassForArrayProperty: property];
        if (itemClass == nil) {
            // Untyped array:
            impBlock = ^id(CBLInterface* receiver) {
                return [receiver getValueOfProperty: property ofClass: propertyClass];
            };
        } else {
            // Typed array of scalar class:
            ValueConverter itemConverter = CBLValueConverterToClass(itemClass);
            if (itemConverter) {
                impBlock = ^id(CBLInterface* receiver) {
                    return [$castIf(NSArray, receiver[property]) my_map: ^id(id value) {
                        return itemConverter(value);
                    }];
                };
            }
        }
    } else {
        // Other property type -- use a ValueConverter if we have one:
        ValueConverter converter = CBLValueConverterToClass(propertyClass);
        if (converter) {
            impBlock = ^id(CBLInterface* receiver) {
                return converter(receiver[property]);
            };
        }
    }

    return impBlock ? imp_implementationWithBlock(impBlock) : NULL;
}

// Generates a method for a property getter.
+ (IMP) impForGetterOfProperty: (NSString*)property ofProtocol:(Protocol *)propertyProtocol {
    id (^impBlock)(CBLInterface*) = nil;
    if (protocol_conformsToProtocol(propertyProtocol, @protocol(CBLInterface))) {
        impBlock = ^id(CBLInterface* receiver) {
            NSDictionary* value = [receiver getValueOfProperty: property];
            if (![value isKindOfClass: [NSDictionary class]])
                return nil;
            if (receiver->_mutable)
                return [CBLInterface accessMutableObject: (NSMutableDictionary*)value
                                         throughProtocol: propertyProtocol];
            else
                return [CBLInterface accessObject: value throughProtocol: propertyProtocol];
        };
    }
    return impBlock ? imp_implementationWithBlock(impBlock) : NULL;
}


// Generates a method for a property setter.
+ (IMP) impForSetterOfProperty: (NSString*)property ofClass: (Class)propertyClass {
    void (^impBlock)(CBLInterface*,id) = nil;

    if ([propertyClass isSubclassOfClass: [CBLInterface class]]) {
        // Model-valued property:
        impBlock = ^(CBLInterface* receiver, CBLInterface* value) {
            [receiver setValue: value.$allProperties forKey: property];
        };
    } else if ([propertyClass isSubclassOfClass: [NSArray class]]) {
        Class itemClass = [self itemClassForArrayProperty: property];
        if (itemClass == nil) {
            // Untyped array:
            return [super impForSetterOfProperty: property ofClass: propertyClass];
        } else if ([itemClass isSubclassOfClass: [CBLInterface class]]) {
            // Model-valued array (to-many relation):
            impBlock = ^(CBLInterface* receiver, NSArray* value) {
                value = [value my_map:^id(CBLInterface* obj) {
                    return obj.$allProperties;
                }];
                [receiver setValue: value ofProperty: property];
            };
        } else if ([itemClass conformsToProtocol: @protocol(CBLJSONEncoding)]) {
            impBlock = ^(CBLInterface* receiver, NSArray* value) {
                value = [value my_map:^id(id<CBLJSONEncoding> obj) {
                    return [obj encodeAsJSON];
                }];
                [receiver setValue: value ofProperty: property];
            };
        } else {
            // Scalar-valued array:
            impBlock = ^(CBLInterface* receiver, NSArray* value) {
                [receiver setValue: value ofProperty: property];
            };
        }
    } else if ([propertyClass conformsToProtocol: @protocol(CBLJSONEncoding)]) {
        impBlock = ^(CBLInterface* receiver, id<CBLJSONEncoding> value) {
            [receiver setValue: [value encodeAsJSON] ofProperty: property];
        };
    } else {
        // Other property type -- use a ValueConverter if we have one:
        ValueConverter converter = CBLValueConverterFromClass(propertyClass);
        if (converter) {
            impBlock = ^(CBLInterface* receiver, id value) {
                [receiver setValue: converter(value) ofProperty: property];
            };
        }
    }

    return impBlock ? imp_implementationWithBlock(impBlock) : NULL;
}

// Generates a method for a property setter.
+ (IMP) impForSetterOfProperty: (NSString*)property ofProtocol:(Protocol *)propertyProtocol {
    void (^impBlock)(CBLInterface*,id) = nil;
    if (protocol_conformsToProtocol(propertyProtocol, @protocol(CBLInterface))) {
        impBlock = ^void(CBLInterface* receiver, id<CBLInterface> value) {
            [receiver setValue: value.$allProperties ofProperty: property];
        };
    }
    return impBlock ? imp_implementationWithBlock(impBlock) : NULL;
}


#pragma mark - INSTANCE METHODS:


- (instancetype) initWithObject:(NSDictionary *)object mutable: (BOOL)mutable {
    self = [super init];
    if (self) {
        _object = object;
        _mutable = mutable;
    }
    return self;
}

- (id) getValueOfProperty: (NSString*)property {
    return _object[property];
}

- (id) getValueOfProperty: (NSString*)property ofClass: (Class)klass {
    id value = _object[property];
    return [value isKindOfClass: klass] ? value : nil;
}

- (BOOL) setValue: (id)value ofProperty: (NSString*)property {
    NSAssert(_mutable, @"%@ is immutable", self);
    ((NSMutableDictionary*)_object)[property] = value;
    return YES;
}

- (id) objectForKeyedSubscript: (NSString*)key {
    return _object[key];
}

- (void) setObject: (id)object forKeyedSubscript: (NSString*)key {
    NSAssert(_mutable, @"%@ is immutable", self);
    [_object setValue: object forKey: key]; // supports nil values
}

- (void) erase {
    NSAssert(_mutable, @"%@ is immutable", self);
    [(NSMutableDictionary*)_object removeAllObjects];
}


@end
