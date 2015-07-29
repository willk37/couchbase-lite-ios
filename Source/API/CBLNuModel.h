//
//  CBLNuModel.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/18/14.
//
//

#import "CBLObject.h"
@class CBLNuModelFactory, CBL_Revision, CBLFault;


/** Abstract model object that represents a Couchbase Lite document in memory. */
@interface CBLNuModel : CBLObject

- (instancetype) initNewWithID: (NSString*)documentID;
- (instancetype) init;

@property (readonly, nonatomic) CBLNuModelFactory* factory;

@property (readonly, nonatomic) NSString* documentID;
@property (readonly, nonatomic) NSString* revisionID;
@property (readonly, nonatomic) BOOL deleted;

@property (readonly, nonatomic) BOOL isNew;

/** Writes any changes to a new revision of the document.
    Returns YES without doing anything, if no changes have been made. */
- (BOOL) save: (NSError**)outError;

/** Persistent "type" property */
@property (copy) NSString* documentType;

/** Document types that can be represented by this class */
+ (NSArray*) documentTypes;

- (void) readFromRevision: (CBL_Revision*)rev;

@end



// internal:
@interface CBLNuModel ()
- (instancetype) initWithFactory: (CBLNuModelFactory*)factory
                      documentID: (NSString*)documentID;
@property (readwrite, nonatomic) CBLNuModelFactory* factory;
+ (NSString*) documentIDFromFault: (CBLFault*)fault;
@end
