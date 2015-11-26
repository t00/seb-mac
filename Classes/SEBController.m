//
//  SEBController.m
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

#include <Carbon/Carbon.h>
#import "SEBController.h"

#import <IOKit/pwr_mgt/IOPMLib.h>

#include <ctype.h>
#include <stdlib.h>
#include <stdio.h>

#include <mach/mach_port.h>
#include <mach/mach_interface.h>
#include <mach/mach_init.h>

#import <objc/runtime.h>

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>

#import "PrefsBrowserViewController.h"
#import "SEBURLFilter.h"
#import "SEBURLProtocol.h"

#import "RNDecryptor.h"
#import "SEBKeychainManager.h"
#import "SEBCryptor.h"
#import "NSWindow+SEBWindow.h"
#import "SEBConfigFileManager.h"

#import "SEBDockItemMenu.h"

#import "SEBWindowSizeValueTransformer.h"
#import "BoolValueTransformer.h"
#import "IsEmptyCollectionValueTransformer.h"
#import "NSTextFieldNilToEmptyStringTransformer.h"

io_connect_t  root_port; // a reference to the Root Power Domain IOService


OSStatus MyHotKeyHandler(EventHandlerCallRef nextHandler,EventRef theEvent,id sender);
void MySleepCallBack(void * refCon, io_service_t service, natural_t messageType, void * messageArgument);
bool insideMatrix();

@implementation SEBController

@synthesize f3Pressed;	//create getter and setter for F3 key pressed flag
@synthesize quittingMyself;	//create getter and setter for flag that SEB is quitting itself
@synthesize webView;
@synthesize capWindows;

#pragma mark Application Delegate Methods

+ (void) initialize
{
    [[MyGlobals sharedMyGlobals] setFinishedInitializing:NO];
    [[MyGlobals sharedMyGlobals] setStartKioskChangedPresentationOptions:NO];
    [[MyGlobals sharedMyGlobals] setLogLevel:DDLogLevelVerbose];

    SEBWindowSizeValueTransformer *windowSizeTransformer = [[SEBWindowSizeValueTransformer alloc] init];
    [NSValueTransformer setValueTransformer:windowSizeTransformer
                                    forName:@"SEBWindowSizeTransformer"];

    BoolValueTransformer *boolValueTransformer = [[BoolValueTransformer alloc] init];
    [NSValueTransformer setValueTransformer:boolValueTransformer
                                    forName:@"BoolValueTransformer"];
    
    IsEmptyCollectionValueTransformer *isEmptyCollectionValueTransformer = [[IsEmptyCollectionValueTransformer alloc] init];
    [NSValueTransformer setValueTransformer:isEmptyCollectionValueTransformer
                                    forName:@"isEmptyCollectionValueTransformer"];
    
    NSTextFieldNilToEmptyStringTransformer *textFieldNilToEmptyStringTransformer = [[NSTextFieldNilToEmptyStringTransformer alloc] init];
    [NSValueTransformer setValueTransformer:textFieldNilToEmptyStringTransformer
                                    forName:@"NSTextFieldNilToEmptyStringTransformer"];
    
}


// Tells the application delegate to open a single file.
// Returning YES if the file is successfully opened, and NO otherwise.
//
- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename
{
    BOOL isFromFile = false;
    NSURL *sebFileURL = [NSURL URLWithString:filename];
    if([sebFileURL.scheme length] == 0 || [sebFileURL.scheme isEqualToString:@"file"])
    {
        sebFileURL = [NSURL fileURLWithPath:filename];
        isFromFile = true;
    }

    DDLogInfo(@"Open file event: Loading .seb settings file with URL %@", sebFileURL);

    [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];

    // Check if preferences window is open
    if ([self.preferencesController preferencesAreOpen]) {

        /// Open settings file in preferences window for editing

        [self.preferencesController openSEBPrefsAtURL:sebFileURL];
    
    } else {
        
        /// Open settings file for exam/reconfiguring client
        
        // Check if SEB is in exam mode = private UserDefauls are switched on
        if (NSUserDefaults.userDefaultsPrivate) {
            NSRunAlertPanel(NSLocalizedString(@"Loading New SEB Settings Not Allowed!", nil),
                            NSLocalizedString(@"SEB is already running in exam mode and it is not allowed to interupt this by starting another exam. Finish the exam and quit SEB before starting another exam.", nil),
                            NSLocalizedString(@"OK", nil), nil, nil);
            return YES;
        }
        
        NSError *error = nil;
        NSData *sebData = [self.browserController downloadSebConfigFromURL:sebFileURL error:&error];

        if(error) {
            [self.browserController.mainBrowserWindow presentError:error modalForWindow:self.browserController.mainBrowserWindow delegate:nil didPresentSelector:NULL contextInfo:NULL];
        }
        else {
            SEBConfigFileManager *configFileManager = [[SEBConfigFileManager alloc] init];
        
            // Get current config path
            NSURL *currentConfigPath = [[MyGlobals sharedMyGlobals] currentConfigURL];
            if(isFromFile)
            {
                // Save the path to the file for possible editing in the preferences window
                [[MyGlobals sharedMyGlobals] setCurrentConfigURL:sebFileURL];
            }
        
            // Decrypt and store the .seb config file
            if ([configFileManager storeDecryptedSEBSettings:sebData forEditing:NO]) {
                    // if successfull restart with new settings
                    [self requestedRestart:nil];
            } else {
                if(isFromFile)
                {
                    // if decrypting new settings wasn't successfull, we have to restore the path to the old settings
                    [[MyGlobals sharedMyGlobals] setCurrentConfigURL:currentConfigPath];
                }
            }
        }
    }
    
    return YES;
}


- (void)handleGetURLEvent:(NSAppleEventDescriptor*)event withReplyEvent:(NSAppleEventDescriptor*)replyEvent
{
    NSString *urlString = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url) {
        if ([url.scheme isEqualToString:@"seb"] || [url.scheme isEqualToString:@"sebs"]) {
            // If we have a valid URL with the path for a .seb file, we download and open it (conditionally)
            DDLogInfo(@"Get URL event: Loading .seb settings file with URL %@", urlString);
            [self.browserController downloadAndOpenSebConfigFromURL:url];
        }
    }
}


#pragma mark Initialization

