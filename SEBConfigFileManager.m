//
//  SEBConfigFileManager.m
//  SafeExamBrowser
//
//  Created by Daniel R. Schneider on 28.04.13.
//
//

#import "SEBConfigFileManager.h"
#import "NSUserDefaults+SEBEncryptedUserDefaults.h"
#import "RNDecryptor.h"
#import "RNEncryptor.h"
#import "SEBKeychainManager.h"
#import "SEBCryptor.h"
#import "MyGlobals.h"
#import "Constants.h"

@implementation SEBConfigFileManager


-(id) init
{
    self = [super init];
    if (self) {
        self.sebController = [NSApp delegate];
    }
    return self;
}


-(BOOL) readSEBConfig:(NSData *)sebData
{
    NSString *prefixString;
    
    // save the data including the first 4 bytes for the case that it's acutally an unencrypted XML plist
    NSData *sebDataUnencrypted = [sebData copy];

    // Get 4-char prefix
    prefixString = [self getPrefixStringFromData:&sebData];
#ifdef DEBUG
    NSLog(@"Outer prefix of .seb settings file: %@",prefixString);
#endif
    NSError *error = nil;

    //// Check prefix identifying encryption modes

    // Prefix = pkhs ("Public Key Hash") ?
    
    if ([prefixString isEqualToString:@"pkhs"]) {

        // Decrypt with cryptographic identity/private key
        sebData = [self decryptDataWithPublicKeyHashPrefix:sebData error:&error];
        if (error) {
            return NO;
        }

        // Get 4-char prefix again
        // and remaining data without prefix, which is either plain or still encoded with password
        prefixString = [self getPrefixStringFromData:&sebData];
#ifdef DEBUG
        NSLog(@"Inner prefix of .seb settings file: %@", prefixString);
#endif
    }
    
    // Prefix = pswd ("Password") ?
    
    if ([prefixString isEqualToString:@"pswd"]) {

        // Decrypt with password
        // if the user enters the right one
        NSData *sebDataDecrypted = nil;
        // Allow up to 5 attempts for entering decoding password
        int i = 5;
        do {
            i--;
            // Prompt for password
            if ([self.sebController showEnterPasswordDialog:NSLocalizedString(@"Enter Password:",nil) modalForWindow:nil windowTitle:NSLocalizedString(@"Loading New SEB Settings",nil)] == SEBEnterPasswordCancel) return NO;
            NSString *password = [self.sebController.enterPassword stringValue];
            if (!password) return NO;
            error = nil;
            sebDataDecrypted = [RNDecryptor decryptData:sebData withPassword:password error:&error];
            // in case we get an error we allow the user to try it again
        } while (error && i>0);
        if (error) {
            //wrong password entered in 5th try: stop reading .seb file
            return NO;
        }
        sebData = sebDataDecrypted;
    } else {
        
        // Prefix = pwcc ("Password Configuring Client") ?
        
        if ([prefixString isEqualToString:@"pwcc"]) {
            
            // Decrypt with password and configure local client settings
            // and quit afterwards, returning if reading the .seb file was successfull
            return [self decryptDataWithPasswordAndConfigureClient:sebData];
            
        } else {

            // Prefix = plnd ("Plain Data") ?
            
            if (![prefixString isEqualToString:@"plnd"]) {
                // No valid 4-char prefix was found in the .seb file
                // Check if .seb file is unencrypted
                if ([prefixString isEqualToString:@"<?xm"]) {
                    // .seb file seems to be an unencrypted XML plist
                    // get the original data including the first 4 bytes
                    sebData = sebDataUnencrypted;
                } else {
                    // No valid prefix and no unencrypted file with valid header
                    // cancel reading .seb file
                    NSRunAlertPanel(NSLocalizedString(@"Loading new SEB settings failed!", nil),
                                    NSLocalizedString(@"This settings file cannot be used. It may have been created by an newer, incompatible version of SEB or it is corrupted.", nil),
                                    NSLocalizedString(@"OK", nil), nil, nil);
                    return NO;
                }
            }
        }
    }
    
    //if decrypting wasn't successfull then stop here
    if (!sebData) return NO;
    
    // Get preferences dictionary from decrypted data
    error = nil;
    //NSDictionary *sebPreferencesDict = [NSKeyedUnarchiver unarchiveObjectWithData:sebData];
    NSDictionary *sebPreferencesDict = [self getPreferencesDictionaryFromConfigData:sebData error:&error];
    if (error) {
        [NSApp presentError:error];
//        NSRunAlertPanel(NSLocalizedString(@"Loading new SEB settings failed!", nil),
//                        NSLocalizedString(@"This settings file is corrupted and cannot be used.", nil),
//                        NSLocalizedString(@"OK", nil), nil, nil);
        return NO; //we abort reading the new settings here
    }

    // Check if a some value is from a wrong class (another than the value from default settings)
    // and quit reading .seb file if a wrong value was found
    if (![self checkClassOfSettings:sebPreferencesDict]) return NO;
    
    // Release preferences window so bindings get synchronized properly with the new loaded values
    [self.sebController.preferencesController releasePreferencesWindow];
    
    // Switch to private UserDefaults (saved non-persistantly in memory instead in ~/Library/Preferences)
//    NSMutableDictionary *privatePreferences = [NSUserDefaults privateUserDefaults];
    [NSUserDefaults setUserDefaultsPrivate:YES];
    
    // Write values from .seb config file to the local preferences (shared UserDefaults)
    [self saveIntoUserDefaults:sebPreferencesDict];

#ifdef DEBUG
//    NSLog(@"Private preferences set: %@", privatePreferences);
#endif
    [[SEBCryptor sharedSEBCryptor] updateEncryptedUserDefaults];
    [self.sebController.preferencesController initPreferencesWindow];
    
    return YES; //reading preferences was successful
}


