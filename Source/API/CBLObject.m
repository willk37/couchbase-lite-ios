//
//  CBLObject.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/15/14.
//
//

#import "CBLObject.h"
#import "CBLObject_Internal.h"
#import "CouchbaseLitePrivate.h"
#import "CBLNuModel.h"
#import "CBLModelArray.h"
#import "ValueConverter.h"
#import "CBLJSON.h"
#import "CBLBase64.h"


// Prefix appended to synthesized property ivars by CBLSynthesize.
#define kIvarPrefixStr "_doc_"

static SEL selectorOfSetter(objc_property_t prop);

// Returns the address of an instance variable.
static inline void* ivarAddress(id object, Ivar ivar) {
    return ((char*)(__bridge CFTypeRef)object + ivar_getOffset(ivar));
}


@implementation CBLObject
{
    uint64_t _dirtyFlags;    // Bit-field that marks which properties (by index) have been changed
}


@synthesize needsSave=_needsSave;
@synthesize extraProperties=_extraProperties;
#if DEBUG
@synthesize dirtyFlags=_dirtyFlags; // used by unit tests
#endif


// Maps Class object -> NSArray of CBLObjectPropertyInfo
static NSMutableDictionary* sClassInfo;


// The setter method that gets spliced in for persistent properties; sets .needsSave.)
#define SETTER_BLOCK(OLD_IMP, FLAG, TYPE) \
    ^void(__unsafe_unretained CBLObject* receiver, TYPE value) { \
        if (!receiver->_dirtyFlags) [receiver setNeedsSave: YES]; \
        receiver->_dirtyFlags |= (FLAG); \
        void (*_oldSetter)(CBLObject* rcvr, SEL cmd, TYPE value) = (void*)(OLD_IMP); \
        _oldSetter(receiver, setterSelector, value); \
    }


+ (void) initialize {
    if (self == [CBLObject class]) {
        sClassInfo = [[NSMutableDictionary alloc] init];
        return;
    }

    // Iterate all properties defined in this class, looking for persistent ones
    CBLPropertyInfo* prevProperty = [[[self superclass] persistentPropertyInfo] lastObject];
    uint8_t propertyIndex = prevProperty ? prevProperty->index+1 : 0;
    NSMutableArray* infos = $marray();
    objc_property_t* props = class_copyPropertyList(self, NULL);
    if (props) {
        for (objc_property_t* prop = props; *prop; ++prop) {
            //Log(@"    %s -> %s", property_getName(*prop), property_getAttributes(*prop));
            const char* ivarName = property_copyAttributeValue(*prop, "V");
            if (ivarName) {
                if (strncmp(ivarName, kIvarPrefixStr, strlen(kIvarPrefixStr)) == 0) {
                    // Record info for this persistent property:
                    const char* docPropName = ivarName + strlen(kIvarPrefixStr);
                    CBLPropertyInfo* info = [[CBLPropertyInfo alloc] init];
                    info->index = propertyIndex;
                    info->definedInClass = self;
                    info->name = [[NSString alloc] initWithUTF8String: property_getName(*prop)];
                    info->docProperty = [[NSString alloc] initWithUTF8String: docPropName];
                    info->ivar = class_getInstanceVariable(self, ivarName);
                    info->ivarType = ivar_getTypeEncoding(info->ivar);
                    [infos addObject: info];

                    // Splice in a new setter method that records which property changed:
                    char* ro = property_copyAttributeValue(*prop, "R");
                    if (ro) {
                        info->readOnly = YES;
                        free(ro);
                    } else {
                        uint64_t dirtyMask = 1llu << MIN(propertyIndex, 63u);
                        SEL setterSelector = selectorOfSetter(*prop);
                        Method method = class_getInstanceMethod(self, setterSelector);
                        Assert(method);
                        IMP oldSetter = method_getImplementation(method);
                        id setter;
                        switch (info->ivarType[0]) {
                            case 'f':   setter = SETTER_BLOCK(oldSetter, dirtyMask, float); break;
                            case 'd':   setter = SETTER_BLOCK(oldSetter, dirtyMask, double); break;
                            default:    setter = SETTER_BLOCK(oldSetter, dirtyMask, void*); break;
                        }
                        method_setImplementation(method, imp_implementationWithBlock(setter));
                    }
                    propertyIndex++;
                }
                free((void*)ivarName);
            }
        }
        free(props);
    }

    @synchronized(self) {
        sClassInfo[(id)self] = infos;
    }
}