- (id)init {
    self = [super init];
    if (self) {
        
        // Register custom SEB NSURL protocol class
//        [NSURLProtocol registerClass:[SEBURLProtocol class]];
        
        // Initialize console loggers
#ifdef DEBUG
        // We show log messages only in Console.app and the Xcode console in debug mode
        [DDLog addLogger:[DDASLLogger sharedInstance]];
        [DDLog addLogger:[DDTTYLogger sharedInstance]];
#endif

        [[MyGlobals sharedMyGlobals] setPreferencesReset:NO];
        [[MyGlobals sharedMyGlobals] setCurrentConfigURL:nil];
        [MyGlobals sharedMyGlobals].reconfiguredWhileStarting = NO;
        [MyGlobals sharedMyGlobals].isInitializing = YES;
        
        
        [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handleGetURLEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
        DDLogDebug(@"Installed get URL event handler");

        // Add an observer for the request to unconditionally quit SEB
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(requestedQuit:)
                                                     name:@"requestQuitNotification" object:nil];
        
        
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
        
        //[[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        // Set default preferences for the case there are no user prefs yet
        // and set flag for displaying alert to new users
        firstStart = [preferences setSEBDefaults];

        // Initialize file logger if it's enabled in settings
        [self initializeLogger];
        
        // Update URL filter flags and rules
        [[SEBURLFilter sharedSEBURLFilter] updateFilterRules];
        // Update URL filter ignore rules
        [[SEBURLFilter sharedSEBURLFilter] updateIgnoreRuleList];
        
        // Regardless if switching to third party applications is allowed in current settings,
        // we need to first open the background cover windows with standard window levels
        [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
    }
    return self;
}


- (BOOL) isInApplicationsFolder:(NSString *)path
{
    // Check all the normal Application directories
    NSArray *applicationDirs = NSSearchPathForDirectoriesInDomains(NSApplicationDirectory, NSAllDomainsMask, YES);
    for (NSString *appDir in applicationDirs) {
        if ([path hasPrefix:appDir]) return YES;
    }
    return NO;
}


- (void)awakeFromNib
{
    self.systemManager = [[SEBSystemManager alloc] init];
    
    [self.systemManager preventSC];
	
//    BOOL worked = [systemManager checkHTTPSProxySetting];
//#ifdef DEBUG
//    DDLogDebug(@"Checking updating HTTPS proxy worked: %hhd", worked);
//#endif
    
    // Flag initializing
	quittingMyself = FALSE; //flag to know if quit application was called externally

    // Terminate invisibly running applications
    if ([NSRunningApplication respondsToSelector:@selector(terminateAutomaticallyTerminableApplications)]) {
        [NSRunningApplication terminateAutomaticallyTerminableApplications];
    }

    // Save the bundle ID of all currently running apps which are visible in a array
	NSArray *runningApps = [[NSWorkspace sharedWorkspace] runningApplications];
    NSRunningApplication *iterApp;
    visibleApps = [NSMutableArray array]; //array for storing bundleIDs of visible apps

    for (iterApp in runningApps) 
    {
        BOOL isHidden = [iterApp isHidden];
        NSString *appBundleID = [iterApp valueForKey:@"bundleIdentifier"];
        if ((appBundleID != nil) & !isHidden) {
            [visibleApps addObject:appBundleID]; //add ID of the visible app
        }
        if ([iterApp ownsMenuBar]) {
            DDLogDebug(@"App %@ owns menu bar", iterApp);
        }
    }

// Setup Notifications and Kiosk Mode    
    
    // Add an observer for the notification that another application became active (SEB got inactive)
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(regainActiveStatus:) 
												 name:NSApplicationDidResignActiveNotification 
                                               object:NSApp];
	
#ifndef DEBUG
    // Add an observer for the notification that another application was unhidden by the finder
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	[[workspace notificationCenter] addObserver:self
                                       selector:@selector(regainActiveStatus:)
                                           name:NSWorkspaceDidActivateApplicationNotification
                                         object:workspace];
	
    // Add an observer for the notification that another application was unhidden by the finder
	[[workspace notificationCenter] addObserver:self
                                       selector:@selector(regainActiveStatus:)
                                           name:NSWorkspaceDidUnhideApplicationNotification
                                         object:workspace];
	
    // Add an observer for the notification that another application was unhidden by the finder
	[[workspace notificationCenter] addObserver:self
                                       selector:@selector(regainActiveStatus:)
                                           name:NSWorkspaceWillLaunchApplicationNotification
                                         object:workspace];
	
    // Add an observer for the notification that another application was unhidden by the finder
	[[workspace notificationCenter] addObserver:self
                                       selector:@selector(regainActiveStatus:)
                                           name:NSWorkspaceDidLaunchApplicationNotification
                                         object:workspace];
	
//    // Add an observer for the notification that another application was unhidden by the finder
//	[[workspace notificationCenter] addObserver:self
//                                       selector:@selector(requestedReinforceKioskMode:)
//                                           name:NSWorkspaceActiveSpaceDidChangeNotification
//                                         object:workspace];
	
#endif
    // Add an observer for the notification that SEB became active
    // With third party apps and Flash fullscreen it can happen that SEB looses its 
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(SEBgotActive:)
												 name:NSApplicationDidBecomeActiveNotification 
                                               object:NSApp];
	
    // Hide all other applications
    [[NSWorkspace sharedWorkspace] performSelectorOnMainThread:@selector(hideOtherApplications)
                                                    withObject:NULL waitUntilDone:NO];
    
    // Cover all attached screens with cap windows to prevent clicks on desktop making finder active
	[self coverScreens];

    
    // Check if launched SEB is placed ("installed") in an Applications folder
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *currentSEBBundlePath =[[NSBundle mainBundle] bundlePath];
    DDLogDebug(@"SEB was started up from this path: %@", currentSEBBundlePath);
    if (![self isInApplicationsFolder:currentSEBBundlePath]) {
        // Has SEB to be installed in an Applications folder?
        if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_forceAppFolderInstall"]) {
#ifndef DEBUG
            DDLogError(@"Current settings require SEB to be installed in an Applications folder, but it isn't! SEB will therefore quit!");
            _forceAppFolder = YES;
            quittingMyself = TRUE; //SEB is terminating itself
            [NSApp terminate: nil]; //quit SEB
#else
            DDLogDebug(@"Current settings require SEB to be installed in an Applications folder, but it isn't! SEB would quit if not Debug build.");
#endif
        }
    } else {
        DDLogInfo(@"SEB was started up from an Applications folder.");
    }

    // Check for command key being held down
    int modifierFlags = [NSEvent modifierFlags];
    _cmdKeyDown = (0 != (modifierFlags & NSCommandKeyMask));
    if (_cmdKeyDown) {
        if ([[NSUserDefaults standardUserDefaults] secureBoolForKey:@"org_safeexambrowser_SEB_enableAppSwitcherCheck"]) {
            DDLogError(@"Command key is pressed and forbidden, SEB will quit!");
            quittingMyself = TRUE; //SEB is terminating itself
            [NSApp terminate: nil]; //quit SEB
        } else {
            DDLogWarn(@"Command key is pressed, but not forbidden in current settings");
        }
    }
    
    // Switch to kiosk mode by setting the proper presentation options
    [self startKioskMode];
    
    // Hide all other applications
    [[NSWorkspace sharedWorkspace] performSelectorOnMainThread:@selector(hideOtherApplications)
                                                    withObject:NULL waitUntilDone:NO];
    
//    // Cover all attached screens with cap windows to prevent clicks on desktop making finder active
//    [self coverScreens];
    
    // Add an observer for changes of the Presentation Options
	[NSApp addObserver:self
			forKeyPath:@"currentSystemPresentationOptions"
			   options:NSKeyValueObservingOptionNew
			   context:NULL];

    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);

    
    // Add a observer for changes of the screen configuration
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(adjustScreenLocking:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:NSApp];
    
    // Add a observer for notification that the main browser window changed screen
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(changeMainScreen:)
                                                 name:@"mainScreenChanged" object:nil];
    
	// Add an observer for the request to conditionally exit SEB
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(exitSEB:)
                                                 name:@"requestExitNotification" object:nil];
	
    // Add an observer for the request to conditionally quit SEB with asking quit password
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(requestedQuitWPwd:)
                                                 name:@"requestQuitWPwdNotification" object:nil];
	
    // Add an observer for the request to reload start URL
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(requestedRestart:)
                                                 name:@"requestRestartNotification" object:nil];
	
    // Add an observer for the request to reinforce the kiosk mode
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(performAfterStartActions:)
                                                 name:@"requestPerformAfterStartActions" object:nil];
    
    // Add an observer for the request to start the kiosk mode
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(startKioskMode)
                                                 name:@"requestStartKioskMode" object:nil];
    
    // Add an observer for the request to reinforce the kiosk mode
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(requestedReinforceKioskMode:)
                                                 name:@"requestReinforceKioskMode" object:nil];
    
    // Add an observer for the request to reinforce the kiosk mode
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(requestedRegainActiveStatus:)
                                                 name:@"regainActiveStatus" object:nil];
	
    // Add an observer for the request to show about panel
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(requestedShowAbout:)
                                                 name:@"requestShowAboutNotification" object:nil];
	
    // Add an observer for the request to close about panel
    [[NSNotificationCenter defaultCenter] addObserver:aboutWindow
                                             selector:@selector(closeAboutWindow:)
                                                 name:@"requestCloseAboutWindowNotification" object:nil];
	
    // Add an observer for the request to show help
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(requestedShowHelp:)
                                                 name:@"requestShowHelpNotification" object:nil];

    // Add an observer for the request to switch plugins on
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(switchPluginsOn:)
                                                 name:@"switchPluginsOn" object:nil];
    
    // Add an observer for the notification that preferences were closed
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(preferencesClosed:)
                                                 name:@"preferencesClosed" object:nil];

    // Add an observer for the notification that preferences were closed and SEB should be restarted
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(preferencesClosedRestartSEB:)
                                                 name:@"preferencesClosedRestartSEB" object:nil];
    //[self startTask];

// Prevent display sleep
#ifndef DEBUG
    IOPMAssertionCreateWithName(
		kIOPMAssertionTypeNoDisplaySleep,										   
		kIOPMAssertionLevelOn, 
		CFSTR("Safe Exam Browser Kiosk Mode"), 
		&assertionID1); 
#else
    IOReturn success = IOPMAssertionCreateWithName(
                                                   kIOPMAssertionTypeNoDisplaySleep,										   
                                                   kIOPMAssertionLevelOn, 
                                                   CFSTR("Safe Exam Browser Kiosk Mode"), 
                                                   &assertionID1);
	if (success == kIOReturnSuccess) {
		DDLogDebug(@"Display sleep is switched off now.");
	}
#endif		
	
/*	// Prevent idle sleep
	success = IOPMAssertionCreateWithName(
		kIOPMAssertionTypeNoIdleSleep, 
		kIOPMAssertionLevelOn, 
		CFSTR("Safe Exam Browser Kiosk Mode"), 
		&assertionID2); 
#ifdef DEBUG
	if (success == kIOReturnSuccess) {
		DDLogDebug(@"Idle sleep is switched off now.");
	}
#endif		
*/	
	// Installing I/O Kit sleep/wake notification to cancel sleep
	
	IONotificationPortRef notifyPortRef; // notification port allocated by IORegisterForSystemPower
    io_object_t notifierObject; // notifier object, used to deregister later
    void* refCon; // this parameter is passed to the callback
	
    // register to receive system sleep notifications

    root_port = IORegisterForSystemPower( refCon, &notifyPortRef, MySleepCallBack, &notifierObject );
    if ( root_port == 0 )
    {
        DDLogError(@"IORegisterForSystemPower failed");
    } else {
	    // add the notification port to the application runloop
		CFRunLoopAddSource( CFRunLoopGetCurrent(),
					   IONotificationPortGetRunLoopSource(notifyPortRef), kCFRunLoopCommonModes ); 
	}

	if (![[NSUserDefaults standardUserDefaults] secureBoolForKey:@"org_safeexambrowser_SEB_allowVirtualMachine"]) {
        // Check if SEB is running inside a virtual machine
        SInt32		myAttrs;
        OSErr		myErr = noErr;
        
        // Get details for the present operating environment
        // by calling Gestalt (Userland equivalent to CPUID)
        myErr = Gestalt(gestaltX86AdditionalFeatures, &myAttrs);
        if (myErr == noErr) {
            if ((myAttrs & (1UL << 31)) | (myAttrs == 0x209)) {
                // Bit 31 is set: VMware Hypervisor running (?)
                // or gestaltX86AdditionalFeatures values of VirtualBox detected
                DDLogError(@"SERIOUS SECURITY ISSUE DETECTED: SEB was started up in a virtual machine! gestaltX86AdditionalFeatures = %X", myAttrs);
                NSRunAlertPanel(NSLocalizedString(@"Virtual Machine Detected!", nil),
                                NSLocalizedString(@"You are not allowed to run SEB inside a virtual machine!", nil),
                                NSLocalizedString(@"Quit", nil), nil, nil);
                quittingMyself = TRUE; //SEB is terminating itself
                [NSApp terminate: nil]; //quit SEB
                
            } else {
                DDLogInfo(@"SEB is running on a native system (no VM) gestaltX86AdditionalFeatures = %X", myAttrs);
            }
        }
        
        bool    virtualMachine = false;
        // STR or SIDT code?
        virtualMachine = insideMatrix();
        if (virtualMachine) {
            DDLogError(@"SERIOUS SECURITY ISSUE DETECTED: SEB was started up in a virtual machine (Test2)!");
        }
    }


    [self clearPasteboardSavingCurrentString];

    // Set up SEB Browser
    self.browserController = [[SEBBrowserController alloc] init];

    self.browserController.reinforceKioskModeRequested = YES;
    
    // Set up and open SEB Dock
    [self openSEBDock];
    self.browserController.dockController = self.dockController;
    
    // Open the main browser window
    [self.browserController openMainBrowserWindow];
    
	// Due to the infamous Flash plugin we completely disable plugins in the 32-bit build