-(BOOL) decryptDataWithPasswordAndConfigureClient:(NSData *)sebData
{
    // Configure local client settings
    
    //get admin password hash
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *hashedAdminPassword = [preferences secureObjectForKey:@"org_safeexambrowser_SEB_hashedAdminPassword"];
    //if (!hashedAdminPassword) {
    //   hashedAdminPassword = @"";
    //}
    NSDictionary *sebPreferencesDict = nil;
    NSError *error = nil;
    NSData *decryptedSebData = [RNDecryptor decryptData:sebData withPassword:hashedAdminPassword error:&error];
    if (error) {
        //if decryption with admin password didn't work, try it with an empty password
        error = nil;
        decryptedSebData = [RNDecryptor decryptData:sebData withPassword:@"" error:&error];
        if (!error) {
            //Decrypting with empty password worked:
            //Check if the openend reconfiguring seb file has the same admin password inside like the current one
            sebPreferencesDict = [self getPreferencesDictionaryFromConfigData:decryptedSebData error:&error];
            if (error) {
                [NSApp presentError:error];
                return NO; //we abort reading the new settings here
            }
            NSString *sebFileHashedAdminPassword = [sebPreferencesDict objectForKey:@"hashedAdminPassword"];
            if (![hashedAdminPassword isEqualToString:sebFileHashedAdminPassword]) {
                //No: The admin password inside the .seb file wasn't the same like the current one
                //now we have to ask for the current admin password and
                //allow reconfiguring only if the user enters the right one
                // Allow up to 5 attempts for entering current admin password
                int i = 5;
                NSString *password = nil;
                NSString *hashedPassword;
                BOOL passwordsMatch;
                SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
                do {
                    i--;
                    // Prompt for password
                    if ([self.sebController showEnterPasswordDialog:NSLocalizedString(@"You can only reconfigure SEB by entering the current SEB administrator password (because it was changed since installing SEB):",nil) modalForWindow:nil windowTitle:NSLocalizedString(@"Reconfiguring Local SEB Settings",nil)] == SEBEnterPasswordCancel) return NO;
                    password = [self.sebController.enterPassword stringValue];
                    hashedPassword = [keychainManager generateSHAHashString:password];
                    passwordsMatch = [hashedAdminPassword isEqualToString:hashedPassword];
                    // in case we get an error we allow the user to try it again
                } while ((!password || !passwordsMatch) && i>0);
                if (!passwordsMatch) {
                    //wrong password entered in 5th try: stop reading .seb file
                    return NO;
                }
            }
            
        } else {
            //if decryption with admin password didn't work, ask for the password the .seb file was encrypted with
            //empty password means no admin pw on clients and should not be hashed
            //NSData *sebDataDecrypted = nil;
            // Allow up to 3 attempts for entering decoding password
            int i = 3;
            do {
                i--;
                // Prompt for password
                if ([self.sebController showEnterPasswordDialog:NSLocalizedString(@"Enter password used to encrypt .seb file:",nil) modalForWindow:nil windowTitle:NSLocalizedString(@"Reconfiguring Local SEB Settings",nil)] == SEBEnterPasswordCancel) return NO;
                NSString *password = [self.sebController.enterPassword stringValue];
                if (!password) return NO;
                error = nil;
                decryptedSebData = [RNDecryptor decryptData:sebData withPassword:password error:&error];
                // in case we get an error we allow the user to try it again
            } while (error && i>0);
            if (error) {
                //wrong password entered in 5th try: stop reading .seb file
                return NO;
            }
        }
    }
    
    sebData = decryptedSebData;
    if (!error) {
        //
        // Decryption worked
        //
        // Get preferences dictionary from decrypted data
        
        
        NSError *error = nil;
        // If we don't have the dictionary yet from above
        if (!sebPreferencesDict) sebPreferencesDict = [self getPreferencesDictionaryFromConfigData:sebData error:&error];
        if (error) {
            [NSApp presentError:error];
            return NO; //we abort reading the new settings here
        }
        
        // Check if a some value is from a wrong class (another than the value from default settings)
        // and quit reading .seb file if a wrong value was found
        if (![self checkClassOfSettings:sebPreferencesDict]) return NO;
        
        //switch to system's UserDefaults
        [NSUserDefaults setUserDefaultsPrivate:NO];
        
        // Write values from .seb config file to the local preferences (shared UserDefaults)
        [self saveIntoUserDefaults:sebPreferencesDict];
        
        int answer = NSRunAlertPanel(NSLocalizedString(@"SEB Re-Configured",nil), NSLocalizedString(@"Local settings of SEB have been reconfigured. Do you want to start working with SEB now or quit?",nil),
                                     NSLocalizedString(@"Continue",nil), NSLocalizedString(@"Quit",nil), nil);
        switch(answer)
        {
            case NSAlertDefaultReturn:
                break; //Cancel: don't quit
            default:
                self.sebController.quittingMyself = TRUE; //SEB is terminating itself
                [NSApp terminate: nil]; //quit SEB
        }
        [[SEBCryptor sharedSEBCryptor] updateEncryptedUserDefaults];
    }
    return YES; //reading preferences was successful
}


