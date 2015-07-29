//
//  NuModel_Tests.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/17/14.
//
//

#import "CBLTestCase.h"
#import "CouchbaseLite.h"
#import "CBLDatabase+NuModel.h"
#import "CBLInterface.h"
#import "CBLObject_Internal.h"
#import "CBLNuModel.h"
#import "CBLNuModelFactory.h"
#import "CBLQueryRowModel.h"
#import "CBJSONEncoder.h"


@interface NuModel_Tests : CBLTestCaseWithDB
@end



@protocol SimpleInterface1 <NSObject, CBLInterface>
@property NSString* name;
@property uint32_t age;
@end

@protocol SimpleInterface2 <CBLInterface>
@property BOOL sex;
@property (copy) NSData* photo;
@property NSURL* homePage;
@end

@protocol RedHerring <NSObject>
@property double dorkyDorkyDorky;
@end

@protocol SimpleInterface3 <SimpleInterface1>
@property NSArray* foo;
@end

@protocol SimpleInterface <SimpleInterface1, RedHerring, SimpleInterface2, SimpleInterface3>
@optional
@property double rating;
@property id<SimpleInterface3> si3;
@end



// Subclass of CBLObject, for testing
@interface CBLObjectTest : CBLObject
@property (getter=isBool,setter=setIsBool:) bool aBool;
@property BOOL aBOOL;
@property char aChar;
@property short aShort;
@property int anInt;
@property int64_t aLong;
@property uint8_t aUChar;
@property uint16_t aUShort;
@property unsigned aUInt;
@property uint64_t aULong;
@property float aFloat;
@property double aDouble;
@property (copy) NSString* str;
@property (readonly) int readOnly;

@property int synthesized;
@property (readonly) id ignore;
@end

@implementation CBLObjectTest
CBLSynthesizeAs(aBool, bool);
CBLSynthesize(aBOOL);
CBLSynthesizeAs(aChar, char);
CBLSynthesizeAs(aShort, short);
CBLSynthesizeAs(anInt, int);
CBLSynthesizeAs(aLong, long);
CBLSynthesizeAs(aUChar, uchar);
CBLSynthesizeAs(aUShort, ushort);
CBLSynthesizeAs(aUInt, uint);
CBLSynthesizeAs(aULong, ulong);
CBLSynthesizeAs(str, string);
CBLSynthesizeAs(aFloat, float);
CBLSynthesizeAs(aDouble, double);
CBLSynthesize(readOnly);
@synthesize synthesized;

- (id) ignore {return nil;}
@end




// Subclass of CBLNuModel, for testing
@interface TestNuModel : CBLNuModel
@property (copy) NSString* greeting;
@property float size;
@property TestNuModel* other;
@end

@implementation TestNuModel

CBLSynthesize(greeting);
CBLSynthesize(size);
CBLSynthesize(other);

@end




// Implementation of CBLNuModelFactoryDelegate, for testing
@interface TestModelSource : NSObject <CBLNuModelFactoryDelegate>
- (instancetype) initWithDictionary: (NSDictionary*)dict;
@end

@implementation TestModelSource
{
    NSMutableDictionary* _dict;
}

- (instancetype) initWithDictionary: (NSDictionary*)dict {
    self = [super init];
    if (self)
        _dict = [dict mutableCopy];
    return self;
}

- (BOOL) readPropertiesOfModel: (CBLNuModel*)model error:(NSError**)error {
    Log(@"READ %@", model);
    model.persistentProperties = _dict[model.documentID];
    return YES;
}

- (BOOL) savePropertiesOfModel: (CBLNuModel*)model error:(NSError**)error {
    Log(@"SAVE %@", model);
    _dict[model.documentID] = model.persistentProperties;
    return YES;
}

- (BOOL) savePropertiesOfModels: (NSSet*)models error:(NSError**)error {
    NSAssert(NO, @"Should not be called!");
    return NO;
}

@end