#ifdef __i386__        // 32-bit Intel build
	[[self.webView preferences] setPlugInsEnabled:NO];
#endif
	
//    if ([[MyGlobals sharedMyGlobals] preferencesReset] == YES) {
//#ifdef DEBUG
//        DDLogError(@"Presenting alert for 'Local SEB settings have been reset' after a delay of 2s");
//#endif
//        [self performSelector:@selector(presentPreferencesCorruptedError) withObject: nil afterDelay: 2];
//    }
    
/*	if (firstStart) {
		NSString *titleString = NSLocalizedString(@"Important Notice for First Time Users", nil);
		NSString *messageString = NSLocalizedString(@"FirstTimeUserNotice", nil);
		NSRunAlertPanel(titleString, messageString, NSLocalizedString(@"OK", nil), nil, nil);
#ifdef DEBUG
        DDLogDebug(@"%@\n%@",titleString, messageString);
#endif
	}*/
    
// Handling of Hotkeys for Preferences-Window
	
	// Register Carbon event handlers for the required hotkeys
	f3Pressed = FALSE; //Initialize flag for first hotkey
	EventHotKeyRef gMyHotKeyRef;
	EventHotKeyID gMyHotKeyID;
	EventTypeSpec eventType;
	eventType.eventClass=kEventClassKeyboard;
	eventType.eventKind=kEventHotKeyPressed;
	InstallApplicationEventHandler((void*)MyHotKeyHandler, 1, &eventType, (__bridge void*)(SEBController*)self, NULL);
    //Pass pointer to flag for F3 key to the event handler
	// Register F3 as a hotkey
	gMyHotKeyID.signature='htk1';
	gMyHotKeyID.id=1;
	RegisterEventHotKey(99, 0, gMyHotKeyID,
						GetApplicationEventTarget(), 0, &gMyHotKeyRef);
	// Register F6 as a hotkey
	gMyHotKeyID.signature='htk2';
	gMyHotKeyID.id=2;
	RegisterEventHotKey(97, 0, gMyHotKeyID,
						GetApplicationEventTarget(), 0, &gMyHotKeyRef);
    

    // Show the About SEB Window
    [aboutWindow showAboutWindowForSeconds:2];

//    [self performSelector:@selector(performAfterStartActions:) withObject: nil afterDelay: 2];

}


- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self performSelector:@selector(performAfterStartActions:) withObject: nil afterDelay: 2];
}


