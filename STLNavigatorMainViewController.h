//
//  STLNavigatorMainViewController.h
//  STLNavigtorLite
//
//  Created by Vishal Patil on 10/3/12.
//  Copyright (c) 2012 Akruty. All rights reserved.
//

#import <GLKit/GLKit.h>
#import "STLNavigatorSettingsDelegate.h"

@interface STLNavigatorMainViewController : UIViewController <UIPopoverControllerDelegate, GLKViewDelegate, STLNavigatorSettingsDelegate>

@property (strong, nonatomic) UIPopoverController *flipsidePopoverController;
@property (weak, nonatomic) IBOutlet GLKView *glview;
@property (weak) IBOutlet UINavigationItem *navItem;
@property (weak) IBOutlet UILabel *warningLabel;
@property IBOutlet UIImageView *options;
@property (weak) IBOutlet UIActivityIndicatorView *loadActivityIndicator;

- (IBAction)handlePinch:(UIPinchGestureRecognizer *)recognizer;
- (IBAction)handleDoubleTap:(UITapGestureRecognizer *)recognizer;

@end
