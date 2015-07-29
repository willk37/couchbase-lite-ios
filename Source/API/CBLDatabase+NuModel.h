//
//  CBLDatabaseNuModel.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 3/20/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import "CBLDatabase.h"
@class CBLNuModel;


@interface CBLDatabase (NuModel)

- (void) registerModelClass: (Class)modelClass;

- (CBLNuModel*) existingModelWithDocumentID: (NSString*)docID
                                      error: (NSError**)outError;

- (void) addNuModel: (CBLNuModel*)model;

- (NSArray*) unsavedNuModels;

- (BOOL) saveAllNuModels: (NSError**)outError;

@end
