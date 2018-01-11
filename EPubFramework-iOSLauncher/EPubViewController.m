//
//  EPubViewController.m
//  SDKLauncher-iOS
//
//  Created by Shane Meyer on 6/5/13.
//  Copyright (c) 2014 Readium Foundation and/or its licensees. All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without modification, 
//  are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright notice, this 
//  list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice, 
//  this list of conditions and the following disclaimer in the documentation and/or 
//  other materials provided with the distribution.
//  3. Neither the name of the organization nor the names of its contributors may be 
//  used to endorse or promote products derived from this software without specific 
//  prior written permission.
//  
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. 
//  IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, 
//  INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
//  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
//  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF 
//  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE 
//  OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED 
//  OF THE POSSIBILITY OF SUCH DAMAGE.

#import "EPubViewController.h"
#include <RDFramework/RDContainer.h>
#include <RDFramework/RDNavigationElement.h>
#include <RDFramework/RDPackage.h>
#include <RDFramework/RDPackageResourceServer.h>
#include <RDFramework/RDSpineItem.h>
#import <WebKit/WebKit.h>


@interface EPubViewController () <
	RDPackageResourceServerDelegate,
	UIAlertViewDelegate,
	UIPopoverControllerDelegate,
	UIWebViewDelegate,WKUIDelegate,
	WKScriptMessageHandler,UIGestureRecognizerDelegate>
{
	@private RDContainer *m_container;
	@private BOOL m_currentPageCanGoLeft;
	@private BOOL m_currentPageCanGoRight;
	@private BOOL m_currentPageIsFixedLayout;
	@private NSArray* m_currentPageOpenPagesArray;
	@private BOOL m_currentPageProgressionIsLTR;
	@private int m_currentPageSpineItemCount;
	@private NSString *m_initialCFI;
	@private BOOL m_moIsPlaying;
	@private RDNavigationElement *m_navElement;
	@private RDPackage *m_package;
	@private RDPackageResourceServer *m_resourceServer;
	@private RDSpineItem *m_spineItem;
	@private __weak UIWebView *m_webViewUI;
	@private __weak WKWebView *m_webViewWK;
}

@end


@implementation EPubViewController

- (void)cleanUp {
    if (m_webViewWK != nil) {
        [m_webViewWK.configuration.userContentController removeScriptMessageHandlerForName:@"readium"];
    }
    
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	m_moIsPlaying = NO;
}


- (BOOL)commonInit {

	// Load the special payloads. This is optional (the payloads can be nil), in which case
	// MathJax and annotations.css functionality will be disabled.

	NSBundle *bundle = [NSBundle mainBundle];
	NSString *path = [bundle pathForResource:@"annotations" ofType:@"css"];
	NSData *payloadAnnotations = (path == nil) ? nil : [[NSData alloc] initWithContentsOfFile:path];
	path = [bundle pathForResource:@"MathJax" ofType:@"js" inDirectory:@"mathjax"];
	NSData *payloadMathJax = (path == nil) ? nil : [[NSData alloc] initWithContentsOfFile:path];

	m_resourceServer = [[RDPackageResourceServer alloc]
		initWithDelegate:self
		package:m_package
		specialPayloadAnnotationsCSS:payloadAnnotations
		specialPayloadMathJaxJS:payloadMathJax];

	if (m_resourceServer == nil) {
		return NO;
	}

	// Configure the package's root URL. Rather than "localhost", "127.0.0.1" is specified in the
	// following URL to work around an issue introduced in iOS 7.0. When an iOS 7 device is offline
	// (Wi-Fi off, or airplane mode on), audio and video fails to be served by UIWebView / QuickTime,
	// even though being offline is irrelevant for an embedded HTTP server. Daniel suggested trying
	// 127.0.0.1 in case the underlying issue was host name resolution, and it works.

	m_package.rootURL = [NSString stringWithFormat:@"http://127.0.0.1:%d/", m_resourceServer.port];

    // Observe application background/foreground notifications
    // HTTP server becomes unreachable after the application has become inactive
    // so we need to stop and restart it whenever it happens
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppWillResignActiveNotification:) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppWillEnterForegroundNotification:) name:UIApplicationWillEnterForegroundNotification object:nil];
	return YES;
}


- (void)
	executeJavaScript:(NSString *)javaScript
	completionHandler:(void (^)(id response, NSError *error))completionHandler
{
	if (m_webViewUI != nil) {
		NSString *response = [m_webViewUI stringByEvaluatingJavaScriptFromString:javaScript];
		if (completionHandler != nil) {
			completionHandler(response, nil);
		}
	}
	else if (m_webViewWK != nil) {
		[m_webViewWK evaluateJavaScript:javaScript completionHandler:^(id response, NSError *error) {
			if (error != nil) {
				NSLog(@"%@", error);
			}
			if (completionHandler != nil) {
				if ([NSThread isMainThread]) {
					completionHandler(response, error);
				}
				else {
					dispatch_async(dispatch_get_main_queue(), ^{
						completionHandler(response, error);
					});
				}
			}
		}];
	}
	else if (completionHandler != nil) {
		completionHandler(nil, nil);
	}
}