// Check if a some value is from a wrong class (another than the value from default settings)
-(BOOL)checkClassOfSettings:(NSDictionary *)sebPreferencesDict
{
    // get default settings
    NSDictionary *defaultSettings = [[NSUserDefaults standardUserDefaults] sebDefaultSettings];
    
    // Check if a some value is from a wrong class other than the value from default settings)
    for (NSString *key in sebPreferencesDict) {
        NSString *keyWithPrefix = [self prefixKey:key];
        id value = [sebPreferencesDict objectForKey:key];
        id defaultValue = [defaultSettings objectForKey:keyWithPrefix];
        Class valueClass = [value superclass];
        Class defaultValueClass = [defaultValue superclass];
        if (valueClass && defaultValueClass && !([defaultValue isKindOfClass:valueClass] || [value isKindOfClass:defaultValueClass])) {
            //if (valueClass && defaultValueClass && valueClass != defaultValueClass) {
            //if (!(object_getClass([value class]) == object_getClass([defaultValue class]))) {
            //if (defaultValue && !([value class] == [defaultValue class])) {
            // Class of newly loaded value is different than the one from the default value
            // If yes, then cancel reading .seb file
            NSRunAlertPanel(NSLocalizedString(@"Loading new SEB settings failed!", nil),
                            NSLocalizedString(@"This settings file cannot be used. It may have been created by an older, incompatible version of SEB or it is corrupted.", nil),
                            NSLocalizedString(@"OK", nil), nil, nil);
            return NO; //we abort reading the new settings here
        }
    }
    return YES;
}