// Perform actions which require that SEB has finished setting up and has opened its windows
- (void) performAfterStartActions:(NSNotification *)notification
{
    [MyGlobals sharedMyGlobals].isInitializing = NO;
    DDLogInfo(@"Performing after start actions");
    
    // Check for command key being held down
    int modifierFlags = [NSEvent modifierFlags];
    _cmdKeyDown = (0 != (modifierFlags & NSCommandKeyMask));
    if (_cmdKeyDown) {
        if ([[NSUserDefaults standardUserDefaults] secureBoolForKey:@"org_safeexambrowser_SEB_enableAppSwitcherCheck"]) {
            DDLogError(@"Command key is pressed and forbidden, SEB will quit!");
            quittingMyself = TRUE; //SEB is terminating itself
            [NSApp terminate: nil]; //quit SEB
        } else {
            DDLogWarn(@"Command key is pressed, but not forbidden in current settings");
        }
    }
    
    // Reinforce the kiosk mode
    [self requestedReinforceKioskMode:nil];
    
//    [[NSNotificationCenter defaultCenter]
//     postNotificationName:@"requestReinforceKioskMode" object:self];
    
    if ([[MyGlobals sharedMyGlobals] preferencesReset] == YES) {
        DDLogError(@"Triggering present alert for 'Local SEB settings have been reset'");
        [self presentPreferencesCorruptedError];
    }
    
    // Check if there is a SebClientSettings.seb file saved in the preferences directory
    SEBConfigFileManager *configFileManager = [[SEBConfigFileManager alloc] init];
    if (![configFileManager reconfigureClientWithSebClientSettings] && [MyGlobals sharedMyGlobals].reconfiguredWhileStarting) {
        // Show alert that SEB was reconfigured
        NSAlert *newAlert = [[NSAlert alloc] init];
        [newAlert setMessageText:NSLocalizedString(@"SEB Re-Configured", nil)];
        [newAlert setInformativeText:NSLocalizedString(@"Local settings of this SEB client have been reconfigured. Do you want to start working with SEB now or quit?", nil)];
        [newAlert addButtonWithTitle:NSLocalizedString(@"Start", nil)];
        [newAlert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
        int answer = [newAlert runModal];
        switch(answer)
        {
            case NSAlertFirstButtonReturn:
                
                break; //Continue running SEB
                
            case NSAlertSecondButtonReturn:
            {
//                [[NSNotificationCenter defaultCenter]
//                 postNotificationName:@"requestQuitNotification" object:self];
                [self performSelector:@selector(requestedQuit:) withObject: nil afterDelay: 1];
                return;
            }
                
        }
    }

    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    if([[preferences secureStringForKey:@"org_safeexambrowser_SEB_startURL"] length] == 0)
    {
        NSAlert *newAlert = [[NSAlert alloc] init];
        [newAlert setMessageText:NSLocalizedString(@"SEB Not configured", nil)];
        [newAlert setInformativeText:NSLocalizedString(@"SEB Configuration not found. Please open configuration file or address to open SEB.", nil)];
        [newAlert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
        [newAlert runModal];
        [self performSelector:@selector(requestedQuit:) withObject: nil afterDelay: 1];
        return;
    }

    // Set flag that SEB is initialized: Now showing alerts is allowed
    [[MyGlobals sharedMyGlobals] setFinishedInitializing:YES];
}


- (void)presentPreferencesCorruptedError
{
    [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
    NSAlert *newAlert = [NSAlert alertWithMessageText:NSLocalizedString(@"Local SEB Settings Have Been Reset", nil) defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:NSLocalizedString(@"Local preferences were either created by an incompatible SEB version or manipulated. They have been reset to the default settings. Ask your exam supporter to re-configure SEB correctly.", nil)];
    [newAlert setAlertStyle:NSCriticalAlertStyle];
    [newAlert runModal];
    newAlert = nil;

    DDLogInfo(@"Dismissed alert for local SEB settings have been reset");

    //    NSDictionary *newDict = @{ NSLocalizedDescriptionKey :
    //                                   NSLocalizedString(@"Local SEB settings are corrupted!", nil),
    //                               /*NSLocalizedFailureReasonErrorKey :
    //                                NSLocalizedString(@"Either an incompatible version of SEB has been used on this computer or the preferences file has been manipulated. In the first case you can quit SEB now and use the previous version to export settings as a .seb config file for reconfiguring the new version. Otherwise local settings need to be reset to the default values in order for SEB to continue running.", nil),*/
    //                               //NSURLErrorKey : furl,
    //                               NSRecoveryAttempterErrorKey : self,
    //                               NSLocalizedRecoverySuggestionErrorKey :
    //                                   NSLocalizedString(@"Local preferences have either been manipulated or created by an incompatible SEB version. You can reset settings now or quit and try to use your previous SEB version to review or export settings as a .seb file for configuring the new version.\n\nReset local settings and continue?", @""),
    //                               NSLocalizedRecoveryOptionsErrorKey :
    //                                   @[NSLocalizedString(@"Continue", @""), NSLocalizedString(@"Quit", @"")] };
    //
    //    NSError *newError = [[NSError alloc] initWithDomain:sebErrorDomain
    //                                                   code:1 userInfo:newDict];
    
    
    // Reset settings to the default values
    //	NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    //    [preferences resetSEBUserDefaults];
    //    [preferences storeSEBDefaultSettings];
    //    // Update Exam Browser Key
    //    [[SEBCryptor sharedSEBCryptor] updateEncryptedUserDefaults:YES updateSalt:NO];
    //#ifdef DEBUG
    //    DDLogError(@"Local preferences have been reset!");
    //#endif
}


- (void) initializeLogger
{
    // Initialize file logger if logging enabled
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_enableLogging"] == NO) {
        [DDLog removeLogger:_myLogger];
    } else {
        //Set log directory
        NSString *logPath = [[NSUserDefaults standardUserDefaults] secureStringForKey:@"org_safeexambrowser_SEB_logDirectoryOSX"];
        [DDLog removeLogger:_myLogger];
        if (logPath.length == 0) {
            // No log directory indicated: We use the standard one
            logPath = nil;
        } else {
            logPath = [logPath stringByExpandingTildeInPath];
        }
        DDLogFileManagerDefault* logFileManager = [[DDLogFileManagerDefault alloc] initWithLogsDirectory:logPath];
        _myLogger = [[DDFileLogger alloc] initWithLogFileManager:logFileManager];
        _myLogger.rollingFrequency = 60 * 60 * 24; // 24 hour rolling
        _myLogger.logFileManager.maximumNumberOfLogFiles = 7; // keep logs for 7 days
        [DDLog addLogger:_myLogger];
    }
}


#pragma mark Methods

// Method executed when hotkeys are pressed
OSStatus MyHotKeyHandler(EventHandlerCallRef nextHandler,EventRef theEvent,
						  id userData)
{
	EventHotKeyID hkCom;
	GetEventParameter(theEvent,kEventParamDirectObject,typeEventHotKeyID,NULL,
					  sizeof(hkCom),NULL,&hkCom);
	int l = hkCom.id;
	id self = userData;
	
	switch (l) {
		case 1: //F3 pressed
			[self setF3Pressed:TRUE];	//F3 was pressed
			
			break;
		case 2: //F6 pressed
			if ([self f3Pressed]) {	//if F3 got pressed before
				[self setF3Pressed:FALSE];
				[self openPreferences:self]; //show preferences window
			}
			break;
	}
	return noErr;
}


// Method called by I/O Kit power management
void MySleepCallBack( void * refCon, io_service_t service, natural_t messageType, void * messageArgument )
{
    DDLogDebug(@"messageType %08lx, arg %08lx\n",
		   (long unsigned int)messageType,
		   (long unsigned int)messageArgument );
	
    switch ( messageType )
    {
			
        case kIOMessageCanSystemSleep:
            /* Idle sleep is about to kick in. This message will not be sent for forced sleep.
			 Applications have a chance to prevent sleep by calling IOCancelPowerChange.
			 Most applications should not prevent idle sleep.
			 
			 Power Management waits up to 30 seconds for you to either allow or deny idle sleep.
			 If you don't acknowledge this power change by calling either IOAllowPowerChange
			 or IOCancelPowerChange, the system will wait 30 seconds then go to sleep.
			 */
			
            // cancel idle sleep
            DDLogDebug(@"kIOMessageCanSystemSleep: IOCancelPowerChange");
            IOCancelPowerChange( root_port, (long)messageArgument );
            // uncomment to allow idle sleep
            //IOAllowPowerChange( root_port, (long)messageArgument );
            break;
			
        case kIOMessageSystemWillSleep:
            /* The system WILL go to sleep. If you do not call IOAllowPowerChange or
			 IOCancelPowerChange to acknowledge this message, sleep will be
			 delayed by 30 seconds.
			 
			 NOTE: If you call IOCancelPowerChange to deny sleep it returns kIOReturnSuccess,
			 however the system WILL still go to sleep. 
			 */
			
			//IOCancelPowerChange( root_port, (long)messageArgument );
			//IOAllowPowerChange( root_port, (long)messageArgument );
            break;
			
        case kIOMessageSystemWillPowerOn:
            //System has started the wake up process...
            break;
			
        case kIOMessageSystemHasPoweredOn:
            //System has finished waking up...
			break;
			
        default:
            break;
			
    }
}


bool insideMatrix(){
	unsigned char mem[4] = {0,0,0,0};
	//__asm ("str mem");
	if ( (mem[0]==0x00) && (mem[1]==0x40))
		return true; //printf("INSIDE MATRIX!!\n");
	else
		return false; //printf("OUTSIDE MATRIX!!\n");
	return false;
}


// Close the About Window
- (void) closeAboutWindow {
    DDLogInfo(@"Attempting to close about window %@", aboutWindow);
    [aboutWindow orderOut:self];
}


// Open background windows on all available screens to prevent Finder becoming active when clicking on the desktop background
- (void) coverScreens {
    return;
    // Open background windows on all available screens to prevent Finder becoming active when clicking on the desktop background
    NSArray *screens = [NSScreen screens];	// get all available screens
    if (!self.capWindows) {
        self.capWindows = [NSMutableArray arrayWithCapacity:1];	// array for storing our cap (covering) background windows
    } else {
        [self.capWindows removeAllObjects];
    }
    NSScreen *iterScreen;
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    BOOL allowSwitchToThirdPartyApps = ![preferences secureBoolForKey:@"org_safeexambrowser_elevateWindowLevels"];
    for (iterScreen in screens)
    {
        //NSRect frame = size of the current screen;
        NSRect frame = [iterScreen frame];
        NSUInteger styleMask = NSBorderlessWindowMask;
        NSRect rect = [NSWindow contentRectForFrameRect:frame styleMask:styleMask];
        
        //set origin of the window rect to left bottom corner (important for non-main screens, since they have offsets)
        rect.origin.x = 0;
        rect.origin.y = 0;

        // If switching to third party apps isn't allowed and showing menu bar
        if (!allowSwitchToThirdPartyApps && [preferences secureBoolForKey:@"org_safeexambrowser_SEB_showMenuBar"]) {
            // Reduce size of covering background windows to not cover the menu bar
            rect.size.height -= 22;
            //rect.origin.y += 22;
        }
        CapWindow *window = [[CapWindow alloc] initWithContentRect:rect styleMask:styleMask backing: NSBackingStoreBuffered defer:NO screen:iterScreen];
        [window setReleasedWhenClosed:NO];
        [window setBackgroundColor:[NSColor blackColor]];
        [window setSharingType: NSWindowSharingNone];  //don't allow other processes to read window contents
        if (!allowSwitchToThirdPartyApps) {
            [window newSetLevel:NSMainMenuWindowLevel+2];
        } else {
            [window newSetLevel:NSNormalWindowLevel];
        }
        //[window orderBack:self];
        [self.capWindows addObject: window];
        NSView *superview = [window contentView];
        CapView *capview = [[CapView alloc] initWithFrame:rect];
        [superview addSubview:capview];
        
        //[window orderBack:self];
        CapWindowController *capWindowController = [[CapWindowController alloc] initWithWindow:window];
        //CapWindow *loadedCapWindow = capWindowController.window;
        [capWindowController showWindow:self];
        [window makeKeyAndOrderFront:self];
        //[window orderBack:self];
        //BOOL isWindowLoaded = capWindowController.isWindowLoaded;
#ifdef DEBUG
        //DDLogDebug(@"Loaded capWindow %@, isWindowLoaded %@", loadedCapWindow, isWindowLoaded);
#endif
    }
}


// Called when changes of the screen configuration occur
// (new display is contected or removed or display mirroring activated)

- (void) adjustScreenLocking: (id)sender {
    // This should only be done when the preferences window isn't open
    if (![self.preferencesController preferencesAreOpen]) {
        // Close the covering windows
        // (which most likely are no longer there where they should be)
        [self closeCapWindows];
        
        // Open new covering background windows on all currently available screens
        [self coverScreens];
        
        // We adjust position and size of the SEB Dock
        [self.dockController adjustDock];
        
        // We adjust the size of the main browser window
        [self.browserController adjustMainBrowserWindow];
    }
}


// Called when main browser window changed screen
- (void) changeMainScreen: (id)sender {
    [self.dockController moveDockToScreen:self.browserController.mainBrowserWindow.screen];
}


- (void) closeCapWindows
{
    // Close the covering windows
	int windowIndex;
	int windowCount = [self.capWindows count];
    for (windowIndex = 0; windowIndex < windowCount; windowIndex++ )
    {
		[(NSWindow *)[self.capWindows objectAtIndex:windowIndex] close];
	}
}


- (void) startTask {
	// Start third party application from within SEB
	
	// Path to Excel
	NSString *pathToTask=@"/Applications/Preview.app/Contents/MacOS/Preview";
	
	// Parameter and path to XUL-SEB Application
	NSArray *taskArguments=[NSArray arrayWithObjects:nil];
	
	// Allocate and initialize a new NSTask
    NSTask *task=[[NSTask alloc] init];
	
	// Tell the NSTask what the path is to the binary it should launch
    [task setLaunchPath:pathToTask];
    
    // The argument that we pass to XULRunner (in the form of an array) is the path to the SEB-XUL-App
    [task setArguments:taskArguments];
    	
	// Launch the process asynchronously
	@try {
		[task launch];
	}
	@catch (NSException * e) {
		DDLogError(@"Error.  Make sure you have a valid path and arguments.");
		
	}
	
}

- (void) terminateScreencapture {
    DDLogInfo(@"screencapture terminated");
}

- (void) regainActiveStatus: (id)sender {
	// hide all other applications if not in debug build setting
    /*/ Check if the
    if ([[sender name] isEqualToString:@"NSWorkspaceDidLaunchApplicationNotification"]) {
        NSDictionary *userInfo = [sender userInfo];
        if (userInfo) {
            NSRunningApplication *launchedApp = [userInfo objectForKey:NSWorkspaceApplicationKey];
#ifdef DEBUG
            DDLogInfo(@"launched app localizedName: %@, executableURL: %@", [launchedApp localizedName], [launchedApp executableURL]);
#endif
            if ([[launchedApp localizedName] isEqualToString:@"iCab"]) {
                [launchedApp forceTerminate];
            }
        }
    }*/
    // Load preferences from the system's user defaults database
	NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
	BOOL allowSwitchToThirdPartyApps = ![preferences secureBoolForKey:@"org_safeexambrowser_elevateWindowLevels"];
    if (!allowSwitchToThirdPartyApps && ![self.preferencesController preferencesAreOpen]) {
		// if switching to ThirdPartyApps not allowed
        DDLogDebug(@"Regain active status after %@", [sender name]);
#ifndef DEBUG
        [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        [[NSWorkspace sharedWorkspace] performSelectorOnMainThread:@selector(hideOtherApplications) withObject:NULL waitUntilDone:NO];
//        [self startKioskMode];
#endif
    } else {
        /*/ Save the bundle ID of all currently running apps which are visible in a array
        NSArray *runningApps = [[NSWorkspace sharedWorkspace] runningApplications];
        NSRunningApplication *iterApp;
        NSDictionary *bundleInfo = [[NSBundle mainBundle] infoDictionary];
        NSString *bundleId = [bundleInfo objectForKey: @"CFBundleIdentifier"];
        for (iterApp in runningApps)
        {
            BOOL isActive = [iterApp isActive];
            NSString *appBundleID = [iterApp valueForKey:@"bundleIdentifier"];
            if ((appBundleID != nil) & ![appBundleID isEqualToString:bundleId] & ![appBundleID isEqualToString:@"com.apple.Preview"]) {
                //& isActive
                BOOL successfullyHidden = [iterApp hide]; //hide the active app
#ifdef DEBUG
                DDLogInfo(@"Successfully hidden app %@: %@", appBundleID, [NSNumber numberWithBool:successfullyHidden]);
#endif
            }
        }
*/
    }
}


- (void) SEBgotActive: (id)sender {
    DDLogDebug(@"SEB got active");
//    [self startKioskMode];
}


// Method which sets the setting flag for elevating window levels according to the
// setting key allowSwitchToApplications
- (void) setElevateWindowLevels
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    BOOL allowSwitchToThirdPartyApps = [preferences secureBoolForKey:@"org_safeexambrowser_SEB_allowSwitchToApplications"];
    if (allowSwitchToThirdPartyApps) {
        [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
    } else {
        [preferences setSecureBool:YES forKey:@"org_safeexambrowser_elevateWindowLevels"];
    }
}


- (void) startKioskMode {
	// Switch to kiosk mode by setting the proper presentation options
    // Load preferences from the system's user defaults database
//    [self startKioskModeThirdPartyAppsAllowed:YES];
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    BOOL allowSwitchToThirdPartyApps = ![preferences secureBoolForKey:@"org_safeexambrowser_elevateWindowLevels"];
    DDLogDebug(@"startKioskMode switchToApplications %hhd", allowSwitchToThirdPartyApps);
    [self startKioskModeThirdPartyAppsAllowed:allowSwitchToThirdPartyApps overrideShowMenuBar:NO];

}


- (void) switchKioskModeAppsAllowed:(BOOL)allowApps overrideShowMenuBar:(BOOL)overrideShowMenuBar {
	// Switch the kiosk mode to either only browser windows or also third party apps allowed:
    // Change presentation options and windows levels without closing/reopening cap background and browser foreground windows
    [self startKioskModeThirdPartyAppsAllowed:allowApps overrideShowMenuBar:overrideShowMenuBar];
    
    // Change window level of cap windows
    CapWindow *capWindow;
    BOOL allowAppsUserDefaultsSetting = [[NSUserDefaults standardUserDefaults] secureBoolForKey:@"org_safeexambrowser_SEB_allowSwitchToApplications"];

    for (capWindow in self.capWindows) {
        if (allowApps) {
            [capWindow newSetLevel:NSNormalWindowLevel];
            if (allowAppsUserDefaultsSetting) {
                capWindow.collectionBehavior = NSWindowCollectionBehaviorStationary;
            }
        } else {
            [capWindow newSetLevel:NSMainMenuWindowLevel+2];
        }
    }
    
    // Change window level of all open browser windows
    [self.browserController allBrowserWindowsChangeLevel:allowApps];
}


- (void) startKioskModeThirdPartyAppsAllowed:(BOOL)allowSwitchToThirdPartyApps overrideShowMenuBar:(BOOL)overrideShowMenuBar {
    // Switch to kiosk mode by setting the proper presentation options
    // Load preferences from the system's user defaults database
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    BOOL showMenuBar = overrideShowMenuBar || [preferences secureBoolForKey:@"org_safeexambrowser_SEB_showMenuBar"];
//    BOOL enableToolbar = [preferences secureBoolForKey:@"org_safeexambrowser_SEB_enableBrowserWindowToolbar"];
//    BOOL hideToolbar = [preferences secureBoolForKey:@"org_safeexambrowser_SEB_hideBrowserWindowToolbar"];
    NSApplicationPresentationOptions presentationOptions;
    
    if (allowSwitchToThirdPartyApps) {
        [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
    } else {
        [preferences setSecureBool:YES forKey:@"org_safeexambrowser_elevateWindowLevels"];
    }
    
    if (!allowSwitchToThirdPartyApps) {
        // if switching to third party apps not allowed
        presentationOptions =
        NSApplicationPresentationDisableAppleMenu +
        NSApplicationPresentationHideDock +
        (showMenuBar ? 0 : NSApplicationPresentationHideMenuBar) +
        NSApplicationPresentationDisableProcessSwitching +
        NSApplicationPresentationDisableForceQuit +
        NSApplicationPresentationDisableSessionTermination;
    } else {
        presentationOptions =
        (showMenuBar ? 0 : NSApplicationPresentationHideMenuBar) +
        NSApplicationPresentationHideDock +
        NSApplicationPresentationDisableAppleMenu +
        NSApplicationPresentationDisableForceQuit +
        NSApplicationPresentationDisableSessionTermination;
    }
    
    @try {
        [[MyGlobals sharedMyGlobals] setStartKioskChangedPresentationOptions:YES];
        
        DDLogDebug(@"NSApp setPresentationOptions: %lo", presentationOptions);
        
        [NSApp setPresentationOptions:presentationOptions];
        [[MyGlobals sharedMyGlobals] setPresentationOptions:presentationOptions];
    }
    @catch(NSException *exception) {
        DDLogError(@"Error.  Make sure you have a valid combination of presentation options.");
    }
}


// Clear Pasteboard, but save the current content in case it is a NSString
- (void)clearPasteboardSavingCurrentString
{
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    //NSArray *classes = [[NSArray alloc] initWithObjects:[NSString class], [NSAttributedString class], nil];
    NSArray *classes = [[NSArray alloc] initWithObjects:[NSString class], nil];
    NSDictionary *options = [NSDictionary dictionary];
    NSArray *copiedItems = [pasteboard readObjectsForClasses:classes options:options];
    if ((copiedItems != nil) && [copiedItems count]) {
        // if there is a NSSting in the pasteboard, save it for later use
        //[[MyGlobals sharedMyGlobals] setPasteboardString:[copiedItems objectAtIndex:0]];
        [[MyGlobals sharedMyGlobals] setValue:[copiedItems objectAtIndex:0] forKey:@"pasteboardString"];
        DDLogDebug(@"String saved from pasteboard");
    } else {
        [[MyGlobals sharedMyGlobals] setValue:@"" forKey:@"pasteboardString"];
    }
#ifdef DEBUG
    //    NSString *stringFromPasteboard = [[MyGlobals sharedMyGlobals] valueForKey:@"pasteboardString"];
    //    DDLogDebug(@"Saved string from Pasteboard: %@", stringFromPasteboard);
#endif
    //NSInteger changeCount = [pasteboard clearContents];
    [pasteboard clearContents];
}


// Clear Pasteboard when quitting/restarting SEB,
// If selected in Preferences, then the current Browser Exam Key is copied to the pasteboard instead
- (void)clearPasteboardCopyingBrowserExamKey
{
    // Clear Pasteboard
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    
    // Write Browser Exam Key to clipboard if enabled in prefs
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    if ([preferences secureBoolForKey:@"org_safeexambrowser_copyBrowserExamKeyToClipboardWhenQuitting"]) {
        NSData *browserExamKey = [preferences secureObjectForKey:@"org_safeexambrowser_currentData"];
        unsigned char hashedChars[32];
        [browserExamKey getBytes:hashedChars length:32];
        NSMutableString* browserExamKeyString = [[NSMutableString alloc] init];
        for (int i = 0 ; i < 32 ; ++i) {
            [browserExamKeyString appendFormat: @"%02x", hashedChars[i]];
        }
        [pasteboard writeObjects:[NSArray arrayWithObject:browserExamKeyString]];
    }
}


// Set up and display SEB Dock
- (void) openSEBDock
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];

    if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_showTaskBar"]) {
        
        DDLogDebug(@"SEBController openSEBDock: dock enabled");
        // Initialize the Dock
        self.dockController = [[SEBDockController alloc] init];
        
        if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_enableSebBrowser"]) {
            NSString* versionString = [[MyGlobals sharedMyGlobals] infoValueForKey:@"CFBundleShortVersionString"];
            NSString* buildString = [[MyGlobals sharedMyGlobals] infoValueForKey:@"CFBundleVersion"];
            NSString* titleString = [NSString stringWithFormat:@"%@ %@.%@",
                                        NSLocalizedString(@"Safe Exam Browser",nil),
                                        versionString,
                                        buildString];
            SEBDockItem *dockItemSEB = [[SEBDockItem alloc] initWithTitle:titleString
                                                                     icon:[NSApp applicationIconImage]
                                                                  toolTip:nil
                                                                     menu:self.browserController.openBrowserWindowsWebViewsMenu
                                                                   target:self
                                                                   action:@selector(buttonPressed)];
            [self.dockController setLeftItems:[NSArray arrayWithObjects:dockItemSEB, nil]];
        }
        
        // Initialize right dock items (controlls and info widgets)
        NSMutableArray *rightDockItems = [NSMutableArray array];
        
        if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_allowQuit"]) {
            SEBDockItem *dockItemShutDown = [[SEBDockItem alloc] initWithTitle:nil
                                                                          icon:[NSImage imageNamed:@"SEBShutDownIcon"]
                                                                       toolTip:NSLocalizedString(@"Quit SEB",nil)
                                                                          menu:nil
                                                                        target:self
                                                                        action:@selector(quitButtonPressed)];
            [rightDockItems addObject:dockItemShutDown];
        }
        
        if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_enableSebBrowser"] &&
            ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_restartExamUseStartURL"] ||
            [preferences secureStringForKey:@"org_safeexambrowser_SEB_restartExamURL"].length > 0)) {
            NSString *restartButtonToolTip = [preferences secureStringForKey:@"org_safeexambrowser_SEB_restartExamText"];
            if (restartButtonToolTip.length == 0) {
                restartButtonToolTip = NSLocalizedString(@"Restart Exam",nil);
            }
            SEBDockItem *dockItemShutDown = [[SEBDockItem alloc] initWithTitle:nil
                                                                          icon:[NSImage imageNamed:@"SEBRestartIcon"]
                                                                       toolTip:restartButtonToolTip
                                                                          menu:nil
                                                                        target:self
                                                                        action:@selector(restartButtonPressed)];
            [rightDockItems addObject:dockItemShutDown];
        }
        if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_enableSebBrowser"] &&
            [preferences secureBoolForKey:@"org_safeexambrowser_SEB_showReloadButton"]) {
            SEBDockItem *dockItemShutDown = [[SEBDockItem alloc] initWithTitle:nil
                                                                          icon:[NSImage imageNamed:@"SEBReloadIcon"]
                                                                       toolTip:NSLocalizedString(@"Reload Current Page",nil)
                                                                          menu:nil
                                                                        target:self
                                                                        action:@selector(reloadButtonPressed)];
            [rightDockItems addObject:dockItemShutDown];
        }
        
        
        // Set right dock items
        
