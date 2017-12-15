//
//  SEBWebViewController.m
//  Speedwell eSystem Secure
//
//  Created by Michal Turecki on 14/12/2017.
//

#import "SEBWebViewController.h"

@interface SEBWebViewController ()

@end

@implementation SEBWebViewController
- (void)viewDidAppear {
    [super viewDidAppear];
    // Do view setup here.
    
    NSPressureConfiguration* pressureConfiguration;
    pressureConfiguration = [[NSPressureConfiguration alloc]
                             initWithPressureBehavior:NSPressureBehaviorPrimaryClick];
    
    for (NSView *subview in [self.view subviews]) {
        if ([subview respondsToSelector:@selector(setPressureConfiguration:)]) {
            subview.pressureConfiguration = pressureConfiguration;
        }
    }
}

@end
