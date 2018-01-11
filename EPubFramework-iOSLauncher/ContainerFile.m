//
//  ContainerFile.m
//  EPub_iOS_Demo
//
//  Created by Tejsvi Tandon on 1/4/18.
//  Copyright © 2018 Indpro. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ContainerFile.h"
#include <RDFramework/RDContainer.h>
#include <RDFramework/RDPackage.h>
#include <RDFramework/RDSpineItem.h>
#import "EPubViewController.h"
@implementation ContainerFile{
@private RDContainer *m_container;
@private RDPackage *m_package;
}


-(id)initWithController:(UIViewController *)controller {
    if (self = [super init]) {
        NSString *resPath = [NSBundle mainBundle].resourcePath;
        NSString *docsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                  NSUserDomainMask, YES) objectAtIndex:0];
        NSFileManager *fm = [NSFileManager defaultManager];
        
        for (NSString *fileName in [fm contentsOfDirectoryAtPath:resPath error:nil]) {
            if ([fileName.lowercaseString hasSuffix:@".epub"]) {
                NSString *src = [resPath stringByAppendingPathComponent:fileName];
                NSString *dst = [docsPath stringByAppendingPathComponent:fileName];
                
                if (![fm fileExistsAtPath:dst]) {
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
            }
        }
        
        m_paths = self.paths;
        m_container = [[RDContainer alloc] initWithDelegate:nil path:m_paths.firstObject];
        m_package = m_container.firstPackage;
        
        RDSpineItem *spineItem = [m_package.spineItems objectAtIndex:0];
        EPubViewController *c = [[EPubViewController alloc]
                                 initWithContainer:m_container
                                 package:m_package
                                 spineItem:spineItem
                                 cfi:nil];
        [controller presentViewController:c animated:true completion:nil];
        
      
    }
    return self;
 }
- (NSArray *)paths {
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:16];
    
    NSString *docsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES) objectAtIndex:0];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (NSString *fileName in [fm contentsOfDirectoryAtPath:docsPath error:nil]) {
        if ([fileName.lowercaseString hasSuffix:@".epub"]) {
            [paths addObject:[docsPath stringByAppendingPathComponent:fileName]];
        }
    }
    
    [paths sortUsingComparator:^NSComparisonResult(NSString *path0, NSString *path1) {
        return [path0 compare:path1];
    }];
    return paths;
}


+ (ContainerFile *)shared {
    static ContainerFile *shared = nil;
    
    if (shared == nil) {
        shared = [[ContainerFile alloc] init];
    }
    
    return shared;
}

@end
