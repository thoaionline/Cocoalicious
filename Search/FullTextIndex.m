//
//  FullTextIndex.m
//  Delicious Client
//
//  Created by Andrew Wooster on Sat Oct 16 2004.
//  Copyright (c) 2004 Andrew Wooster. All rights reserved.
// 

#import "FullTextIndex.h"

extern Boolean SKSearchFindMatches() __attribute__((weak_import));

static double kREQUEST_TIMEOUT_INTERVAL = 30.0;
static NSString *kUSER_AGENT_HTTP_HEADER = @"User-Agent";

@implementation FullTextIndex

- (id) init
{
	if (self = [super init]) {
        textIndex = nil;
        searching = NO;
        indexing = NO;
        indexLock = [[NSLock alloc] init];
        results = [[NSMutableSet alloc] init];
        resultsLock = [[NSLock alloc] init];
        searchLock = [[NSLock alloc] init];
        currentSearchID = 0;
	}
	return self;
}

- (void) dealloc
{
    [indexLock release];
    [results release];
    [resultsLock release];
    [searchLock release];
    [self closeIndex];
	[super dealloc];
}

- (SKIndexRef)textIndex
{
    [self flushIndex];
    return textIndex;
}

#pragma mark Index File Handling
- (void)openIndex
{
    // Check if index is already open.
    if (textIndex) {
        return;
    }
    
    NSString *indexPath = [self indexPath];
    NSURL *indexFileUrl = [NSURL fileURLWithPath: indexPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // Index file already exists.
    [indexLock lock];
    if ([fm fileExistsAtPath: indexPath]) {
        textIndex = SKIndexOpenWithURL((CFURLRef)indexFileUrl,
                                       (CFStringRef)kTEXT_INDEX_VERSION,
                                       true);
    }
    
    // Load existing index, if not already loaded.
    if (!textIndex) {
		CFDictionaryRef indexAttributes = NULL;
		
		// Switch based on Tiger or Panther SearchKit API's.
		if (SKSearchFindMatches != NULL) {
			// If we're using Tiger, turn on proximity indexing.
			indexAttributes = (CFDictionaryRef) [NSDictionary dictionaryWithObject: @"1" forKey: (NSString *) kSKProximityIndexing];
		}

        textIndex = SKIndexCreateWithURL((CFURLRef)indexFileUrl,
                                         // Actually index name.
                                         (CFStringRef)kTEXT_INDEX_VERSION,
                                         // Terms to documents.
                                         kSKIndexInverted,
                                         // No need to set these options.
                                         indexAttributes);
    }
    [indexLock unlock];
    
    //!! Doesn't do anything unless we use SKIndexAddDocument.
    //SKLoadDefaultExtractorPlugIns();
    NSAssert(textIndex, @"textIndex not loaded.");
}

- (void)closeIndex
{
    [indexLock lock];
    if (textIndex) {
        CFRelease(textIndex);
    }
    textIndex = nil;
    [indexLock unlock];
}

- (void)flushIndex
{
    [indexLock lock];
    if (textIndex) {
		if (AWOOSTER_DEBUG) {
			NSLog(@"flushing index");
		}
        if (!SKIndexFlush(textIndex)) {
			NSLog(@"flushing index failed");
		}
    }
    [indexLock unlock];
}

- (NSString *)indexPath
{
    return [[kTEXT_INDEX_PATH stringByAppendingPathComponent: kTEXT_INDEX_NAME]
        stringByExpandingTildeInPath];
}

- (NSMutableSet *)results
{
    // Since this can change at any time, return a copy.
    return [[results copy] autorelease];
}

- (BOOL)searching
{
    return searching;
}

- (BOOL)indexing
{
    return indexing;
}

#pragma mark Index Utilities
- (void)logIndexInformation
{
    [indexLock lock];
    if (textIndex != nil) {
        CFIndex numberOfDocuments = SKIndexGetDocumentCount(textIndex);
        NSLog(@"%d documents in index.", numberOfDocuments);
        CFIndex numberOfTerms = SKIndexGetMaximumTermID(textIndex);
        NSLog(@"%d terms in index.", numberOfTerms);
    } else {
        NSLog(@"No index loaded.");
    }
    [indexLock unlock];
}

#pragma mark Index Indexing
- (void)addDocumentToIndex:(NSURL *)url
               withContent:(NSString *)content
               inBatchMode:(BOOL)batchMode
{
    content = [self extractTextFromHTMLString: content];
    if (AWOOSTER_DEBUG) {
        NSLog(@"Adding %@", url);
        NSLog(@"With contents:");
        NSLog(@"%@", content);
    }
    if (!batchMode) {
        [self openIndex];
    }
    if (textIndex == nil) {
        NSLog(@"textIndex is nil, not processing: %@", [url absoluteString]);
        return;
    }
    [indexLock lock];
    indexing = YES;
    // CFURL's, funnily enough, don't preserve the entire URL.
    // Great.
    // So, instead, create an SKDocument with the name being the URL.
    SKDocumentRef document = SKDocumentCreate((CFStringRef)@"file",
                                              NULL,
                                              (CFStringRef)[url description]);
    if (!SKIndexAddDocumentWithText(textIndex,
                                    document,
                                    (CFStringRef)content,
                                    true)) {
        NSLog(@"There was a problem adding %@", [url absoluteString]);
    }
    CFRelease(document);
    
    indexing = NO;
    [indexLock unlock];
    if (!batchMode) {
        [self flushIndex];
    }
}

- (void) removeDocumentFromIndex: (NSURL *) documentURL {
    SKDocumentRef document = SKDocumentCreate((CFStringRef)@"file",
                                              NULL,
                                              (CFStringRef)[documentURL description]);
	
	SKIndexRemoveDocument(textIndex, document);
    
	CFRelease(document);
}

- (void) search: (NSDictionary *) searchDict {
    currentSearchID++;
    int thisSearchID = currentSearchID;
    
    // Wait for the current search to end.
    [searchLock lock]; [searchLock unlock];
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Get the properties out of the search dictionary.
    id anObject = [searchDict objectForKey:@"anObject"];
    SEL aSelector = 
        NSSelectorFromString([searchDict objectForKey:@"aSelector"]);
    NSString *query = [searchDict objectForKey:@"query"];

    if (!textIndex) {
        [self openIndex];
    }
    
    if (AWOOSTER_DEBUG) {
        NSLog(@"Searching for %@", query);
        [self logIndexInformation];
    }
    if (!textIndex) {
        NSLog(@"textIndex is nil, not processing search for: %@",
              query);
        [pool release];
        return;
    }
    
    [searchLock lock];
    
    if (thisSearchID != currentSearchID) {
        [searchLock unlock];
        [pool release];
        return;
    }
    
    [results removeAllObjects];
    searching = YES;
	
	// Switch based on Tiger or Panther SearchKit API's.
	// Panther
	if (SKSearchFindMatches == NULL) {
		// We need a search group.
		SKIndexRef indexArray[1];
		indexArray[0] = textIndex;
		CFArrayRef searchArray = CFArrayCreate(NULL,
											   (void *) indexArray,
											   1,
											   &kCFTypeArrayCallBacks);
		
		SKSearchGroupRef searchGroup = SKSearchGroupCreate(searchArray);

		SKSearchResultsRef searchResults
			= SKSearchResultsCreateWithQuery(searchGroup,
											 (CFStringRef)query,
											 kSKSearchRequiredRanked,
											 kTEXT_SEARCH_MAX_RESULTS,
											 NULL,
											 NULL);

		SKDocumentRef outDocumentsArray[kTEXT_SEARCH_CHUNK_SIZE];
		int resultCount = 0;
		int location;
		resultCount = SKSearchResultsGetCount(searchResults);
		if (AWOOSTER_DEBUG) {
			NSLog(@"%d results", resultCount);
		}
		for (location = 0; 
			 location < resultCount; 
			 location += kTEXT_SEARCH_CHUNK_SIZE) {
			int count = 
				SKSearchResultsGetInfoInRange(searchResults,
											  CFRangeMake(location,
														  kTEXT_SEARCH_CHUNK_SIZE),
											  outDocumentsArray,
											  NULL,
											  NULL);
			int i;
			for (i = 0; i < count; i++) {
				NSString *url = (NSString *)SKDocumentGetName(outDocumentsArray[i]);
				if (AWOOSTER_DEBUG) {
					NSLog(@"Matched document:  %@", url);
				}
				[resultsLock lock];
				[results addObject: url];
				[resultsLock unlock];
			}
			
			[anObject performSelectorOnMainThread: aSelector
									   withObject: [results copy]
									waitUntilDone: NO];
		}
		
		CFRelease(searchArray);
		CFRelease(searchGroup);
		CFRelease(searchResults);

	// Tiger SearchKit API
	} else {
		// Create a search.
		SKSearchRef search = SKSearchCreate(textIndex, (CFStringRef)query, kSKSearchOptionDefault);
		CFIndex maxResultCount = kTEXT_SEARCH_CHUNK_SIZE;
		CFIndex resultCount = 0;
		SKDocumentID documentIDs[kTEXT_SEARCH_CHUNK_SIZE];
		SKDocumentRef documentRefs[kTEXT_SEARCH_CHUNK_SIZE];
		
		while (SKSearchFindMatches(search, maxResultCount, documentIDs, NULL, 0, &resultCount) || resultCount > 0) {
			SKIndexCopyDocumentRefsForDocumentIDs(textIndex, resultCount, documentIDs, documentRefs);
			int i;
			for (i = 0; i < resultCount; i++) {
				NSString *url = (NSString *)SKDocumentGetName(documentRefs[i]);
				if (AWOOSTER_DEBUG) {
					NSLog(@"Matched document: %@", url);
				}
				[resultsLock lock];
				[results addObject: url];
				[resultsLock unlock];
			}
			[anObject performSelectorOnMainThread: aSelector
									   withObject: [results copy]
									waitUntilDone: NO];
		}
		CFRelease(search);
	}
    searching = NO;
    
    if (thisSearchID == currentSearchID) {
        // Inefficient, I know, but I need to make the calling thread aware that
        // we're done searching.
        [anObject performSelectorOnMainThread: aSelector
                                   withObject: [results copy]
                                waitUntilDone: NO];
    }
    [pool release];
    [searchLock unlock];
}

- (void) index:(NSDictionary *)indexDict
{
    //!! I should add a conditional indexing lock around all of this so
    // we only have one indexing thread going at once.
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    id anObject = [indexDict objectForKey:@"anObject"];
    SEL aSelector = 
        NSSelectorFromString([indexDict objectForKey:@"aSelector"]);
    NSArray *urls = [indexDict objectForKey:@"urls"];
    
	if ([anObject respondsToSelector: @selector(fullTextIndexBeganIndexingDocumentList:)]) {
		[anObject performSelectorOnMainThread: @selector(fullTextIndexBeganIndexingDocumentList:) withObject: urls  waitUntilDone: NO];
	}
	
    if (!urls) {
        [pool release];
        return;
    }
    [self openIndex];
    indexing = YES;
    
	[anObject performSelectorOnMainThread: aSelector
                               withObject: nil
                            waitUntilDone: NO];
	
	
    NSEnumerator *urlsEnum = [urls objectEnumerator];
    NSURL *currentURL;

    while ((currentURL = [urlsEnum nextObject]) != nil) {
        NSAutoreleasePool *whilePool = [[NSAutoreleasePool alloc] init];
		NSString *contents = [self sendRequestForURI: currentURL 
                   usingCachePolicy: NSURLRequestReloadIgnoringCacheData];
        contents = [self extractTextFromHTMLString: contents];
        [self addDocumentToIndex: currentURL
                     withContent: [[contents copy] autorelease]
                     inBatchMode: YES];
        [contents release];
		
		if ([anObject respondsToSelector: @selector(fullTextIndexIndexedDocumentWithURL:)]) {
			[anObject performSelectorOnMainThread: @selector(fullTextIndexIndexedDocumentWithURL:) withObject: currentURL waitUntilDone: NO];
		}
		
		[whilePool release];
    }
    indexing = NO;
    [self flushIndex];
    [anObject performSelectorOnMainThread: aSelector
                               withObject: nil
                            waitUntilDone: NO];

	if ([anObject respondsToSelector: @selector(fullTextIndexFinishedIndexingDocumentList:)]) {
		[anObject performSelectorOnMainThread: @selector(fullTextIndexFinishedIndexingDocumentList:) withObject: urls waitUntilDone: NO];
	}

    [pool release];
}


- (NSString *) sendRequestForURI: (NSURL *) apiURL 
                usingCachePolicy: (NSURLRequestCachePolicy) cachePolicy 
{
    NSMutableURLRequest *req = 
        [NSMutableURLRequest requestWithURL: apiURL 
                                cachePolicy: cachePolicy 
                            timeoutInterval: kREQUEST_TIMEOUT_INTERVAL];
	
    [req setValue: kUSER_AGENT forHTTPHeaderField: kUSER_AGENT_HTTP_HEADER];
    
    NSURLResponse *resp;
    NSError *error;
	
	NSData *returnData = [NSURLConnection sendSynchronousRequest: req 
                                               returningResponse: &resp 
                                                           error: &error];
    // We need to make a copy here, in case the encoding conversion fails, in
    // which case we need to try initing a string as a cstring from the data.
    NSData *returnDataCopy = [NSData dataWithBytes: [returnData bytes] 
                                            length: [returnData length]];
    
    if (AWOOSTER_DEBUG) {
        NSLog(@"mime-type: %@\ntext-encoding:%@\nfilename: %@", [resp MIMEType],
              [resp textEncodingName], 
              [resp suggestedFilename]);
        NSLog(@"length: %u", [returnData length]);
    }
	
	if (![[resp MIMEType] hasPrefix:@"text"] && ![[resp MIMEType] hasSuffix:@"html"] && ![[resp MIMEType] hasSuffix:@"xml"]) {
		return @"";
	}

    NSString *nsStrEncoding = [resp textEncodingName];
    if (!nsStrEncoding) {
        [nsStrEncoding release];
        nsStrEncoding = @"ISO_8859-1"; // ISO Latin 1
    }
    CFStringEncoding cfEncoding = 
        CFStringConvertIANACharSetNameToEncoding(
            (CFStringRef)nsStrEncoding);
    if (cfEncoding == kCFStringEncodingInvalidId) {
        cfEncoding = kCFStringEncodingISOLatin1;
    }

    NSStringEncoding encoding = 
        CFStringConvertEncodingToNSStringEncoding(cfEncoding);

    NSString *contents = [[NSString alloc] initWithBytes: [returnData bytes]
                                                  length: [returnData length]
                                               encoding: encoding];

    if (!contents) {
        [contents release];
        contents = [[NSString alloc] initWithCString: [returnDataCopy bytes]
                                              length: [returnDataCopy length]];
    }
    
    if (error) { 
		NSLog(@"Error: %@", [error description]);
	}
  
	return contents;
}

- (NSString *)extractTextFromHTMLString: (NSString *)html
{
	NSMutableString *result = [[NSMutableString alloc] init];
	
	// Tiger
	Class nsxmldoc = NSClassFromString(@"NSXMLDocument");
	if (nsxmldoc != nil) {
		NSError *err = nil;
		NSXMLDocument *doc = [[nsxmldoc alloc] initWithXMLString:html options:(NSXMLNodePreserveAll|NSXMLDocumentTidyHTML) error:&err];
		if (doc == nil) {
			return result;
		}
		
		// Walk the tree.
		{
			// Get all meta keywords tags.
			NSArray *nodes = [doc nodesForXPath:@".//meta" error:&err];
			int i;
			for (i = 0; i < [nodes count]; i++) {
				NSXMLNode *attr = [[nodes objectAtIndex:i] attributeForName:@"name"];
				if (nil != attr && [[attr stringValue] isEqualToString:@"keywords"]) {
					attr = [[nodes objectAtIndex:i] attributeForName:@"content"];
					if (nil != attr) {
						[result appendString:[attr stringValue]];
						[result appendString:@"\n"];
					}
				}
			}
			
			// Get all text nodes.
			NSXMLNode *aNode = [doc rootElement];
			while (aNode = [aNode nextNode]) {
				if ([aNode kind] == NSXMLTextKind && ![[[aNode parent] name] isEqualToString:@"script"] && ![[[aNode parent] name] isEqualToString:@"style"]) {
					[result appendString:[aNode stringValue]];
					[result appendString:@"\n"];
				}
			}
		}
		[doc release];
	// Panther
	} else {
		// If we were given a nil string, return;
		if (nil == html) {
			return result;
		}
		NSString *tempString;
		NSCharacterSet *leftBracketSet;
		NSCharacterSet *rightBracketSet;
		NSScanner *theScanner = [NSScanner scannerWithString:html];
		
		leftBracketSet = [NSCharacterSet
			characterSetWithCharactersInString:@"<"];
		rightBracketSet = [NSCharacterSet
			characterSetWithCharactersInString:@">"];
		
		while ([theScanner isAtEnd] == NO) {
			if ([theScanner scanUpToCharactersFromSet: leftBracketSet
										   intoString: &tempString]) {
				[result appendString: tempString];
				[result appendString: @"\n"];
			}
			if ([theScanner scanString:@"<" intoString: NULL] &&
				[theScanner scanUpToCharactersFromSet:rightBracketSet
										   intoString: NULL] &&
				[theScanner scanString:@">" intoString: NULL]) {
			}
		}
	}
	return result;
}
@end
