//
//  CBLDatabase+NuModel.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 3/20/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import "CBLDatabase+NuModel.h"


#import "CBLDatabase+Internal.h"
#import "CBLDatabase+Insertion.h"
#import "CBLDatabaseChange.h"
#import "CBLNuModelFactory.h"
#import "CBLInternal.h"
#import "CouchbaseLitePrivate.h"


@interface CBLDatabase (NuModel_Internal) <CBLNuModelFactoryDelegate>
@end


@implementation CBLDatabase (NuModel)


- (CBLNuModelFactory*) nuModelFactory {
    if (!_nuFactory) {
        _nuFactory = [[CBLNuModelFactory alloc] init];
        _nuFactory.delegate = self;
    }
    return _nuFactory;
}

- (void) registerModelClass: (Class)modelClass {
    [self.nuModelFactory registerModelClass: modelClass];
}

- (CBLNuModel*) existingModelWithDocumentID: (NSString*)docID error: (NSError**)outError {
    CBLNuModel* model;
    model = [self.nuModelFactory existingModelWithDocumentID: docID];
    if (model)
        return model;

    // Load the document to look at its 'type' property:
    CBLStatus status;
    CBL_Revision* rev = [self getDocumentWithID: docID
                                     revisionID: nil
                                       withBody: YES
                                         status: &status];
    if (!rev) {
        if (outError)
            *outError = (status != kCBLStatusNotFound) ? CBLStatusToNSError(status) : nil;
        return nil;
    }
    NSString* docType = rev[@"type"];
    Class klass = [_nuFactory modelClassForDocumentType: docType];
    if (!klass) {
        CBLStatusToOutNSError(kCBLStatusUnsupportedType, outError);
        return nil;
    }
    return [_nuFactory modelWithDocumentID: docID ofClass: klass asFault:NO error:outError];
}

- (void) addNuModel: (CBLNuModel*)model {
    [self.nuModelFactory addModel: model];
}

- (NSArray*) unsavedNuModels {
    return [_nuFactory.unsavedModels allObjects];
}

- (BOOL) saveAllNuModels: (NSError**)outError {
    return _nuFactory ? [_nuFactory saveAllModels: outError] : YES;
}

- (void) _revisionAdded:(CBLDatabaseChange *)change notify:(BOOL)notify {
    CBLNuModel* model = [_nuFactory existingModelWithDocumentID: change.documentID];
    if (!model || model.isFault)
        return;
    NSString* revID = change.winningRevisionID;
    if (!revID)
        return; // current revision didn't change
    if (!$equal(revID, model.revisionID)) {
        CBL_Revision* rev = change.winningRevisionIfKnown;
        if (rev)
            [model readFromRevision: rev];
        else
            [self readPropertiesOfModel: model error: nil]; // read current rev from db
    }
}

// CBLNuModelFactoryDelegate API:

- (BOOL) readPropertiesOfModel: (CBLNuModel*)model error: (NSError**)outError {
    CBLStatus status;
    CBL_Revision* rev = [self getDocumentWithID: model.documentID
                                     revisionID: nil
                                       withBody: YES
                                         status: &status];
    if (!rev && status != kCBLStatusNotFound) {
        if (outError)
            *outError = CBLStatusToNSError(status);
        return NO;
    }
    [model readFromRevision: rev];
    return YES;
}


- (BOOL) savePropertiesOfModel: (CBLNuModel*)model error: (NSError**)outError {
    CBL_MutableRevision* rev = [[CBL_MutableRevision alloc] initWithDocID: model.documentID
                                                                    revID: model.revisionID
                                                                  deleted: NO];
    rev.properties = model.persistentProperties;
    CBLStatus status;
    CBL_Revision* nuRev = [self putRevision: rev
                             prevRevisionID: model.revisionID
                              allowConflict: NO
                                     status: &status
                                      error: outError];
    return nuRev != nil;
}


- (BOOL) savePropertiesOfModels: (NSSet*)models error: (NSError**)outError {
    return [self inTransaction: ^BOOL{
        for (CBLNuModel* model in models) {
            @autoreleasepool {
                if (![self savePropertiesOfModel: model error: outError])
                    return NO;
            }
        }
        return YES;
    }];
}


@end
