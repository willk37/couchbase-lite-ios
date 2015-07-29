//
//  ValueConverter.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 3/19/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import "ValueConverter.h"
#import "CBLBase64.h"
#import "CBLJSON.h"
#import "CBLInterface.h"
#import "CBLNuModel.h"
#import "CBLModelArray.h"
#import "CBLObject_Internal.h"


// Returns a block that will convert an input JSON value to an instance of the desired class,
// or nil if the class isn't supported.
ValueConverter CBLValueConverterToClass(Class toClass) {
    if (toClass == [NSData class]) {
        return ^id(id rawValue) {
            if ([rawValue isKindOfClass: [NSString class]])
                return [CBLBase64 decode: rawValue];
            return nil;
        };
    } else if (toClass == [NSDate class]) {
        return ^id(id rawValue) {
            return [CBLJSON dateWithJSONObject: rawValue];
        };
    } else if (toClass == [NSDecimalNumber class]) {
        return ^id(id rawValue) {
            if ([rawValue isKindOfClass: [NSString class]])
                return [NSDecimalNumber decimalNumberWithString: rawValue];
            return nil;
        };
    } else if (toClass == [NSURL class]) {
        return ^id(id rawValue) {
            if ([rawValue isKindOfClass: [NSString class]])
                return [NSURL URLWithString: rawValue];
            return nil;
        };
    } else if ([toClass conformsToProtocol: @protocol(CBLInterface)]) {
        return ^id(id rawValue) {
            if (![rawValue isKindOfClass: [NSDictionary class]])
                return nil;
            return [(CBLInterface*)[toClass alloc] initWithObject: rawValue mutable: NO];
        };
    } else if ([toClass conformsToProtocol: @protocol(CBLJSONEncoding)]) {
        return ^id(id rawValue) {
            if (!rawValue)
                return nil;
            return [(id<CBLJSONEncoding>)[toClass alloc] initWithJSON: rawValue];
        };
    } else {
        return nil;
    }
}


// Returns a block that will convert an input object to a JSON-compatible object,
// or nil if the class isn't supported.
ValueConverter CBLValueConverterFromClass(Class fromClass) {
    if (fromClass == [NSData class]) {
        return ^id(NSData* value) {
            return [CBLBase64 encode: value];
        };
    } else if (fromClass == [NSDate class]) {
        return ^id(NSDate* value) {
            return [CBLJSON JSONObjectWithDate: value];
        };
    } else if (fromClass == [NSDecimalNumber class]) {
        return ^id(NSDecimalNumber* value) {
            return [value stringValue];
        };
    } else if (fromClass == [NSURL class]) {
        return ^id(NSURL* value) {
            return [value absoluteString];
        };
    } else if ([fromClass conformsToProtocol: @protocol(CBLInterface)]) {
        return ^id(id<CBLInterface> value) {
            return value.$allProperties;
        };
    } else if ([fromClass conformsToProtocol: @protocol(CBLJSONEncoding)]) {
        return ^id(id<CBLJSONEncoding> value) {
            return [value encodeAsJSON];
        };
    } else {
        return nil;
    }
}


id CBLToJSONCompatible(id value) {
    if ([value isKindOfClass: [NSData class]])
        value = [CBLBase64 encode: value];
        else if ([value isKindOfClass: [NSDate class]])
            value = [CBLJSON JSONObjectWithDate: value];
        else if ([value isKindOfClass: [NSDecimalNumber class]])
            value = [value stringValue];
        else if ([value isKindOfClass: [CBLNuModel class]])
            value = ((CBLNuModel*)value).documentID;
        else if ([value isKindOfClass: [CBLFault class]])
            value = [CBLNuModel documentIDFromFault: value];
        else if ([value isKindOfClass: [NSArray class]]) {
            if ([value isKindOfClass: [CBLModelArray class]])
                value = [value docIDs];
            else
                value = [value my_map:^id(id obj) { return CBLToJSONCompatible(obj); }];
        } else if ([value conformsToProtocol: @protocol(CBLJSONEncoding)]) {
            value = [(id<CBLJSONEncoding>)value encodeAsJSON];
        }
    return value;
}