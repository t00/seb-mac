//
//  SEBController.h
//  Safe Exam Browser
//
//  Created by Daniel R. Schneider on 29.04.10.
//  Copyright (c) 2010-2015 Daniel R. Schneider, ETH Zurich, 
//  Educational Development and Technology (LET), 
//  based on the original idea of Safe Exam Browser 
//  by Stefan Schneider, University of Giessen
//  Project concept: Thomas Piendl, Daniel R. Schneider, 
//  Dirk Bauer, Kai Reuter, Tobias Halbherr, Karsten Burger, Marco Lehre, 
//  Brigitte Schmucki, Oliver Rahs. French localization: Nicolas Dunand
//
//  ``The contents of this file are subject to the Mozilla Public License
//  Version 1.1 (the "License"); you may not use this file except in
//  compliance with the License. You may obtain a copy of the License at
//  http://www.mozilla.org/MPL/
//  
//  Software distributed under the License is distributed on an "AS IS"
//  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
//  License for the specific language governing rights and limitations
//  under the License.
//  
//  The Original Code is Safe Exam Browser for Mac OS X.
//  
//  The Initial Developer of the Original Code is Daniel R. Schneider.
//  Portions created by Daniel R. Schneider are Copyright 
//  (c) 2010-2015 Daniel R. Schneider, ETH Zurich, Educational Development
//  and Technology (LET), based on the original idea of Safe Exam Browser 
//  by Stefan Schneider, University of Giessen. All Rights Reserved.
//  
//  Contributor(s): ______________________________________.
//

// Main Safe Exam Browser controller class

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <CommonCrypto/CommonDigest.h>
#import "PreferencesController.h"

#import "CapView.h"
#import "CapWindow.h"
#import "CapWindowController.h"

#import "AboutWindow.h"
#import "SEBBrowserController.h"

#import "SEBBrowserWindow.h"
#import "SEBWebView.h"

#import "SEBDockController.h"
#import "SEBDockItem.h"

#import "SEBEncryptedUserDefaultsController.h"
#import "SEBSystemManager.h"

#import "CocoaLumberjack.h"

@class PreferencesController;
@class SEBSystemManager;
@class SEBDockController;
@class SEBBrowserController;


@interface SEBController : NSObject <NSApplicationDelegate> {
	
    NSArray *runningAppsWhileTerminating;
    NSMutableArray *visibleApps;
	BOOL f3Pressed;
	BOOL firstStart;
    BOOL quittingMyself;

	IBOutlet AboutWindow *aboutWindow;
    IBOutlet NSWindow *cmdKeyAlertWindow;
    IBOutlet NSMenuItem *configMenu;
    IBOutlet NSMenu *settingsMenu;
    IBOutlet NSView *passwordView;

    IBOutlet NSWindow *enterPasswordDialogWindow;
    IBOutlet NSTextField *enterPasswordDialog;
    	
	IOPMAssertionID assertionID1;
	IOPMAssertionID assertionID2;
    
    @private
    BOOL _cmdKeyDown;
    DDFileLogger *_myLogger;
    BOOL _forceAppFolder;
}

- (void) closeAboutWindow;
- (void) closeDocument:(id)sender;
- (void) coverScreens;
- (void) adjustScreenLocking:(id)sender;
- (void) startTask;
- (void) terminateScreencapture;
- (void) regainActiveStatus:(id)sender;
- (void) SEBgotActive:(id)sender;
- (void) startKioskMode;

- (NSInteger) showEnterPasswordDialog:(NSString *)text modalForWindow:(NSWindow *)window windowTitle:(NSString *)title;
- (IBAction) okEnterPassword: (id)sender;
- (IBAction) cancelEnterPassword: (id)sender;

- (IBAction) exitSEB:(id)sender;
- (void) requestedQuitWPwd:(id)sender;

- (IBAction) openPreferences:(id)sender;
- (IBAction) showAbout:(id)sender;
- (IBAction) showHelp:(id)sender;

- (void) requestedRestart:(NSNotification *)notification;

- (BOOL) applicationShouldOpenUntitledFile:(NSApplication *)sender;

@property(readwrite) BOOL f3Pressed;
@property(readwrite) BOOL quittingMyself;
@property(strong) SEBWebView *webView;
@property(strong) NSMutableArray *capWindows;
@property(strong) IBOutlet NSSecureTextField *enterPassword;
@property(strong) IBOutlet id preferencesController;
@property(strong) IBOutlet SEBSystemManager *systemManager;
@property(strong) SEBDockController *dockController;
@property(strong) SEBBrowserController *browserController;

@end
