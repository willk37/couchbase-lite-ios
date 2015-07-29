//
//  ValueConverter.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 3/19/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

// A type of block that converts an input value to an output value, or nil if it can't.
typedef id (^ValueConverter)(id input);

// Returns a block that will convert an input JSON value to an instance of the desired class,
// or nil if the class isn't supported.
ValueConverter CBLValueConverterToClass(Class toClass);

// Returns a block that will convert an input object to a JSON-compatible object,
// or nil if the class isn't supported.
ValueConverter CBLValueConverterFromClass(Class fromClass);

id CBLToJSONCompatible(id value);