+ (NSArray*) persistentPropertyInfo {
    @synchronized(self) {
        return sClassInfo[(id)self];
    }
}


#pragma mark - PROPERTIES:


// Called from spliced-in property setter the first time a persistent property is changed.
- (void) setNeedsSave:(BOOL)needsSave {
    _needsSave = needsSave;
    if (needsSave)
        LogTo(Model, @"*** %@ is now dirty", self);
    else
        _dirtyFlags = 0;
}


// Calls the block once for each persistent property, including inherited ones
+ (void) forEachProperty: (void (^)(CBLPropertyInfo*))block {
    if (self != [CBLObject class]) {
        [[self superclass] forEachProperty: block];
        for (CBLPropertyInfo* info in [self persistentPropertyInfo])
            block(info);
    }
}


// Convert a value from raw JSON-parsed form into the type of the given property
- (id) internalizeValue: (id)rawValue forProperty: (CBLPropertyInfo*)info {
    Class propertyClass = info.propertyClass;
    if (!propertyClass) {
        // Scalar property. It must have an NSNumber value:
        return $castIf(NSNumber, rawValue);
    } else if (propertyClass == [NSData class])
        return [CBLBase64 decode: rawValue];
    else if (propertyClass == [NSDate class])
        return [CBLJSON dateWithJSONObject: rawValue];
    else if (propertyClass == [NSDecimalNumber class]) {
        if (![rawValue isKindOfClass: [NSString class]])
            return nil;
        return [NSDecimalNumber decimalNumberWithString: rawValue];
    } else if ([rawValue isKindOfClass: propertyClass]) {
        return rawValue;
    } else {
        // Value is of incompatible class, so don't return it:
        return nil;
    }
}


#define SETTER(TYPE, METHOD) \
    { TYPE v = (TYPE)[value METHOD]; \
      memcpy(dst, &v, sizeof(v)); }

- (void) setValue:(id)value forPersistentProperty: (CBLPropertyInfo*)prop {
    value = [self internalizeValue: value forProperty: prop];
    if (prop->ivarType[0] == '@') {
        object_setIvar(self, prop->ivar, value);
    } else {
        void* dst = ivarAddress(self, prop->ivar);
        switch (prop->ivarType[0]) {
            case 'B':   SETTER(bool,    boolValue); break;
            case 'c':
            case 'C':   SETTER(char,    charValue); break;
            case 's':
            case 'S':   SETTER(short,   shortValue); break;
            case 'i':
            case 'I':   SETTER(int,     intValue); break;
            case 'l':
            case 'L':   SETTER(int32_t, intValue); break;
            case 'q':
            case 'Q':   SETTER(int64_t, longLongValue); break;
            case 'f':   SETTER(float,   floatValue); break;
            case 'd':   SETTER(double,  doubleValue); break;
            default:
                Assert(NO, @"Can't set ivar of type '%s' in %@", prop->ivarType, prop);
                break;
        }
    }
}

- (void) setPersistentProperties: (NSDictionary*)properties {
    // Tell KVO that all persistent properties may be changing:
    [[self class] forEachProperty:^(CBLPropertyInfo *prop) {
        [self willChangeValueForKey: prop->name];
    }];

    NSMutableDictionary* extra = self.keepExtraProperties ? [properties mutableCopy] : nil;

    [[self class] forEachProperty:^(CBLPropertyInfo *prop) {
        [self setValue: properties[prop->docProperty] forPersistentProperty: prop];
        [extra removeObjectForKey: prop->docProperty];
    }];

    self.extraProperties = extra;

    // Tell KVO that all persistent properties may have changed:
    [[self class] forEachProperty:^(CBLPropertyInfo *prop) {
        [self didChangeValueForKey: prop->name];
    }];
}


- (id) persistentValueOfProperty: (CBLPropertyInfo*)info {
    const char* addr = ivarAddress(self, info->ivar);
    if (info->ivarType[0] == 'c' && *addr == 1) {
        // Special case for BOOL, which encodes to the same type as char:
        return $true;
    }
    id value = _box(addr, info->ivarType);
    if (info->ivarType[0] == '@')
        value = CBLToJSONCompatible(value);
    else if ([value doubleValue] == 0.0)
        value = nil;
    return value;
}