//        [self.dockController setCenterItems:[NSArray arrayWithObjects:dockItemSEB, dockItemShutDown, nil]];
        
        [self.dockController setRightItems:rightDockItems];
        
        // Display the dock
        [self.dockController showDock];

    } else {
        DDLogDebug(@"SEBController openSEBDock: dock disabled");
        if (self.dockController) {
            [self.dockController hideDock];
            self.dockController = nil;
        }
    }
}


- (void) buttonPressed
{
    [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
    [self.browserController.mainBrowserWindow makeKeyAndOrderFront:self];
}


- (void) restartButtonPressed
{
    // Get custom (if it was set) or standard restart exam text
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *restartExamText = [preferences secureStringForKey:@"org_safeexambrowser_SEB_restartExamText"];
    if (restartExamText.length == 0) {
        restartExamText = NSLocalizedString(@"Restart Exam",nil);
    }

    // Check if restarting is protected with the quit/restart password (and one is set)
    NSString *hashedQuitPassword = [preferences secureObjectForKey:@"org_safeexambrowser_SEB_hashedQuitPassword"];
    
    if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_restartExamPasswordProtected"] && ![hashedQuitPassword isEqualToString:@""]) {
        // if quit/restart password is set, then restrict quitting
        if ([self showEnterPasswordDialog:NSLocalizedString(@"Enter quit/restart password:",nil) modalForWindow:self.browserController.mainBrowserWindow windowTitle:restartExamText] == SEBEnterPasswordCancel) return;
        NSString *password = [self.enterPassword stringValue];
        
        SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
        if ([hashedQuitPassword caseInsensitiveCompare:[keychainManager generateSHAHashString:password]] == NSOrderedSame) {
            // if the correct quit/restart password was entered, restart the exam
            [self.browserController restartDockButtonPressed];
            return;
        } else {
            // Wrong quit password was entered
            NSAlert *newAlert = [NSAlert alertWithMessageText:restartExamText
                                                defaultButton:NSLocalizedString(@"OK", nil)
                                              alternateButton:nil
                                                  otherButton:nil
                                    informativeTextWithFormat:NSLocalizedString(@"Wrong quit/restart password.", nil)];
            [newAlert setAlertStyle:NSCriticalAlertStyle];
            [newAlert runModal];
            return;
        }
    }
    
    // if no quit password is required, then confirm quitting
    int answer = NSRunAlertPanel(restartExamText, NSLocalizedString(@"Are you sure?",nil),
                                 NSLocalizedString(@"Cancel",nil), NSLocalizedString(@"OK",nil), nil);
    switch(answer)
    {
        case NSAlertDefaultReturn:
            return; //Cancel: don't restart exam
        default:
        {
            [self.browserController restartDockButtonPressed];
        }
    }
}