- (void)handleMediaOverlayStatusDidChange:(NSString *)payload {
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (error != nil || dict == nil || ![dict isKindOfClass:[NSDictionary class]]) {
        NSLog(@"The mediaOverlayStatusDidChange payload is invalid! (%@, %@)", error, dict);
    }
    else {
        NSNumber *n = dict[@"isPlaying"];

        if (n != nil && [n isKindOfClass:[NSNumber class]]) {
            m_moIsPlaying = n.boolValue;
        }
    }
}


- (void)handlePageDidChange:(NSString *)payload {
	NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
	NSError *error = nil;
	NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

	if (error != nil || dict == nil || ![dict isKindOfClass:[NSDictionary class]]) {
		NSLog(@"The pageDidChange payload is invalid! (%@, %@)", error, dict);
	}
	else {
		NSNumber *n = dict[@"canGoLeft_"];
		m_currentPageCanGoLeft = [n isKindOfClass:[NSNumber class]] && n.boolValue;

		n = dict[@"canGoRight_"];
		m_currentPageCanGoRight = [n isKindOfClass:[NSNumber class]] && n.boolValue;

		n = dict[@"isRightToLeft"];
		m_currentPageProgressionIsLTR = [n isKindOfClass:[NSNumber class]] && !n.boolValue;

		n = dict[@"isFixedLayout"];
		m_currentPageIsFixedLayout = [n isKindOfClass:[NSNumber class]] && n.boolValue;

		n = dict[@"spineItemCount"];
		m_currentPageSpineItemCount = [n isKindOfClass:[NSNumber class]] ? n.intValue : 0;

		NSArray *array = dict[@"openPages"];
		m_currentPageOpenPagesArray = [array isKindOfClass:[NSArray class]] ? array : nil;

		if (m_webViewUI != nil) {
			m_webViewUI.hidden = NO;
		}
		else if (m_webViewWK != nil) {
			m_webViewWK.hidden = NO;
		}

	}
}

-(NSDictionary *)settingsDictionary{
    return @{@"columnGap" : [NSNumber numberWithInt:20],
            @"fontSize" : [NSNumber numberWithInt:150],
            @"scroll" : @"auto",
             @"syntheticSpread" : @"single"};
}

- (void)handleReaderDidInitialize {
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	dict[@"package"] = m_package.dictionary;
    dict[@"settings"] = [self settingsDictionary];

	NSDictionary *pageDict = nil;

	if (m_spineItem == nil) {
	}
	else if (m_initialCFI != nil && m_initialCFI.length > 0) {
		pageDict = @{
			@"idref" : m_spineItem.idref,
			@"elementCfi" : m_initialCFI
		};
	}
	else if (m_navElement.content != nil && m_navElement.content.length > 0) {
		pageDict = @{
			@"contentRefUrl" : m_navElement.content,
			@"sourceFileHref" : (m_navElement.sourceHref == nil ?
				@"" : m_navElement.sourceHref)
		};
	}
	else {
		pageDict = @{
			@"idref" : m_spineItem.idref
		};
	}

	if (pageDict != nil) {
		dict[@"openPageRequest"] = pageDict;
	}

	NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];

	if (data != nil) {
		NSString *arg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		arg = [NSString stringWithFormat:@"ReadiumSDK.reader.openBook(%@)", arg];
		[self executeJavaScript:arg completionHandler:nil];
	}
}


- (instancetype)
	initWithContainer:(RDContainer *)container
	package:(RDPackage *)package
{
	return [self initWithContainer:container package:package spineItem:nil cfi:nil];
}





- (instancetype)
	initWithContainer:(RDContainer *)container
	package:(RDPackage *)package
	spineItem:(RDSpineItem *)spineItem
	cfi:(NSString *)cfi
{
	if (container == nil || package == nil) {
		return nil;
	}

	if (spineItem == nil && package.spineItems.count > 0) {
		spineItem = [package.spineItems objectAtIndex:0];
	}

	if (spineItem == nil) {
		return nil;
	}

	if (self = [super initWithTitle:package.title navBarHidden:NO]) {
		m_container = container;
		m_initialCFI = cfi;
		m_package = package;
		m_spineItem = spineItem;

		if (![self commonInit]) {
			return nil;
		}
	}

	return self;
}