- (BOOL) keepExtraProperties {
    return NO;
}


- (NSDictionary*) persistentProperties {
    NSMutableDictionary* properties = [_extraProperties mutableCopy] ?: $mdict();
    [[self class] forEachProperty:^(CBLPropertyInfo *info) {
        id value = [self persistentValueOfProperty: info];
        if (value)
            properties[info->docProperty] = value;
    }];
    return properties;
}


- (BOOL) getPersistentPropertiesInto: (NSMutableDictionary*)properties {
    __block BOOL changed = NO;
    [[self class] forEachProperty:^(CBLPropertyInfo *info) {
        uint64_t dirtyMask = 1llu << MIN(info->index, 63u);
        if (_dirtyFlags & dirtyMask) {
            id value = [self persistentValueOfProperty: info];
            if (!$equal(value, properties[info->docProperty])) {
                [properties setValue: value forKey: info->docProperty];
                changed = YES;
            }
        }
    }];
    return changed;
}


#pragma mark - FAULTS:


- (BOOL) isFault {
    return NO;
}


- (void) turnIntoFault {
    @synchronized(self) {
        if (!_realClass) {
            _realClass = [self class];
            object_setClass(self, [CBLFault class]);  // SHAZAM! Transform into a fault
        }
    }
}

// Internal notification that I'm no longer a fault
- (void) awokeFromFault {
    [self awakeFromFetch];
}


- (void) awakeFromFetch {
    // nothing to do; subclasses can override this
}

- (void) awakeFromCreate {
    // nothing to do; subclasses can override this
}


@end




@implementation CBLFault


- (void) forwardInvocation: (NSInvocation*)invocation {
    @synchronized(self) {
        if (_realClass) {                       // in case of simultaneous calls
            LogTo(Model, @"AWAKE %@ ...", self);
            object_setClass(self, _realClass);  // SHAZAM! Transform into the real object
            _realClass = nil;                   // zero out state before transforming class
            [self awokeFromFault];
        }
    }
    [invocation invoke];
}


- (NSMethodSignature*) methodSignatureForSelector: (SEL)selector {
    return [_realClass instanceMethodSignatureForSelector: selector];
}


- (BOOL) isReallyKindOfClass: (Class)klass {
    return [_realClass isSubclassOfClass: klass];
}


- (BOOL) isFault {
    return YES;
}


- (void) turnIntoFault {
    // I am already a fault
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@/%@", self.class, _realClass];
}


@end




@implementation CBLPropertyInfo

- (NSString*) description {
    return [NSString stringWithFormat: @"[%@.%@ <- doc.%@ ('%s')]",
            definedInClass, name, docProperty, ivarType];
}

- (Class) propertyClass {
    @synchronized(self) {
        if (!_propertyClass && ivarType[0] == '@') {
            NSString* className = [[NSString alloc] initWithBytes: ivarType+2
                                                           length: strlen(ivarType)-3
                                                         encoding: NSUTF8StringEncoding];
            _propertyClass = NSClassFromString(className);
            Assert(_propertyClass);
        }
        return _propertyClass;
    }
}

@end




#if 0 // unused
static SEL selectorOfGetter(objc_property_t prop) {
    char* customGetter = property_copyAttributeValue(prop, "G");
    if (customGetter) {
        SEL result = sel_registerName(customGetter);
        free(customGetter);
        return result;
    } else {
        return sel_registerName(property_getName(prop));
    }
}
#endif


// Returns the selector of the setter method for the given property.
static SEL selectorOfSetter(objc_property_t prop) {
    char* customSetter = property_copyAttributeValue(prop, "S");
    if (customSetter) {
        SEL result = sel_registerName(customSetter);
        free(customSetter);
        return result;
    } else {
        const char* name = property_getName(prop);
        char setterName[strlen(name)+1+3+1];
        strcpy(setterName, "set");
        strcat(setterName, name);
        strcat(setterName, ":");
        setterName[3] = (char)toupper(setterName[3]);
        return sel_registerName(setterName);
    }
}