// Subclass of CBLQueryRowModel, for testing
@interface TestRow : CBLQueryRowModel
@property (readonly) int year;
@property (readonly) NSString* title;
@property (readonly) float rating;
@end

@implementation TestRow

CBLSynthesizeAs(year,   key0);
CBLSynthesizeAs(title,  key1);
CBLSynthesize(rating);

@end




static NSString* jsonString(id obj) {
    return [[CBJSONEncoder canonicalEncoding: obj error: NULL] my_UTF8ToString];
}

static NSDictionary* dirtyProperties(CBLObject* m) {
    NSMutableDictionary* dirty = $mdict();
    return [m getPersistentPropertiesInto: dirty] ? dirty : nil;
}



#pragma mark - TESTS START HERE!

@implementation NuModel_Tests


- (void) test_CBLInterface {
    NSDictionary* dict = @{@"name": @"Zegpold",
                           @"age": @23,
                           @"rating": @8.9,
                           @"extra": @[],
                           @"photo": @"aGkgdGhlcmU=",
                           @"homePage": @"http://couchbase.com",
                           @"si3": @{@"foo": @[]}};
    id<SimpleInterface> i = [CBLInterface accessObject: dict
                                       throughProtocol: @protocol(SimpleInterface)];
    AssertEqual(i.name, @"Zegpold");
    AssertEq(i.age, 23u);
    AssertEq(i.rating, 8.9);
    AssertEqual(i.photo, [NSData dataWithBytes: "hi there" length: 8]);
    AssertEqual(i.homePage, [NSURL URLWithString: @"http://couchbase.com"]);
    AssertEqual(i[@"extra"], @[]);
    AssertEqual(i.si3.foo, @[]);

    Assert(![i respondsToSelector: @selector(dorkyDorkyDorky)], @"didn't ignore RedHerring");

    NSMutableDictionary* mdict = [dict mutableCopy];
    i = [CBLInterface accessMutableObject: mdict
                          throughProtocol: @protocol(SimpleInterface)];
    i.age = 24;
    i.rating = 8.7;
    i[@"extra"] = @[@1];
    i.photo = [NSData dataWithBytes: "bye" length: 3];
    i.homePage = [NSURL URLWithString: @"http://apple.com"];
    i.si3 = [CBLInterface mutableInstanceOfProtocol: @protocol(SimpleInterface3)];
    i.si3.foo = @[@"a",@"b"];
    AssertEqual(mdict[@"age"], @24);
    AssertEqual(mdict[@"rating"], @8.7);
    AssertEqual(mdict[@"extra"], @[@1]);
    AssertEqual(mdict[@"photo"], @"Ynll");
    AssertEqual(mdict[@"homePage"], @"http://apple.com");
    AssertEqual(mdict[@"si3"], (@{@"foo": @[@"a", @"b"]}));

    Log(@"Property info = %@", [[i class] propertyInfo]);
}


