//
//  PocketAPIOperation.m
//  PocketSDK
//
//  Created by Steve Streza on 5/29/12.
//  Copyright (c) 2012 Read It Later, Inc.
//  
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this
//  software and associated documentation files (the "Software"), to deal in the Software
//  without restriction, including without limitation the rights to use, copy, modify, 
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to 
//  permit persons to whom the Software is furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in all copies or
//  substantial portions of the Software.
//  
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING 
//  BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND 
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, 
//  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import "PocketAPIOperation.h"

NSString *PocketAPINameForHTTPMethod(PocketAPIHTTPMethod method){
	switch (method) {
		case PocketAPIHTTPMethodPOST:
			return @"POST";
			break;
		case PocketAPIHTTPMethodPUT:
			return @"PUT";
			break;
		case PocketAPIHTTPMethodDELETE:
			return @"DELETE";
			break;
		case PocketAPIHTTPMethodGET:
		default:
			return @"GET";
			break;
	}
}

@interface PocketAPI ()
-(void)pkt_loggedInWithUsername:(NSString *)username token:(NSString *)accessToken;
-(NSString *)pkt_userAgent;
-(NSString *)pkt_getToken;
-(NSOperationQueue *)pkt_operationQueue;
@end

@interface PocketAPIOperation ()

-(void)pkt_connectionFinishedLoading;

-(NSMutableURLRequest *)pkt_URLRequest;

@end

@implementation PocketAPIOperation

@synthesize API, delegate, error;

@synthesize domain, HTTPMethod, APIMethod, arguments;
@synthesize connection, response, data;