- (void) reloadButtonPressed
{
    [self.browserController reloadDockButtonPressed];
}


- (void) quitButtonPressed
{
    // Post a notification that SEB should conditionally quit
    [[NSNotificationCenter defaultCenter]
     postNotificationName:@"requestExitNotification" object:self];
}


- (NSInteger) showEnterPasswordDialog:(NSString *)text modalForWindow:(NSWindow *)window windowTitle:(NSString *)title {
    // User has asked to see the dialog. Display it.
//    [passwordView setTranslatesAutoresizingMaskIntoConstraints:NO];

    [self.enterPassword setStringValue:@""]; //reset the enterPassword NSSecureTextField
    if (title) enterPasswordDialogWindow.title = title;
    [enterPasswordDialog setStringValue:text];
        
    // If the (main) browser window is full screen, we don't show the dialog as sheet
    if (window && (self.browserController.mainBrowserWindow.isFullScreen || [self.preferencesController preferencesAreOpen])) {
        window = nil;
    }
    
    [NSApp beginSheet: enterPasswordDialogWindow
       modalForWindow: window
        modalDelegate: nil
       didEndSelector: nil
          contextInfo: nil];
    [enterPasswordDialogWindow setOrderedIndex:0];
    [enterPasswordDialogWindow makeKeyAndOrderFront:enterPasswordDialogWindow];
    NSInteger returnCode = [NSApp runModalForWindow: enterPasswordDialogWindow];
    // Dialog is up here.
    [NSApp endSheet: enterPasswordDialogWindow];
    [enterPasswordDialogWindow orderOut: self];
    return returnCode;
}


- (IBAction) okEnterPassword: (id)sender {
    [NSApp stopModalWithCode:SEBEnterPasswordOK];
}


- (IBAction) cancelEnterPassword: (id)sender {
    [NSApp stopModalWithCode:SEBEnterPasswordCancel];
    [self.enterPassword setStringValue:@""];
}


- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
    DDLogDebug(@"sheetDidEnd");
}


- (IBAction) exitSEB:(id)sender {
	// Load quitting preferences from the system's user defaults database
	NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
	NSString *hashedQuitPassword = [preferences secureObjectForKey:@"org_safeexambrowser_SEB_hashedQuitPassword"];
    if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_allowQuit"] == YES) {
		// if quitting SEB is allowed
		
        if (![hashedQuitPassword isEqualToString:@""]) {
			// if quit password is set, then restrict quitting
            if ([self showEnterPasswordDialog:NSLocalizedString(@"Enter quit password:",nil)  modalForWindow:self.browserController.mainBrowserWindow windowTitle:@""] == SEBEnterPasswordCancel) return;
            NSString *password = [self.enterPassword stringValue];
			
            SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
            if ([hashedQuitPassword caseInsensitiveCompare:[keychainManager generateSHAHashString:password]] == NSOrderedSame) {
				// if the correct quit password was entered
				quittingMyself = TRUE; //SEB is terminating itself
                [NSApp terminate: nil]; //quit SEB
            } else {
                // Wrong quit password was entered
                NSAlert *newAlert = [NSAlert alertWithMessageText:NSLocalizedString(@"Wrong Quit Password", nil)
                                                    defaultButton:NSLocalizedString(@"OK", nil)
                                                  alternateButton:nil
                                                      otherButton:nil
                                        informativeTextWithFormat:NSLocalizedString(@"If you don't enter the correct quit password, then you cannot quit SEB.", nil)];
                [newAlert setAlertStyle:NSWarningAlertStyle];
                [newAlert runModal];
            }
        } else {
        // if no quit password is required, then confirm quitting
            int answer = NSRunAlertPanel(NSLocalizedString(@"Quit Safe Exam Browser",nil), NSLocalizedString(@"Are you sure you want to quit SEB?",nil),
                                         NSLocalizedString(@"Cancel",nil), NSLocalizedString(@"Quit",nil), nil);
            switch(answer)
            {
                case NSAlertDefaultReturn:
                    return; //Cancel: don't quit
                default:
                {
                    if ([self.preferencesController preferencesAreOpen]) {
                        [self.preferencesController quitSEB:self];
                    } else {
                        quittingMyself = TRUE; //SEB is terminating itself
                        [NSApp terminate: nil]; //quit SEB
                    }
                }
            }
        }
    } 
}