- (void) test_CBLObject {
    NSArray* info = [CBLObjectTest persistentPropertyInfo];
    Log(@"Info = %@", info);

    Log(@"---- Initializing a model");
    CBLObjectTest* m = [[CBLObjectTest alloc] init];
    m.aBool = true;
    m.aBOOL = YES;
    m.aChar = -123;
    m.aUChar = 234;
    m.aShort = 32767;
    m.aUShort = 65432;
    m.anInt = 1337;
    m.aUInt = 123456789;
    m.aLong = -123456789876543;
    m.aULong = 123456789876543;
    m.aFloat = 3.14159f;
    m.aDouble = M_PI;
    m.synthesized = 1;
    m.str = @"frood";

    Log(@"---- Testing properties");
    NSDictionary* persistentProperties = m.persistentProperties;
    Log(@"Properties = %@", jsonString(persistentProperties));
    AssertEqualish(persistentProperties, (@{@"double":@3.141592653589793, @"int":@1337, @"ushort":@65432, @"string":@"frood", @"float":@3.14159, @"long":@-123456789876543, @"char":@-123, @"short":@32767, @"uint":@123456789, @"ulong":@123456789876543, @"uchar":@234, @"bool":@YES, @"aBOOL": @YES}));
    AssertEqualish(jsonString(persistentProperties), @"{\"aBOOL\":true,\"bool\":true,\"char\":-123,\"double\":3.141592653589793,\"float\":3.14159,\"int\":1337,\"long\":-123456789876543,\"short\":32767,\"string\":\"frood\",\"uchar\":234,\"uint\":123456789,\"ulong\":123456789876543,\"ushort\":65432}");
    Log(@"Dirty = %llx", m.dirtyFlags);
    Assert(m.needsSave);
    AssertEq(m.dirtyFlags, 0x01FFFllu);

    [m setPersistentProperties: @{@"float": @1.414}];
    Log(@"m.aFloat = %g", m.aFloat);
    AssertEq(m.aDouble, 0.0);
    persistentProperties = m.persistentProperties;
    Log(@"Properties = %@", jsonString(persistentProperties));
    AssertEqualish(persistentProperties, (@{@"float":@1.414}));

    Log(@"---- m.anInt = -2468");
    m.needsSave = NO;
    m.anInt = -2468;
    Log(@"Dirty = %llx", m.dirtyFlags);
    AssertEq(m.dirtyFlags, 0x10llu);
    Log(@"Dirty Properties = %@", jsonString(dirtyProperties(m)));
    Assert(m.needsSave);
    AssertEq(m.anInt, -2468);

    Log(@"---- Making a no-op change:");
    NSMutableDictionary* properties = [m.persistentProperties mutableCopy];
    m.needsSave = NO;
    m.anInt = -2468; // no-op change
    Log(@"Dirty = %llx", m.dirtyFlags);
    Assert(![m getPersistentPropertiesInto: properties]);

    Log(@"---- Set double-valued property");
    m.needsSave = NO;
    m.aDouble = 25.25;
    Log(@"Dirty = %llx", m.dirtyFlags);
    Log(@"Dirty Properties = %@", jsonString(dirtyProperties(m)));
    Assert(m.needsSave);
    AssertEq(m.aDouble, 25.25);
}


- (void) test_CBLNuModel_Isolated {
    RequireTestCase(CBLObject);

    CBLNuModelFactory* factory = [[CBLNuModelFactory alloc] init];
    TestModelSource* source = [[TestModelSource alloc] initWithDictionary: @{
        @"doc1": @{@"greeting": @"hello", @"size": @8.5, @"other": @"doc2"},
        @"doc2": @{@"greeting": @"bye", @"size": @14}
    }];
    factory.delegate = source;

    NSError* error;
    TestNuModel* doc1 = (TestNuModel*) [factory modelWithDocumentID: @"doc1"
                                                            ofClass: [TestNuModel class]
                                                            asFault: NO
                                                              error: &error];
    Assert(doc1);
    Assert([doc1 isKindOfClass: [TestNuModel class]]);
    Assert(!doc1.isFault);
    AssertEqual(doc1.greeting, @"hello");
    AssertEq(doc1.size, 8.5);

    TestNuModel* doc2 = doc1.other;
    Assert(doc2);
    Assert(doc2.isFault);
    AssertEqual(doc2.greeting, @"bye");
    AssertEq(doc2.size, 14);
    Assert(!doc2.isFault);
}


