//
//  ContainerFile.h
//  EPub_iOS_Demo
//
//  Created by Tejsvi Tandon on 1/4/18.
//  Copyright © 2018 Indpro. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface ContainerFile : NSObject{
    @private NSArray *m_paths;
}
@property (nonatomic, readonly) NSArray *paths;
-(id)initWithController:(UIViewController *)controller;
+ (ContainerFile *)shared;

@end
