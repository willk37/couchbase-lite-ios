//
//  Listener_Tests.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 7/8/15.
//  Copyright © 2015 Couchbase, Inc. All rights reserved.
//

#import "CBLTestCase.h"
#import "CBLManager+Internal.h"
#import "CBLSyncListener.h"
#import "CBLHTTPListener.h"
#import "CBLRemoteRequest.h"
#import "CBLClientCertAuthorizer.h"
#import "BLIPPocketSocketConnection.h"
#import "MYAnonymousIdentity.h"

#import <arpa/inet.h>


#define kTimeout 5.0


@interface Listener_Tests : CBLTestCaseWithDB <CBLListenerDelegate, BLIPConnectionDelegate>
@end


static UInt16 sPort = 60000;


@implementation Listener_Tests
{
    @protected
    CBLListener* listener;
    NSURLCredential* clientCredential;
    XCTestExpectation *_expectValidateServerTrust, *_expectDidOpen, *_expectDidClose;
    XCTestExpectation *_expectAuthenticateTrust;
}

- (Class) listenerClass {
    return [CBLSyncListener class];
}

- (void)setUp {
    [super setUp];
    dbmgr.dispatchQueue = dispatch_get_main_queue();
    dbmgr.replicatorClassName = @"CBLBlipReplicator";

    // Each test run uses a different port number (sPort is incremented) to prevent CFNetwork from
    // resuming the previous SSL session. Because if it does that, the previous client cert gets
    // used on the server side, which breaks the test. Haven't found a workaround for this yet.
    // --Jens 7/2015
    listener = [[[self listenerClass] alloc] initWithManager: dbmgr port: sPort];
    listener.delegate = self;
}

- (void)tearDown {
    listener.delegate = nil;
    [listener stop];
    ++sPort;
    [super tearDown];
}


- (void)testSSL_NoClientCert {
    if (!self.isSQLiteDB)
        return;
    NSError* error;
    Assert([listener setAnonymousSSLIdentityWithLabel: @"CBLUnitTests" error: &error],
           @"Failed to set SSL identity: %@", error);
    // Wait for listener to start:
    if (listener.port == 0) {
        [self keyValueObservingExpectationForObject: listener keyPath: @"port" expectedValue: @(sPort)];
        [listener start: NULL];
        [self waitForExpectationsWithTimeout: kTimeout handler: nil];
    }

    _expectAuthenticateTrust = [self expectationWithDescription: @"authenticateWithTrust"];
    [self connect];
}


- (void)testSSL_ClientCert {
    if (!self.isSQLiteDB)
        return;
    NSError* error;
    Assert([listener setAnonymousSSLIdentityWithLabel: @"CBLUnitTests" error: &error],
           @"Failed to set SSL identity: %@", error);
    // Wait for listener to start:
    if (listener.port == 0) {
        [self keyValueObservingExpectationForObject: listener keyPath: @"port" expectedValue: @(sPort)];
        [listener start: NULL];
        [self waitForExpectationsWithTimeout: kTimeout handler: nil];
    }

    SecIdentityRef identity = MYGetOrCreateAnonymousIdentity(@"CBLUnitTests-Client",
                                                     kMYAnonymousIdentityDefaultExpirationInterval,
                                                     &error);
    Assert(identity, @"Couldn't create client identity: %@", error);
    clientCredential = [NSURLCredential credentialWithIdentity: identity certificates: nil
                                                   persistence: NSURLCredentialPersistenceNone];

    _expectAuthenticateTrust = [self expectationWithDescription: @"authenticateWithTrust"];
    [self connect];
}


- (void) connect {
    NSURL* url = [[listener.URL URLByAppendingPathComponent: db.name]
                                      URLByAppendingPathComponent: @"_blipsync"];
    Log(@"Connecting to <%@>", url);
    BLIPPocketSocketConnection* conn = [[BLIPPocketSocketConnection alloc] initWithURL: url];
    [conn setDelegate: self queue: dispatch_get_main_queue()];
    conn.credential = clientCredential;

    NSError* error;
    Assert([conn connect: &error], @"Can't connect: %@", error);

    _expectValidateServerTrust = [self expectationWithDescription: @"validateServerTrust"];
    _expectDidOpen = [self expectationWithDescription: @"didOpen"];
    [self waitForExpectationsWithTimeout: kTimeout handler: nil];

    _expectDidClose = [self expectationWithDescription: @"didClose"];
    [conn close];
    [self waitForExpectationsWithTimeout: kTimeout handler: nil];
}


