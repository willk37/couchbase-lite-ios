//
//  CBLNuModel.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/18/14.
//
//

#import "CBLNuModel.h"
#import "CBLNuModelFactory.h"
#import "CBLObject_Internal.h"
#import "CBLMisc.h"
#import "CBL_Revision.h"
#import "CouchbaseLitePrivate.h"


@interface CBLNuModel ()
@property (readwrite) NSString* revisionID;
@property (readwrite) BOOL deleted;
@end




@implementation CBLNuModel
{
    BOOL _saving;
}


@synthesize factory=_factory, documentID=_documentID, revisionID=_revisionID, deleted=_deleted,
            isNew=_isNew;

CBLSynthesizeAs(documentType, type);


+ (NSArray*) documentTypes {
    return @[NSStringFromClass(self)];
}


//+ (instancetype) modelWithFactory: (CBLNuModelFactory*)factory
//                       documentID: (NSString*)documentID
//{
//    return [factory modelWithDocumentID: documentID ofClass: self asFault: NO error: nil];
//}
//
//+ (instancetype) createModelWithFactory: (CBLNuModelFactory*)factory {
//    return [[self alloc] initNewModelWithFactory: factory];
//}


- (instancetype) initWithID: (NSString*)documentID { // Designated initializer
    Assert(documentID);
    self = [super init];
    if (self) {
        _documentID = [documentID copy];
    }
    return self;
}


- (instancetype) initNewWithID: (NSString*)documentID {
    self = [self initWithID: documentID];
    if (self) {
        _isNew = YES;
        self.documentType = [[[self class] documentTypes] firstObject];
        [self setNeedsSave: NO];
    }
    return self;
}

- (instancetype) init {
    return [self initNewWithID: CBLCreateUUID()];
}


- (instancetype) initWithFactory: (CBLNuModelFactory*)factory
                      documentID: (NSString*)documentID
{
    self = [self initWithID: documentID];
    if (self) {
        _factory = factory;
    }
    return self;
}


- (instancetype) initNewModelWithFactory: (CBLNuModelFactory*)factory {
    Assert(factory);
    self = [self init];
    if (self) {
        [factory addModel: self];
    }
    return self;
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@]", self.class, _documentID];
}


- (BOOL) keepExtraProperties {
    return [self class] == [CBLNuModel class];
}


// Overridden to support model-valued properties
- (id) internalizeValue: (id)rawValue forProperty: (CBLPropertyInfo*)info {
    id value = [super internalizeValue: rawValue forProperty: info];
    if (!value) {
        Class propertyClass = info.propertyClass;
        if ([propertyClass isSubclassOfClass: [CBLNuModel class]]) {
            // Model-valued property:
            if (![rawValue isKindOfClass: [NSString class]])
                return nil;
            return [_factory modelWithDocumentID: rawValue
                                         ofClass: propertyClass
                                         asFault: YES
                                           error: nil];
        }
    }
    return value;
}


- (void) readFromRevision: (CBL_Revision*)rev {
    if (!_saving) {
        // Update ivars from revision, unless this is an echo of my saving myself:
        self.persistentProperties = rev.properties;
    }
    self.revisionID = rev.revID;
    self.deleted = rev.deleted;
}


#pragma mark - SAVING:


- (void) setNeedsSave: (BOOL)needsSave {
    if (needsSave != super.needsSave) {
        [super setNeedsSave: needsSave];
        NSMutableSet* unsaved = _factory.unsavedModels;
        if (needsSave)
            [unsaved addObject: self];
        else
            [unsaved removeObject: self];
    }
}


// Internal version of -save: that doesn't invoke -didSave
- (BOOL) justSave: (NSError**)outError {
    Assert(_factory);
    if (!self.needsSave)
        return YES; // no-op
    BOOL ok;
    _saving = true;
    @try {
        ok = [_factory savePropertiesOfModel: self error: outError];
    } @finally {
        _saving = false;
    }
    return ok;
}


- (void) didSave {
    _isNew = NO;
    self.needsSave = NO;
}


- (BOOL) save: (NSError**)outError {
    BOOL ok = [self justSave: outError];
    if (ok)
        [self didSave];
    return ok;
}


#pragma mark - FAULTS:


- (void) awokeFromFault {
    NSError* error;
    if (![_factory readPropertiesOfModel: self error: nil])
        Warn(@"Error reading %@ from fault: %@", self, error);
    [super awokeFromFault]; // will call -awakeFromFetch
}


+ (NSString*) documentIDFromFault: (CBLFault*)fault {
    if (![fault isReallyKindOfClass: [CBLNuModel class]])
        return nil;
    return ((CBLNuModel*)fault)->_documentID;

}


@end