// Save imported settings into private user defaults (either in memory or local shared UserDefaults)
-(void) saveIntoUserDefaults:(NSDictionary *)sebPreferencesDict
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    // get default settings
    NSDictionary *defaultSettings = [preferences sebDefaultSettings];

    // Write SEB default values to the local preferences
    for (NSString *key in defaultSettings) {
        id value = [defaultSettings objectForKey:key];
        if (value) [preferences setSecureObject:value forKey:key];
    }
    
    // Write values from .seb config file to the local preferences
    for (NSString *key in sebPreferencesDict) {
        id value = [sebPreferencesDict objectForKey:key];
        if ([key isEqualToString:@"allowPreferencesWindow"]) {
            [preferences setSecureObject:
             [[sebPreferencesDict objectForKey:key] copy]
                                  forKey:@"org_safeexambrowser_enablePreferencesWindow"];
        }
        NSString *keyWithPrefix = [self prefixKey:key];
        
        // If imported settings are being saved into shared UserDefaults
        // Import embedded certificates (and identities) into the keychain
        // but don't save into local preferences
        if (!NSUserDefaults.userDefaultsPrivate && [key isEqualToString:@"embeddedCertificates"]) {
            SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
            for (NSDictionary *certificate in value) {
                int certificateType = [[certificate objectForKey:@"type"] integerValue];
                NSData *certificateData = [certificate objectForKey:@"certificateData"];
                switch (certificateType) {
                    case certificateTypeSSLClientCertificate:
                        if (certificateData) {
                            BOOL success = [keychainManager importCertificateFromData:certificateData];
#ifdef DEBUG
                            NSLog(@"Importing SSL certificate <%@> into Keychain %@", [certificate objectForKey:@"name"], success ? @"succedded" : @"failed");
#endif
                        }
                        break;
                        
                    case certificateTypeIdentity:
                        if (certificateData) {
                            BOOL success = [keychainManager importIdentityFromData:certificateData];
#ifdef DEBUG
                            NSLog(@"Importing identity <%@> into Keychain %@", [certificate objectForKey:@"name"], success ? @"succedded" : @"failed");
#endif
                        }
                        break;
                }
            }
            
        } else {
            // other values can be saved into local preferences
            [preferences setSecureObject:value forKey:keyWithPrefix];
        }
    }
}