#pragma mark - CBLListenerDelegate


static NSString* addressToString(NSData* addrData) {
    if (!addrData)
        return nil;
    const struct sockaddr_in *addr = addrData.bytes;
    // Format it in readable (e.g. dotted-quad) form, with the port number:
    char nameBuf[INET6_ADDRSTRLEN];
    if (inet_ntop(addr->sin_family, &addr->sin_addr, nameBuf, (socklen_t)sizeof(nameBuf)) == NULL)
        return nil;
    return [NSString stringWithFormat: @"%s:%hu", nameBuf, ntohs(addr->sin_port)];
}


- (NSString*) authenticateConnectionFromAddress: (NSData*)address
                                      withTrust: (SecTrustRef)trust
{
    Log(@"authenticateConnectionFromAddress: %@ withTrust: %@",
        addressToString(address), trust);
    [_expectAuthenticateTrust fulfill];
    Assert(address != nil);
    if (clientCredential) {
        Assert(trust != nil);
        SecCertificateRef clientCert = SecTrustGetCertificateAtIndex(trust, 0);
        SecCertificateRef realClientCert;
        SecIdentityCopyCertificate(clientCredential.identity, &realClientCert);
        Assert(CFEqual(clientCert, realClientCert));
        CFRelease(realClientCert);
        return @"userWithClientCert";
    } else {
        AssertEq(trust, NULL);
        return @"";
    }
}


#pragma mark - BLIPConnectionDelegate

- (BOOL)blipConnection: (BLIPConnection*)connection
        validateServerTrust: (SecTrustRef)trust
{
    Log(@"validateServerTrust: %@", trust);
    [_expectValidateServerTrust fulfill];
    return YES;
}

- (void)blipConnectionDidOpen:(BLIPConnection*)connection {
    Log(@"didOpen");
    [_expectDidOpen fulfill];
}

- (void)blipConnection: (BLIPConnection*)connection
        didFailWithError: (NSError*)error
{
    XCTAssert(NO, @"Connection failed to open: %@", error);
}

- (void)blipConnection: (BLIPConnection*)connection
        didCloseWithError: (NSError*)error
{
    Log(@"didClose");
    XCTAssertNil(error, @"Unexpected error closing");
    XCTAssertNotNil(_expectDidClose);
    [_expectDidClose fulfill];
}


@end




@interface ListenerHTTP_Tests : Listener_Tests <CBLRemoteRequestDelegate>
@end


@implementation ListenerHTTP_Tests
{
    XCTestExpectation* _expectCheckServerTrust;
}

- (Class) listenerClass {
    return [CBLHTTPListener class];
}

- (void)testSSL_NoClientCert    {[super testSSL_NoClientCert];}
- (void)testSSL_ClientCert      {[super testSSL_ClientCert];}

- (void)testGetRange {
    // Create a document with an attachment:
    CBLDocument* doc = [db createDocument];
    CBLUnsavedRevision* newRev = [doc newRevision];
    NSData* attach = [@"This is the body of attach1" dataUsingEncoding: NSUTF8StringEncoding];
    [newRev setAttachmentNamed: @"attach" withContentType: @"text/plain" content: attach];
    Assert([newRev save: nil]);

    // Wait for listener to start:
    if (listener.port == 0) {
        [self keyValueObservingExpectationForObject: listener keyPath: @"port" expectedValue: @(sPort)];
        [listener start: NULL];
        [self waitForExpectationsWithTimeout: kTimeout handler: nil];
    }

    // URL to the attachment:
    NSString* path = [NSString stringWithFormat:@"%@/%@/attach", db.name, doc.documentID];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=5-15"} body: nil
       expectedStatus: 206 expectedHeaders: @{@"Content-Range": @"bytes 5-15/27"}
       expectedResult: [@"is the body" dataUsingEncoding: NSUTF8StringEncoding]];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=12-"} body: nil
       expectedStatus: 206 expectedHeaders: @{@"Content-Range": @"bytes 12-26/27"}
       expectedResult: [@"body of attach1" dataUsingEncoding: NSUTF8StringEncoding]];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=12-100"} body: nil
       expectedStatus: 206 expectedHeaders: @{@"Content-Range": @"bytes 12-26/27"}
       expectedResult: [@"body of attach1" dataUsingEncoding: NSUTF8StringEncoding]];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=-7"} body: nil
       expectedStatus: 206 expectedHeaders: @{@"Content-Range": @"bytes 20-26/27"}
       expectedResult: [@"attach1" dataUsingEncoding: NSUTF8StringEncoding]];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=5-3"} body: nil
       expectedStatus: 200 expectedHeaders: nil
       expectedResult: [@"This is the body of attach1" dataUsingEncoding: NSUTF8StringEncoding]];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=100-"} body: nil
       expectedStatus: 416 expectedHeaders: @{@"Content-Range": @"bytes */27"}
       expectedResult: nil];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=-100"} body: nil
       expectedStatus: 200 expectedHeaders: nil
       expectedResult: [@"This is the body of attach1" dataUsingEncoding: NSUTF8StringEncoding]];

    [self sendRequest: @"GET" path: path headers: @{@"Range": @"bytes=500-100"} body: nil
       expectedStatus: 200 expectedHeaders: nil
       expectedResult: [@"This is the body of attach1" dataUsingEncoding: NSUTF8StringEncoding]];
}