- (void) test_SaveModel {
    NSString* modelID, *model2ID, *model3ID;
    {
        [db registerModelClass: [TestNuModel class]];
        TestNuModel* model = [[TestNuModel alloc] init];
        Assert(model != nil);
        Assert(model.isNew);
        Assert(!model.needsSave);
        modelID = model.documentID;
        AssertEqual(model.persistentProperties, @{@"type": @"TestNuModel"});

        // Create and populate a TestModel:
        model.greeting = @"¡Hola!";
        model.size = 123;

        Assert(model.isNew);
        Assert(model.needsSave);
        AssertEqual(model.persistentProperties, (@{@"greeting": @"¡Hola!",
                                                   @"size": @123,
                                                   @"type": @"TestNuModel"}));

        TestNuModel* model2 = [[TestNuModel alloc] init];
        model2ID = model2.documentID;
        TestNuModel* model3 = [[TestNuModel alloc] init];
        model3ID = model3.documentID;

        model.other = model3;

        // Verify the property getters:
        AssertEqual(model.greeting, @"¡Hola!");
        AssertEq(model.size, 123);
        AssertEq(model.other, model3);

        // Save it and make sure the save didn't trigger a reload:
        [db addNuModel: model];
        AssertEqual(db.unsavedNuModels, @[model]);
        NSError* error;
        Assert([db saveAllNuModels: &error]);

        // Verify that the document got updated correctly:
        NSMutableDictionary* props = [model.persistentProperties mutableCopy];
        AssertEqual(props, (@{@"greeting": @"¡Hola!",
                              @"size": @123,
                              @"other": model3ID,
                              @"type": @"TestNuModel"}));
#if 0
        // Update the document directly and make sure the model updates:
        props[@"number"] = @4321;
        Assert([model.document putProperties: props error: &error]);
        AssertEq(model.reloadCount, 1u);
        AssertEq(model.number, 4321);

        // Store the same properties in a different model's document:
        [props removeObjectForKey: @"_id"];
        [props removeObjectForKey: @"_rev"];
        Assert([model2.document putProperties: props error: &error]);
        // ...and verify its properties:
        AssertEq(model2.reloadCount, 1u);
        AssertEq(model2.number, 4321);
        AssertEqual(model2.str, @"LEET");
        AssertEqual(model2.strings, (@[@"fee", @"fie", @"foe", @"fum"]));
        AssertEqual(model2.data, [@"ASCII" dataUsingEncoding: NSUTF8StringEncoding]);
        AssertEqual(model2.date, [NSDate dateWithTimeIntervalSinceReferenceDate: 392773252]);
        AssertEqual(model2.dates, dates);
        AssertEqual(model2.decimal, decimal);
        AssertEq(model2.other, model3);
        AssertEqual(model2.others, (@[model2, model3]));
        AssertEqual(model2.others, model.others);

        AssertEqual($cast(CBLModelArray, model2.others).docIDs, (@[model2.documentID,
                                                                    model3.documentID]));
#endif
    }
    {
        // Close/reopen the database and verify again:
        [self reopenTestDB];
        [db registerModelClass: [TestNuModel class]];
        NSError* error;
        TestNuModel* modelAgain = (TestNuModel*)[db existingModelWithDocumentID: modelID error: &error];
        Assert(modelAgain, @"Couldn't reload model: %@", error);
        AssertEqual(modelAgain.greeting, @"¡Hola!");
        AssertEq(modelAgain.size, 123);

        TestNuModel *other = modelAgain.other;
        AssertEqual(other.documentID, model3ID);
#if 0
        NSArray* others = modelAgain.others;
        AssertEq(others.count, 2u);
        AssertEq(others[1], other);
        AssertEqual(((TestNuModel*)others[0]).documentID, model2ID);
#endif
    }
}


- (void) test_CBLQueryRowModel {

    CBLView* view = [db viewNamed: @"vu"];
    [view setMapBlock: MAPBLOCK({
        emit(@[doc[@"year"], doc[@"title"]], @{@"rating": doc[@"rating"]});
    }) version: @"1"];

    [self createDocumentWithProperties:
                        @{@"year": @1977, @"title": @"Star Wars", @"rating": @0.9}];

    int rowCount = 0;
    CBLQuery* query = [view createQuery];
    for (CBLQueryRow* row in [query run: NULL]) {
        TestRow* testRow = [[TestRow alloc] initWithQueryRow: row];
        AssertEq(testRow.year, 1977);
        AssertEqual(testRow.title, @"Star Wars");
        AssertEq(testRow.rating, 0.9f);
        ++rowCount;
    }
    AssertEq(rowCount, 1);
}

@end