- (IBAction) openPreferences:(id)sender {
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_allowPreferencesWindow"]) {
        [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        if (![self.preferencesController preferencesAreOpen]) {
            // Load admin password from the system's user defaults database
            NSString *hashedAdminPW = [preferences secureObjectForKey:@"org_safeexambrowser_SEB_hashedAdminPassword"];
            if (![hashedAdminPW isEqualToString:@""]) {
                // If admin password is set, then restrict access to the preferences window
                if ([self showEnterPasswordDialog:NSLocalizedString(@"Enter administrator password:",nil)  modalForWindow:self.browserController.mainBrowserWindow windowTitle:@""] == SEBEnterPasswordCancel) return;
                NSString *password = [self.enterPassword stringValue];
                SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
                if ([hashedAdminPW caseInsensitiveCompare:[keychainManager generateSHAHashString:password]] != NSOrderedSame) {
                    //if hash of entered password is not equal to the one in preferences
                    // Wrong admin password was entered
                    NSAlert *newAlert = [NSAlert alertWithMessageText:NSLocalizedString(@"Wrong Admin Password", nil)
                                                        defaultButton:NSLocalizedString(@"OK", nil)
                                                      alternateButton:nil                                                      otherButton:nil
                                            informativeTextWithFormat:NSLocalizedString(@"If you don't enter the correct SEB administrator password, then you cannot open preferences.", nil)];
                    [newAlert setAlertStyle:NSWarningAlertStyle];
                    [newAlert runModal];

                    return;
                }
            }
            // Switch the kiosk mode temporary off and override settings for menu bar: Show it while prefs are open
            [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
            [self switchKioskModeAppsAllowed:YES overrideShowMenuBar:YES];
            // Close the black background covering windows
            [self closeCapWindows];

            // Show preferences window
            [self.preferencesController openPreferencesWindow];
            
            // Show the Config menu (in menu bar)
            [configMenu setHidden:NO];
        } else {
            // Show preferences window
            DDLogDebug(@"openPreferences: Preferences already open, just show Window");
            [self.preferencesController showPreferencesWindow:nil];
        }
    }
}


- (void)preferencesClosed:(NSNotification *)notification
{
    [self performAfterPreferencesClosedActions];

    // Reinforce kiosk mode after a delay, so eventually visible fullscreen apps get hidden again
    [self performSelector:@selector(requestedReinforceKioskMode:) withObject: nil afterDelay: 1];
}


- (void)performAfterPreferencesClosedActions
{
    // Hide the Config menu (in menu bar)
    [configMenu setHidden:YES];
    
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    
    DDLogInfo(@"Preferences window closed, reopening cap windows.");
    
    // Open new covering background windows on all currently available screens
    [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
    [self coverScreens];
    
    [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
    [self.browserController.mainBrowserWindow makeKeyAndOrderFront:self];
    
    // Switch the kiosk mode on again
    [self setElevateWindowLevels];
    
//    [self startKioskMode];
    BOOL allowSwitchToThirdPartyApps = ![preferences secureBoolForKey:@"org_safeexambrowser_elevateWindowLevels"];
    [self switchKioskModeAppsAllowed:allowSwitchToThirdPartyApps overrideShowMenuBar:NO];

    // Update URL filter flags and rules
    [[SEBURLFilter sharedSEBURLFilter] updateFilterRules];    
    // Update URL filter ignore rules
    [[SEBURLFilter sharedSEBURLFilter] updateIgnoreRuleList];
}


- (void)preferencesClosedRestartSEB:(NSNotification *)notification
{
    [self performAfterPreferencesClosedActions];
    
    [self requestedRestart:nil];

    // Reinforce kiosk mode after a delay, so eventually visible fullscreen apps get hidden again
    [self performSelector:@selector(requestedReinforceKioskMode:) withObject: nil afterDelay: 1];
}


- (void)requestedQuitWPwd:(NSNotification *)notification
{
    [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
    
    int answer = NSRunAlertPanel(NSLocalizedString(@"Quit Safe Exam Browser",nil), NSLocalizedString(@"Are you sure you want to quit SEB?",nil),
                                 NSLocalizedString(@"Cancel",nil), NSLocalizedString(@"Quit",nil), nil);
    switch(answer)
    {
        case NSAlertDefaultReturn:
            return; //Cancel: don't quit
        default:
        {
            if ([self.preferencesController preferencesAreOpen]) {
                [self.preferencesController quitSEB:self];
            } else {
                quittingMyself = TRUE; //SEB is terminating itself
                [NSApp terminate: nil]; //quit SEB
            }
        }
    }
}


- (void)requestedQuit:(NSNotification *)notification
{
    quittingMyself = TRUE; //SEB is terminating itself
    [NSApp terminate: nil]; //quit SEB
}


- (void)requestedRestart:(NSNotification *)notification
{
    DDLogInfo(@"Requested Restart");

    // Clear Pasteboard
    [self clearPasteboardSavingCurrentString];
    
    // Check if launched SEB is placed ("installed") in an Applications folder
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *currentSEBBundlePath =[[NSBundle mainBundle] bundlePath];
    if (![self isInApplicationsFolder:currentSEBBundlePath]) {
        // Has SEB to be installed in an Applications folder?
        if ([preferences secureBoolForKey:@"org_safeexambrowser_SEB_forceAppFolderInstall"]) {
#ifndef DEBUG
            DDLogError(@"Current settings require SEB to be installed in an Applications folder, but it isn't! SEB will therefore quit!");
            _forceAppFolder = YES;
            quittingMyself = TRUE; //SEB is terminating itself
            [NSApp terminate: nil]; //quit SEB
#else
            DDLogDebug(@"Current settings require SEB to be installed in an Applications folder, but it isn't! SEB would quit if not Debug build.");
#endif
        }
    }
    
    // Adjust screen shot blocking
    [self.systemManager adjustSC];
    
    // Close all browser windows (documents)
    [[NSDocumentController sharedDocumentController] closeAllDocumentsWithDelegate:self
                                                               didCloseAllSelector:@selector(documentController:didCloseAll:contextInfo:)
                                                                       contextInfo: nil];
    self.browserController.currentMainHost = nil;

    // Re-Initialize file logger if logging enabled
    [self initializeLogger];
    
    // Update URL filter flags and rules
    [[SEBURLFilter sharedSEBURLFilter] updateFilterRules];
    // Update URL filter ignore rules
    [[SEBURLFilter sharedSEBURLFilter] updateIgnoreRuleList];
    
    // Check for command key being held down
    int modifierFlags = [NSEvent modifierFlags];
    _cmdKeyDown = (0 != (modifierFlags & NSCommandKeyMask));
    if (_cmdKeyDown) {
        if ([[NSUserDefaults standardUserDefaults] secureBoolForKey:@"org_safeexambrowser_SEB_enableAppSwitcherCheck"]) {
            // Show alert that keys were hold while starting SEB
            DDLogWarn(@"Command key is pressed while restarting SEB, show dialog asking to release it.");
            NSAlert *newAlert = [[NSAlert alloc] init];
            [newAlert setMessageText:NSLocalizedString(@"Holding Command Key Not Allowed!", nil)];
            [newAlert setInformativeText:NSLocalizedString(@"Holding the Command key down while restarting SEB is not allowed.", nil)];
            [newAlert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
            [newAlert setAlertStyle:NSCriticalAlertStyle];
            [newAlert runModal];
            _cmdKeyDown = NO;
            
            quittingMyself = TRUE; //SEB is terminating itself
            [NSApp terminate: nil]; //quit SEB
        } else {
            DDLogWarn(@"Command key is pressed, but not forbidden in current settings");
        }

    }
    
    // Set kiosk/presentation mode in case it changed
    [self setElevateWindowLevels];
    [self startKioskMode];
    
    // Set up SEB Browser
    self.browserController = [[SEBBrowserController alloc] init];
    
    // Reopen SEB Dock
    [self openSEBDock];
    self.browserController.dockController = self.dockController;

    // Reopen main browser window and load start URL
    [self.browserController openMainBrowserWindow];

    // Adjust screen locking
    [self adjustScreenLocking:self];
    
    // ToDo: Opening of additional resources (but not only here, also when starting SEB)
//    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
//    NSArray *additionalResources = [preferences secureArrayForKey:@"org_safeexambrowser_SEB_additionalResources"];
//    for (NSDictionary *resource in additionalResources) {
//        if ([resource valueForKey:@"active"] == [NSNumber numberWithBool:YES]) {
//            NSString *resourceURL = [resource valueForKey:@"URL"];
//            NSString *resourceTitle = [resource valueForKey:@"title"];
//            if ([resource valueForKey:@"autoOpen"] == [NSNumber numberWithBool:YES]) {
//                [self openResourceWithURL:resourceURL andTitle:resourceTitle];
//            }
//        }
//    }
}


- (void)documentController:(NSDocumentController *)docController  didCloseAll: (BOOL)didCloseAll contextInfo:(void *)contextInfo
{
    DDLogDebug(@"documentController: %@ didCloseAll: %hhd contextInfo: %@", docController, didCloseAll, contextInfo);
}


- (void)requestedReinforceKioskMode:(NSNotification *)notification
{
    if (![self.preferencesController preferencesAreOpen]) {
        DDLogDebug(@"Reinforcing the kiosk mode was requested");
        // Switch the strict kiosk mode temporary off
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
        [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
        [self switchKioskModeAppsAllowed:YES overrideShowMenuBar:NO];
        
        // Close the black background covering windows
        [self closeCapWindows];
        
        // Reopen the covering Windows and reset the windows elevation levels
        DDLogDebug(@"requestedReinforceKioskMode: Reopening cap windows.");
        if (self.browserController.mainBrowserWindow.isVisible) {
            [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
            [self.browserController.mainBrowserWindow makeKeyAndOrderFront:self];
        }
        
        // Open new covering background windows on all currently available screens
        [preferences setSecureBool:NO forKey:@"org_safeexambrowser_elevateWindowLevels"];
        [self coverScreens];
        
        // Switch the proper kiosk mode on again
        [self setElevateWindowLevels];
        
        //    [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        
        BOOL allowSwitchToThirdPartyApps = [preferences secureBoolForKey:@"org_safeexambrowser_SEB_allowSwitchToApplications"];
        [self switchKioskModeAppsAllowed:allowSwitchToThirdPartyApps overrideShowMenuBar:NO];
        
        [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        [self.browserController.mainBrowserWindow makeKeyAndOrderFront:self];
    }
}


/*- (void)documentController:(NSDocumentController *)docController  didCloseAll: (BOOL)didCloseAll contextInfo:(void *)contextInfo {
#ifdef DEBUG
    DDLogDebug(@"All documents closed: %@", [NSNumber numberWithBool:didCloseAll]);
#endif
    return;
}*/

- (void) requestedShowAbout:(NSNotification *)notification
{
    [self showAbout:self];
}

- (IBAction)showAbout:(id)sender
{
    [aboutWindow setStyleMask:NSBorderlessWindowMask];
	[aboutWindow center];
	//[aboutWindow orderFront:self];
    //[aboutWindow setLevel:NSMainMenuWindowLevel];
    [[NSApplication sharedApplication] runModalForWindow:aboutWindow];
}


- (void) requestedShowHelp:(NSNotification *)notification
{
    [self showHelp:self];
}

- (IBAction) showHelp: (id)sender
{
    // Open new browser window containing WebView and show it
    SEBWebView *newWebView = [self.browserController openAndShowWebView];
    // Load manual page URL in new browser window
    NSString *urlText = helpUrl;
	[[newWebView mainFrame] loadRequest:
     [NSURLRequest requestWithURL:[NSURL URLWithString:urlText]]];
}


- (void) closeDocument:(id)document
{
    [document close];
}

- (void) switchPluginsOn:(NSNotification *)notification
{
#ifndef __i386__        // Plugins can't be switched on in the 32-bit Intel build
    [[self.webView preferences] setPlugInsEnabled:YES];
#endif
}


#pragma mark Delegates

// Called when SEB should be terminated
- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication *)sender {
	if (quittingMyself) {
		return NSTerminateNow; //SEB wants to quit, ok, so it should happen
	} else { //SEB should be terminated externally(!)
		return NSTerminateCancel; //this we can't allow, sorry...
	}
}

// Called just before SEB will be terminated
- (void) applicationWillTerminate:(NSNotification *)aNotification
{
    if (_forceAppFolder) {
        // Show alert that SEB is not placed in Applications folder
        NSString *applicationsDirectoryName = @"Applications";
        NSString *localizedApplicationDirectoryName = [[NSFileManager defaultManager] displayNameAtPath:NSSearchPathForDirectoriesInDomains(NSApplicationDirectory, NSLocalDomainMask, YES).lastObject];
        NSString *localizedAndInternalApplicationDirectoryName;
        if ([localizedApplicationDirectoryName isEqualToString:applicationsDirectoryName]) {
            // System language is English or the Applications folder is named identically in user's current language
            localizedAndInternalApplicationDirectoryName = applicationsDirectoryName;
        } else {
            NSBundle *preferredLanguageBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:[[NSLocale preferredLanguages] objectAtIndex:0] ofType:@"lproj"]];
            if (preferredLanguageBundle) {
                localizedAndInternalApplicationDirectoryName = [NSString stringWithFormat:@"'%@' ('%@')", localizedApplicationDirectoryName, applicationsDirectoryName];
            } else {
                // User selected language is one which SEB doesn't support
                localizedAndInternalApplicationDirectoryName = [NSString stringWithFormat:@"%@ ('%@')", applicationsDirectoryName, localizedApplicationDirectoryName];
                localizedApplicationDirectoryName = applicationsDirectoryName;
            }
        }
        NSAlert *newAlert = [[NSAlert alloc] init];
        [newAlert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"SEB Not in %@ Folder!", nil), localizedApplicationDirectoryName]];
        [newAlert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"SEB has to be placed in the %@ folder in order for all features to work correctly. Move the 'Safe Exam Browser' app to your %@ folder and make sure that you don't have any other versions of SEB installed on your system. SEB will quit now.", nil), localizedApplicationDirectoryName, localizedAndInternalApplicationDirectoryName]];
        [newAlert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
        [newAlert setAlertStyle:NSCriticalAlertStyle];
        [newAlert runModal];
    } else if (_cmdKeyDown) {
        // Show alert that keys were hold while starting SEB
        NSAlert *newAlert = [[NSAlert alloc] init];
        [newAlert setMessageText:NSLocalizedString(@"Holding Command Key Not Allowed!", nil)];
        [newAlert setInformativeText:NSLocalizedString(@"Holding the Command key down while starting SEB is not allowed. Restart SEB without holding any keys.", nil)];
        [newAlert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
        [newAlert setAlertStyle:NSCriticalAlertStyle];
        [newAlert runModal];
    }
    
    BOOL success = [self.systemManager restoreSC];
    DDLogDebug(@"Success of restoring SC: %hhd", success);
    
    runningAppsWhileTerminating = [[NSWorkspace sharedWorkspace] runningApplications];
    NSRunningApplication *iterApp;
    for (iterApp in runningAppsWhileTerminating) 
    {
        NSString *appBundleID = [iterApp valueForKey:@"bundleIdentifier"];
        if ([visibleApps indexOfObject:appBundleID] != NSNotFound) {
            [iterApp unhide]; //unhide the originally visible application
        }
    }
    [self clearPasteboardCopyingBrowserExamKey];
    
	// Clear the current Browser Exam Key
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    [preferences setSecureObject:[NSData data] forKey:@"org_safeexambrowser_currentData"];

	// Clear the browser cache in ~/Library/Caches/org.safeexambrowser.SEB.Safe-Exam-Browser/
	NSURLCache *cache = [NSURLCache sharedURLCache];
	[cache removeAllCachedResponses];
    
	// Allow display and system to sleep again
	//IOReturn success = IOPMAssertionRelease(assertionID1);
	IOPMAssertionRelease(assertionID1);
	/*// Allow system to sleep again
	success = IOPMAssertionRelease(assertionID2);*/
}


// Prevent an untitled document to be opened at application launch
- (BOOL) applicationShouldOpenUntitledFile:(NSApplication *)sender {
    DDLogDebug(@"Invoked applicationShouldOpenUntitledFile with answer NO!");
    return NO;
}

/*- (void)windowDidResignKey:(NSNotification *)notification {
	[NSApp activateIgnoringOtherApps: YES];
	[self.browserController.browserWindow 
	 makeKeyAndOrderFront:self];
	#ifdef DEBUG
	DDLogDebug(@"[self.browserController.browserWindow makeKeyAndOrderFront]");
	NSBeep();
	#endif
	
}
*/


// Called when currentPresentationOptions change
- (void) observeValueForKeyPath:(NSString *)keyPath
					  ofObject:id
                        change:(NSDictionary *)change
                       context:(void *)context
{
    // If the startKioskMode method changed presentation options, then we don't do nothing here
    if ([keyPath isEqual:@"currentSystemPresentationOptions"]) {
        if ([[MyGlobals sharedMyGlobals] startKioskChangedPresentationOptions]) {
            [[MyGlobals sharedMyGlobals] setStartKioskChangedPresentationOptions:NO];
            return;
        }

		// Current Presentation Options changed, so make SEB active and reset them
        // Load preferences from the system's user defaults database
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
        BOOL allowSwitchToThirdPartyApps = ![preferences secureBoolForKey:@"org_safeexambrowser_elevateWindowLevels"];
        DDLogInfo(@"currentSystemPresentationOptions changed!");
        // If plugins are enabled and there is a Flash view in the webview ...
        if ([[self.webView preferences] arePlugInsEnabled]) {
            NSView* flashView = [self.browserController.mainBrowserWindow findFlashViewInView:webView];
            if (flashView) {
                if (!allowSwitchToThirdPartyApps || ![preferences secureBoolForKey:@"org_safeexambrowser_SEB_allowFlashFullscreen"]) {
                    // and either third party Apps or Flash fullscreen is allowed
                    //... then we switch plugins off and on again to prevent 
                    //the security risk Flash full screen video
#ifndef __i386__        // Plugins can't be switched on in the 32-bit Intel build
                    [[self.webView preferences] setPlugInsEnabled:NO];
                    [[self.webView preferences] setPlugInsEnabled:YES];
#endif
                } else {
                    //or we set the flag that Flash tried to switch presentation options
                    [[MyGlobals sharedMyGlobals] setFlashChangedPresentationOptions:YES];
                }
            }
        }
        //[self startKioskMode];
        //We don't reset the browser window size and position anymore
        //[(BrowserWindow*)self.browserController.browserWindow setCalculatedFrame];
        if (!allowSwitchToThirdPartyApps && ![self.preferencesController preferencesAreOpen]) {
            // If third party Apps are not allowed, we switch back to SEB
            DDLogInfo(@"Switched back to SEB after currentSystemPresentationOptions changed!");
            [[NSRunningApplication currentApplication] activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];

//            [[NSNotificationCenter defaultCenter] postNotificationName:@"requestRegainActiveStatus" object:self];

//            [self.browserController.browserWindow makeKeyAndOrderFront:self];
            //[self startKioskMode];
            [self regainActiveStatus:nil];
            //[self.browserController.browserWindow setFrame:[[self.browserController.browserWindow screen] frame] display:YES];
        }
    }
}
 
@end