- (void) connect {
    Log(@"Connecting to <%@>", listener.URL);
    XCTestExpectation* expectDidComplete = [self expectationWithDescription: @"didComplete"];
    CBLRemoteRequest* req = [[CBLRemoteJSONRequest alloc] initWithMethod: @"GET" URL: listener.URL body: nil requestHeaders: nil onCompletion:^(id result, NSError *error) {
        AssertNil(error);
        Assert(result != nil);
        [expectDidComplete fulfill];
    }];

    if (clientCredential) {
        req.authorizer = [[CBLClientCertAuthorizer alloc] initWithIdentity: clientCredential.identity supportingCerts: clientCredential.certificates];
    }

    _expectCheckServerTrust = [self expectationWithDescription: @"checkServerTrust"];
    req.delegate = self;
    [req start];
    [self waitForExpectationsWithTimeout: kTimeout handler: nil];
}


- (BOOL) checkSSLServerTrust: (NSURLProtectionSpace*)protectionSpace {
    Log(@"checkSSLServerTrust called!");
    [_expectCheckServerTrust fulfill];
    SecCertificateRef cert = SecTrustGetCertificateAtIndex(protectionSpace.serverTrust, 0);
    SecCertificateRef realServerCert;
    SecIdentityCopyCertificate(listener.SSLIdentity, &realServerCert);
    Assert(CFEqual(cert, realServerCert));
    CFRelease(realServerCert);
    return YES;
}


- (void) sendRequest: (NSString*)method
                path: (NSString*)path
             headers: (NSDictionary*)headers
                body: (id)bodyObj
          onComplete: (void (^)(NSData *data, NSURLResponse *response, NSError *error))onComplete {
    NSURL* url = [NSURL URLWithString: path relativeToURL: listener.URL];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url];
    request.HTTPMethod = method;

    for (NSString* header in headers)
        [request setValue: headers[header] forHTTPHeaderField: header];

    if (bodyObj) {
        if ([bodyObj isKindOfClass: [NSData class]])
            request.HTTPBody = bodyObj;
        else {
            NSError* error = nil;
            request.HTTPBody = [CBLJSON dataWithJSONObject: bodyObj options:0 error:&error];
            AssertNil(error);
        }
    }

    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration: config];
    NSURLSessionDataTask *task = [session dataTaskWithRequest: request
                                            completionHandler:
                                  ^(NSData *data, NSURLResponse *response, NSError *error) {
                                      onComplete(data, response, error);
                                  }];
    [task resume];
}


- (void) sendRequest: (NSString*)method
                path: (NSString*)path
             headers: (NSDictionary*)headers
                body: (id)bodyObj
      expectedStatus: (NSInteger)expectedStatus
     expectedHeaders: (NSDictionary*)expectedHeader
      expectedResult: (NSData*)expectedResult {
    NSString* description = [NSString stringWithFormat:@"%@ %@", method, path];
    XCTestExpectation* exp = [self expectationWithDescription: description];

    [self sendRequest: method path: path headers: headers body: bodyObj
           onComplete: ^(NSData *data, NSURLResponse *response, NSError *error) {
               NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
               AssertEq(httpResponse.statusCode, expectedStatus);

               for (NSString* key in [expectedHeader allKeys])
                   AssertEqual(httpResponse.allHeaderFields[key], expectedHeader[key]);

               if (expectedResult)
                   AssertEqual(data, expectedResult);

               [exp fulfill];
           }];

    [self waitForExpectationsWithTimeout: kTimeout handler: nil];
}

@end