- (void)loadView {
	self.view = [[UIView alloc] init];
	self.view.backgroundColor = [UIColor whiteColor];
    
    //add swipe gesture recognizer
    UISwipeGestureRecognizer *rightSwipe = [[UISwipeGestureRecognizer alloc]initWithTarget:self action:@selector(onClickPrev)];
    rightSwipe.direction = UISwipeGestureRecognizerDirectionRight;
//    rightSwipe.delegate = self;
    
    UISwipeGestureRecognizer *leftSwipe = [[UISwipeGestureRecognizer alloc]initWithTarget:self action:@selector(onClickNext)];
    leftSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
//    leftSwipe.delegate = self;

	// Notifications
	// Create the web view. The choice of web view type is based on the existence of the WKWebView
	// class, but this could be decided some other way.
    
    // The "no optimize" RequireJS option means that the entire "readium-shared-js" folder must be copied in to the OSX app bundle's "scripts" folder! (including "node_modules" subfolder, which is populated when invoking the "npm run prepare" build command) There is therefore some significant filesystem / size overhead, but the benefits are significant too: no need for the WebView to fetch sourcemaps, and to attempt to un-mangle the obfuscated Javascript during debugging.
    // However, the recommended development-time pattern is to invoke "npm run build" in order to refresh the "build-output" folder, with the RJS_UGLY environment variable set to "false" or "no". This way, the RequireJS single/multiple bundle(s) will be in readable uncompressed form.
    //NSString* readerFileName = @"reader_RequireJS-no-optimize.html";
    
    //NSString* readerFileName = @"reader_RequireJS-multiple-bundles.html";
    NSString* readerFileName = @"reader_RequireJS-single-bundle.html";
    
  

	if ([WKWebView class] != nil) {
		WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
		config.allowsInlineMediaPlayback = YES;
//        config.mediaPlaybackRequiresUserAction = NO;

		// Configure a "readium" message handler, which is used by host_app_feedback.js.

		WKUserContentController *contentController = [[WKUserContentController alloc] init];
		[contentController addScriptMessageHandler:self name:@"readium"];
		config.userContentController = contentController;

		WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
		m_webViewWK = webView;
        webView.hidden = YES;
		webView.scrollView.bounces = NO;
        [webView addGestureRecognizer:rightSwipe];
        [webView addGestureRecognizer:leftSwipe];
        [self.view addSubview:webView];

		// RDPackageResourceConnection looks at corePaths and corePrefixes in the following
		// query string to determine what core resources it should provide responses for. Since
		// WKWebView can't handle file URLs, the web server must provide these resources.

		NSString *url = [NSString stringWithFormat:
			@"%@%@?"
			@"corePaths=readium-shared-js_all.js,readium-shared-js_all.js.map,epubReadingSystem.js,host_app_feedback.js,sdk.css&"
			@"corePrefixes=readium-shared-js",
			m_package.rootURL,
			readerFileName];

		[webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
	}
	else {
		UIWebView *webView = [[UIWebView alloc] init];
		m_webViewUI = webView;
		webView.delegate = self;
		webView.hidden = YES;
		webView.scalesPageToFit = YES;
		webView.scrollView.bounces = NO;
		webView.allowsInlineMediaPlayback = YES;
		webView.mediaPlaybackRequiresUserAction = NO;
        [webView addGestureRecognizer:rightSwipe];
        [webView addGestureRecognizer:leftSwipe];
		[self.view addSubview:webView];

		NSURL *url = [[NSBundle mainBundle] URLForResource:readerFileName withExtension:nil];
		[webView loadRequest:[NSURLRequest requestWithURL:url]];
	}
}

- (void)onClickMONext {
	[self executeJavaScript:@"ReadiumSDK.reader.nextMediaOverlay()" completionHandler:nil];
}


- (void)onClickMOPause {
	[self executeJavaScript:@"ReadiumSDK.reader.toggleMediaOverlay()" completionHandler:nil];
}


- (void)onClickMOPlay {
	[self executeJavaScript:@"ReadiumSDK.reader.toggleMediaOverlay()" completionHandler:nil];
}


- (void)onClickMOPrev {
	[self executeJavaScript:@"ReadiumSDK.reader.previousMediaOverlay()" completionHandler:nil];
}


- (void)onClickNext {
	[self executeJavaScript:@"ReadiumSDK.reader.openPageNext()" completionHandler:nil];
}


- (void)onClickPrev {
	[self executeJavaScript:@"ReadiumSDK.reader.openPagePrev()" completionHandler:nil];
}

- (void)
	packageResourceServer:(RDPackageResourceServer *)packageResourceServer
	executeJavaScript:(NSString *)javaScript
{
	if ([NSThread isMainThread]) {
		[self executeJavaScript:javaScript completionHandler:nil];
	}
	else {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self executeJavaScript:javaScript completionHandler:nil];
		});
	}
}