-(void)start{
	finishedLoading = NO;

	NSURLRequest *request = [self pkt_URLRequest];
	connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	[connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	
	[connection start];
}

-(BOOL)isConcurrent{
	return YES;
}

-(BOOL)isExecuting{
	return !finishedLoading;
}

-(BOOL)isFinished{
	return finishedLoading;
}

-(id)init{
	if(self = [super init]){
		domain = PocketAPIDomainDefault;
	}
	return self;
}

-(void)dealloc{
	[API release], API = nil;
	delegate = nil;
	
	[APIMethod release], APIMethod = nil;
	[arguments release], arguments = nil;
	
	[connection release], connection = nil;
	[response release], response = nil;
	[data release], data = nil;

	[error release], error = nil;
	
	[super dealloc];
}

-(NSString *)description{
	return [NSString stringWithFormat:@"<%@: %p https://%@%@ %@>", [self class], self, self.baseURLPath, self.APIMethod, self.arguments];
}

-(NSString *)baseURLPath{
	switch (self.domain) {
		case PocketAPIDomainAuth:
			return @"getpocket.com/v3/oauth";
			break;
		case PocketAPIDomainDefault:
		default:
			return @"getpocket.com/v3";
			break;
	}
}

-(NSDictionary *)responseDictionary{
	NSString *contentType = [[self.response allHeaderFields] objectForKey:@"Content-Type"];
	if([contentType isEqualToString:@"application/json"]){
		return [NSJSONSerialization JSONObjectWithData:self.data options:0 error:nil];
	}else{
		return nil;
	}
}

#pragma mark NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)aConnection didReceiveResponse:(NSURLResponse *)receivedResponse{
	response = (NSHTTPURLResponse *)[receivedResponse retain];
	if([response statusCode] == 200){
		data = [[NSMutableData alloc] initWithCapacity:0];
	}else if([[response allHeaderFields] objectForKey:@"X-Error"]){
		[connection cancel];
        NSString *xError = [[response allHeaderFields] objectForKey:@"X-Error"];
        NSDictionary *userInfo = xError ? [NSDictionary dictionaryWithObjectsAndKeys:xError,NSLocalizedDescriptionKey,nil] : nil;
		[self connection:connection didFailWithError:[NSError errorWithDomain:@"PocketSDK" 
																		 code:[response statusCode] 
																	 userInfo:userInfo]];
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)inData{
	[data appendData:inData];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)theError{
	NSUInteger statusCode = [self.response statusCode];
	[self connectionFinishedWithStatusCode:statusCode error:theError];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection{
	NSUInteger statusCode = [self.response statusCode];
	[self connectionFinishedWithStatusCode:statusCode error:nil];
}

-(void)connectionFinishedWithStatusCode:(NSUInteger)statusCode error:(NSError *)theError{
	BOOL needsToRelogin = statusCode == 401;
	BOOL needsToLogout = statusCode == 403;
	if(!theError && statusCode >= 400){
		theError = [NSError errorWithDomain:@"PocketSDK"
									   code:statusCode
								   userInfo:nil];
	}
	
	error = [theError retain];
	
	if(self.delegate && [self.delegate respondsToSelector:@selector(pocketAPI:receivedResponse:forAPIMethod:error:)]){
		[self.delegate pocketAPI:self.API receivedResponse:[self responseDictionary] forAPIMethod:self.APIMethod error:theError];
	}
	
	// if the user has deauthorized the app, we bounce them to the Pocket to re-login
	// if this succeeds, we re-call the API the app requested
	// if it fails, then prompt for an error next time
	if(needsToRelogin){
		[self.API loginWithDelegate:self];
		return;
	}
	
	if(needsToLogout){
		[self.API logout];
	}
	
	if(theError){
		if([self.APIMethod rangeOfString:@"auth"].location != NSNotFound){
			if(self.delegate && [self.delegate respondsToSelector:@selector(pocketAPI:hadLoginError:)]){
				[self.delegate pocketAPI:self.API hadLoginError:error];
			}
		}else if([self.APIMethod isEqualToString:@"send"]){
			if(self.delegate && [self.delegate respondsToSelector:@selector(pocketAPI:failedToSaveURL:error:)]){
				[self.delegate pocketAPI:self.API
						 failedToSaveURL:[NSURL URLWithString:[self.arguments objectForKey:@"url"]]
								   error:error];
			}
		}
	}else{
		if([self.APIMethod isEqualToString:@"auth"]){
			[self.API pkt_loggedInWithUsername:[self.arguments objectForKey:@"username"] token:[self.arguments objectForKey:@"token"]];
			
			if(self.delegate && [self.delegate respondsToSelector:@selector(pocketAPILoggedIn:)]){
				[self.delegate pocketAPILoggedIn:self.API];
			}
		}else if([self.APIMethod isEqualToString:@"send"]){
			if(self.delegate && [self.delegate respondsToSelector:@selector(pocketAPI:savedURL:)]){
				NSString *urlString = [[[self.arguments objectForKey:@"actions"] objectAtIndex:0] objectForKey:@"url"];
				NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
				[self.delegate pocketAPI:self.API
								savedURL:url];
			}
		}
		else if([self.APIMethod isEqualToString:@"request"]){
			NSDictionary *responseDict = [self responseDictionary];
			[self.delegate pocketAPI:self.API receivedRequestToken:[responseDict objectForKey:@"code"]];
		}
		else if([self.APIMethod isEqualToString:@"authorize"] || [self.APIMethod isEqualToString:@"oauth/authorize"]){
			NSDictionary *responseDict = [self responseDictionary];
			NSString *username = [responseDict objectForKey:@"username"];
			NSString *token = [responseDict objectForKey:@"access_token"];
			
			if((id)username == [NSNull null] && (id)token == [NSNull null]){
				[self.delegate pocketAPI:self.API hadLoginError:[NSError errorWithDomain:@"PocketAPI" code:404 userInfo:nil]];
			}else{
				[self.API pkt_loggedInWithUsername:username token:token];
				if(self.delegate && [self.delegate respondsToSelector:@selector(pocketAPILoggedIn:)]){
					[self.delegate pocketAPILoggedIn:self.API];
				}
			}
		}
	}
	[self pkt_connectionFinishedLoading];
}

#pragma mark Handling Re-login

-(void)pocketAPILoggedIn:(PocketAPI *)api{
	[[self.API pkt_operationQueue] addOperation:[[self copy] autorelease]];
}

-(void)pocketAPI:(PocketAPI *)api hadLoginError:(NSError *)theError{
	[self connectionFinishedWithStatusCode:403 error:theError];
}

#pragma mark Private APIs

-(NSDictionary *)pkt_requestArguments{
	NSMutableDictionary *dict = [[self.arguments mutableCopy] autorelease];
	if(self.API.consumerKey){
		[dict setObject:self.API.consumerKey forKey:@"consumer_key"];
	}

	NSString *accessToken = [self.API pkt_getToken];
	if(accessToken){
		[dict setObject:accessToken forKey:@"access_token"];
	}
	
	return dict;
}

-(NSMutableURLRequest *)pkt_URLRequest{
	NSString *urlString = [NSString stringWithFormat:@"https://%@/%@", self.baseURLPath, self.APIMethod];
	
	NSDictionary *requestArgs = [self pkt_requestArguments];

	if(self.HTTPMethod == PocketAPIHTTPMethodGET && requestArgs.count > 0){
		NSMutableArray *pairs = [NSMutableArray array];
		
		for(NSString *key in [requestArgs allKeys]){
			[pairs addObject:[NSString stringWithFormat:@"%@=%@",key, [PocketAPIOperation encodeForURL:[requestArgs objectForKey:key]]]];
		}
		
		if(pairs.count > 0){
			urlString = [urlString stringByAppendingFormat:@"?%@", [pairs componentsJoinedByString:@"&"]];
		}
	}
	
	NSURL *url = [NSURL URLWithString:urlString];
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
	[request setHTTPMethod:PocketAPINameForHTTPMethod(self.HTTPMethod)];
	
	if(self.HTTPMethod != PocketAPIHTTPMethodGET && requestArgs.count > 0){
		[request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
		[request setHTTPBody:[NSJSONSerialization dataWithJSONObject:requestArgs options:0 error:nil]];
	}
	
	NSString *userAgent = [self.API pkt_userAgent];
	if(userAgent){
		[request addValue:userAgent forHTTPHeaderField:@"User-Agent"];
	}
	
	[request addValue:@"application/json" forHTTPHeaderField:@"X-Accept"];
	
	return [request autorelease];
}

+(NSString *)encodeForURL:(NSString *)urlStr
{
	NSString *result = (NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                           (CFStringRef)urlStr,
                                                                           NULL,
																		   CFSTR("!*'();:@&=+$,/?%#[]"),
                                                                           kCFStringEncodingUTF8);
	return [result autorelease];
}

-(void)pkt_connectionFinishedLoading{
	[self willChangeValueForKey:@"isExecuting"];
	[self willChangeValueForKey:@"isFinished"];
	finishedLoading = YES;
	[self  didChangeValueForKey:@"isFinished"];
	[self  didChangeValueForKey:@"isExecuting"];

	[delegate release], delegate = nil;
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone{
	PocketAPIOperation *operation = [[PocketAPIOperation allocWithZone:zone] init];
	operation.API = self.API;
	operation.delegate = self.delegate;
	operation.domain = self.domain;
	operation.HTTPMethod = self.HTTPMethod;
	operation.APIMethod = self.APIMethod;
	operation.arguments = self.arguments;
	return operation;
}

@end