-(NSData *) decryptDataWithPublicKeyHashPrefix:(NSData *)sebData error:(NSError **)error
{
    // Get 20 bytes public key hash prefix
    // and remaining data with the prefix stripped
    NSData *publicKeyHash = [self getPrefixDataFromData:&sebData withLength:publicKeyHashLenght];
    
    SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
    SecKeyRef privateKeyRef = [keychainManager getPrivateKeyFromPublicKeyHash:publicKeyHash];
    if (!privateKeyRef) {
        NSRunAlertPanel(NSLocalizedString(@"Error Decrypting Settings", nil),
                        NSLocalizedString(@"The identity needed to decrypt settings has not been found in the keychain!", nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
        return NO;
    }
#ifdef DEBUG
    NSLog(@"Private key retrieved with hash: %@", privateKeyRef);
#endif
    
    sebData = [keychainManager decryptData:sebData withPrivateKey:privateKeyRef];
    
    return sebData;
}


-(NSString *) getPrefixStringFromData:(NSData **)data
{
    NSData *prefixData = [self getPrefixDataFromData:data withLength:sebConfigFilePrefixLength];
    return [[NSString alloc] initWithData:prefixData encoding:NSUTF8StringEncoding];
}


-(NSData *) getPrefixDataFromData:(NSData **)data withLength:(NSUInteger)prefixLength
{
    // Get prefix with indicated length
    NSRange prefixRange = {0, prefixLength};
    NSData *prefixData = [*data subdataWithRange:prefixRange];
    
    // Get data without the stripped prefix
    NSRange range = {prefixLength, [*data length]-prefixLength};
    *data = [*data subdataWithRange:range];
    
    return prefixData;
}


// Get preferences dictionary from decrypted data
-(NSDictionary *) getPreferencesDictionaryFromConfigData:(NSData *)sebData error:(NSError **)error
{
    NSError *plistError = nil;
    NSDictionary *sebPreferencesDict = [NSPropertyListSerialization propertyListWithData:sebData
                                                                                            options:0
                                                                                             format:NULL
                                                                                              error:&plistError];
    if (plistError) {
        // If it exists, then add the localized error reason from serializing the plist to the error object
        NSString *failureReason = [plistError localizedFailureReason];
        if (!failureReason) failureReason = @"";
        NSMutableDictionary *newErrorDict =
        [NSMutableDictionary dictionaryWithDictionary:@{ NSLocalizedDescriptionKey :
                                                             NSLocalizedString(@"Loading new SEB settings failed!", nil),
                                                         NSLocalizedFailureReasonErrorKey :
                                                             [NSString stringWithFormat:@"%@\n%@", NSLocalizedString(@"This settings file is corrupted and cannot be used.", nil), failureReason]
                                        }];
        
        NSError *newError = [[NSError alloc] initWithDomain:sebErrorDomain
                                                       code:1 userInfo:newErrorDict];
        *error = newError;
        sebPreferencesDict = nil; //we don't have any settings to return
    }
    return sebPreferencesDict;
}


// Add the prefix required to identify SEB keys in UserDefaults to the key 
- (NSString *) prefixKey:(NSString *)key
{
    NSString *keyWithPrefix;
    if ([key isEqualToString:@"originatorVersion"] ||
        [key isEqualToString:@"copyBrowserExamKeyToClipboardWhenQuitting"]) {
        keyWithPrefix = [NSString stringWithFormat:@"org_safeexambrowser_%@", key];
    } else {
        keyWithPrefix = [NSString stringWithFormat:@"org_safeexambrowser_SEB_%@", key];
    }
    return keyWithPrefix;
}


// Encrypt preferences using a certificate
-(NSData *) encryptData:(NSData *) data usingIdentity:(SecIdentityRef) identityRef
{
    SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
    
    //get certificate from selected identity
    SecCertificateRef certificateRef = [keychainManager getCertificateFromIdentity:identityRef];
    
    //get public key hash from selected identity's certificate
    NSData* publicKeyHash = [keychainManager getPublicKeyHashFromCertificate:certificateRef];
    
    //encrypt data using public key
    NSData *encryptedData = [keychainManager encryptData:data withPublicKeyFromCertificate:certificateRef];
    
    //Prefix indicating data has been encrypted with a public key identified by hash
    const char *utfString = [@"pkhs" UTF8String];
    NSMutableData *encryptedSebData = [NSMutableData dataWithBytes:utfString length:sebConfigFilePrefixLength];
    //append public key hash
    [encryptedSebData appendData:publicKeyHash];
    //append encrypted data
    [encryptedSebData appendData:encryptedData];
    
    return encryptedSebData;
}


// Encrypt preferences using a password
- (NSData*) encryptData:(NSData*)data usingPassword:password forConfiguringClient:(BOOL)configureClient {
    const char *utfString;
    // Check if .seb file should start exam or configure client
    if (configureClient == NO) {
        // prefix string for starting exam: normal password will be prompted
        utfString = [@"pswd" UTF8String];
    } else {
        // prefix string for configuring client: configuring password will either be admin pw on client
        // or if no admin pw on client set: empty pw //(((or prompt pw before configuring)))
        utfString = [@"pwcc" UTF8String];
        if (![password isEqualToString:@""]) {
            //empty password means no admin pw on clients and should not be hashed
            SEBKeychainManager *keychainManager = [[SEBKeychainManager alloc] init];
            password = [keychainManager generateSHAHashString:password];
        }
    }
    NSMutableData *encryptedSebData = [NSMutableData dataWithBytes:utfString length:4];
    NSError *error;
    NSData *encryptedData = [RNEncryptor encryptData:data
                                        withSettings:kRNCryptorAES256Settings
                                            password:password
                                               error:&error];;
    [encryptedSebData appendData:encryptedData];
    
    return encryptedSebData;
}


@end