- (void)
	userContentController:(WKUserContentController *)userContentController
	didReceiveScriptMessage:(WKScriptMessage *)message
{
	if (![NSThread isMainThread]) {
		NSLog(@"A script message unexpectedly arrived on a non-main thread!");
	}

	NSArray *body = message.body;

	if (message.name == nil ||
		![message.name isEqualToString:@"readium"] ||
		body == nil ||
		![body isKindOfClass:[NSArray class]] ||
		body.count == 0 ||
		![body[0] isKindOfClass:[NSString class]])
	{
		NSLog(@"Invalid script message! (%@, %@)", message.name, message.body);
		return;
	}

	NSString *messageName = body[0];

	if ([messageName isEqualToString:@"mediaOverlayStatusDidChange"]) {
		if (body.count < 2 || ![body[1] isKindOfClass:[NSString class]]) {
			NSLog(@"The mediaOverlayStatusDidChange payload is invalid!");
		}
		else {
			[self handleMediaOverlayStatusDidChange:body[1]];
		}
	}
	else if ([messageName isEqualToString:@"pageDidChange"]) {
		if (body.count < 2 || ![body[1] isKindOfClass:[NSString class]]) {
			NSLog(@"The pageDidChange payload is invalid!");
		}
		else {
			[self handlePageDidChange:body[1]];
		}
	}
	else if ([messageName isEqualToString:@"readerDidInitialize"]) {
		[self handleReaderDidInitialize];
	}
}


- (void)viewDidLayoutSubviews {
	CGSize size = self.view.bounds.size;
	if (m_webViewUI != nil) {
        [m_webViewUI setUserInteractionEnabled:YES];
		m_webViewUI.frame = self.view.bounds;
	}
	else if (m_webViewWK != nil) {
        [m_webViewWK setUserInteractionEnabled:YES];
		self.automaticallyAdjustsScrollViewInsets = NO;
		CGFloat y0 = self.topLayoutGuide.length;
		CGFloat y1 = size.height - self.bottomLayoutGuide.length;
		m_webViewWK.frame = CGRectMake(0, y0, size.width, y1 - y0);
		m_webViewWK.scrollView.contentInset = UIEdgeInsetsZero;
		m_webViewWK.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
	}
}


- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];

	if (self.navigationController != nil) {
		[self.navigationController setToolbarHidden:NO animated:YES];
	}
}


- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];

	if (self.navigationController != nil) {
		[self.navigationController setToolbarHidden:YES animated:YES];
	}
}


- (BOOL)
	webView:(UIWebView *)webView
	shouldStartLoadWithRequest:(NSURLRequest *)request
	navigationType:(UIWebViewNavigationType)navigationType
{
	BOOL shouldLoad = YES;
	NSString *url = request.URL.absoluteString;
	NSString *s = @"epubobjc:";
    
    // When opening the web inspector from Safari (on desktop OSX), the Javascript sourcemaps are requested and fetched automatically based on the location of their source file counterpart. In other words, no need for intercepting requests below (or via NSURLProtocol), unlike the OSX ReadiumSDK launcher app which requires building custom URL responses containing the sourcemap payload. This needs testing with WKWebView though (right now this works fine with UIWebView because local resources are fetched from the file:// app bundle.
    if ([url hasSuffix:@".map"]) {
        NSLog(@"%@", [NSString stringWithFormat:@"WEBVIEW-REQUESTED SOURCEMAP: %@", url]);
    }
    
	if ([url hasPrefix:s]) {
		url = [url substringFromIndex:s.length];
		shouldLoad = NO;

		s = @"mediaOverlayStatusDidChange?q=";

		if ([url hasPrefix:s]) {
			s = [url substringFromIndex:s.length];
			s = [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
			[self handleMediaOverlayStatusDidChange:s];
		}
		else {
			s = @"pageDidChange?q=";

			if ([url hasPrefix:s]) {
				s = [url substringFromIndex:s.length];
				s = [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
				[self handlePageDidChange:s];
			}
			else if ([url isEqualToString:@"readerDidInitialize"]) {
				[self handleReaderDidInitialize];
			}
		}
	}

	return shouldLoad;
}

- (void)handleAppWillResignActiveNotification:(NSNotification *)notification {
    [m_resourceServer stopHTTPServer];
}

- (void)handleAppWillEnterForegroundNotification:(NSNotification *)notification {
    [m_resourceServer startHTTPServer];
}

//Gesture recognizer delegate method
-(BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch{
    return YES;
}

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer{
    return YES;
}


@end
