//
//  CBLQueryRowModel.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 9/26/14.
//
//

#import "CBLObject.h"
@class CBLQueryRow;


/** An object representing a view-query row, with properties that map to the JSON key/value.
    You should use CBLSynthesizeAs() to define properties, with JSON property names like:
        "key"                   -- the entire key
        "key0", "key1", etc.    -- Components of an array key
        "value"                 -- the entire value
        "value0", "value1", etc -- Components of an array value
    Other property names are assumed to be keys of a dictionary-based value. */
@interface CBLQueryRowModel : CBLObject

- (instancetype) initWithQueryRow: (CBLQueryRow*)row;

@property (readonly, nonatomic) CBLQueryRow* row;

@end
