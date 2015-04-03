/*
    @file
    @brief The app's program driver.

    @copyright © 2015 Daryle Walker.  All rights reserved.
    @CFBundleIdentifier io.github.ctmacuser.cget
 
    Under the MIT License.
 
    The run-loop structure inspired by the code at <https://gist.github.com/syzdek/3220789>.
 */

@import Foundation;

#include <stdio.h>

#import <GBCli/GBCli.h>


#pragma mark Globals

/// Possible return codes.
typedef NS_ENUM(int, CgReturnCodes) {
    cgr_success,  ///< No problems occurred.
    cgr_no_url,  ///< No URL was given.
    cgr_initialization_fail,  ///< A work object could not be allocated or initialized.
    cgr_downloading_fail,  ///< Downloading of a target URL could not be completed.
    cgr_copying_fail,  ///< A downloaded file could not be moved to the designated directory.
    cgr_metadata_and_url  ///< A "print and exit" option and a URL were both provided.
};

// Long option strings
static NSString * const  cgHelpOptionName = @"help";
static NSString * const  cgVersionOptionName = @"version";

// Settings domains
static NSString * const  cgFactorySettingsName = @"Factory";
static NSString * const  cgCommandLineSettingsName = @"Command Line";

#pragma mark - Support functions

/**
    @brief Copy a (temporary) file to another's volume's item-replacement directory.
    @param sourceTemporaryFile  The source file to move. Should be in a directory for temporary items. Must not be nil.
    @param fileOnDestinationVolume  A sample destination file on the volume to receive the moved file. Must not be nil.
    @param newTemporaryFile  The address to write the URL of the post-moved file. Must not be nil. Valid only if YES is returned, but may be mutated even if NO is returned instead.
    @param error  The address to write the first encountered error. If not interested, pass in nil.
    @return YES if the move was successfully done, NO if an error occurred instead.
    @since 0.2
 
    The file is moved even if the source and destination volumes are the same.
 */
static
BOOL  CgMoveFileToDestinationTemporaryDirectory(NSURL *sourceTemporaryFile, NSURL *fileOnDestinationVolume, NSURL **newTemporaryFile, NSError **error) {
    NSCParameterAssert(sourceTemporaryFile);
    NSCParameterAssert(fileOnDestinationVolume);
    NSCParameterAssert(newTemporaryFile);

    NSFileManager * const  filer = [NSFileManager defaultManager];
    NSURL * const        tempDir = [filer URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:fileOnDestinationVolume create:YES error:error];

    if (!tempDir) {
        return NO;
    }
    *newTemporaryFile = [tempDir URLByAppendingPathComponent:sourceTemporaryFile.lastPathComponent];
    return [filer moveItemAtURL:sourceTemporaryFile toURL:*newTemporaryFile error:error];
}

/**
    @brief Generate a name for a file's backup.
    @param originalFilename  The name of the target file.
    @return A new string with a suitable backup file name.
    @since 0.2

    The file name generated is the original filename with a random string inserted between the name's base and extension. The name component ".old" is added after the random string, both as a general reminder and as an extension if the original file was extension-less.
 */
static
NSString *  CgBackupFilename(NSString *originalFilename) {
    NSCParameterAssert(originalFilename);

    return [[NSString stringWithFormat:@"%@.%@.old", originalFilename.stringByDeletingPathExtension, [NSUUID UUID].UUIDString] stringByAppendingPathExtension:originalFilename.pathExtension];
}

#pragma mark - Program settings

/// Additionally handle program-specific settings
@interface GBSettings (CgSettings)
@property (nonatomic, assign) BOOL printHelp;     ///< Display the help text.
@property (nonatomic, assign) BOOL printVersion;  ///< Display the version information.
@end

@implementation GBSettings (CgSettings)

GB_SYNTHESIZE_BOOL(printHelp, setPrintHelp, cgHelpOptionName)
GB_SYNTHESIZE_BOOL(printVersion, setPrintVersion, cgVersionOptionName)

/// Initialize the default state for properties set in the factory settings domain.
- (void)applyFactoryDefaults {
    self.printHelp = NO;
    self.printVersion = NO;
}

@end

#pragma mark - Main class

/// Handles the main logic of the program
@interface CGetter : NSObject

/// @return A configuration object with the program's settings.
+ (GBSettings *)generateSettings;
/// @return A configuration object with the program's options.
+ (GBOptionsHelper *)generateOptions;

@end

@implementation CGetter

+ (GBSettings *)generateSettings {
    GBSettings * const  factoryDefaults = [GBSettings settingsWithName:cgFactorySettingsName parent:nil];

    NSAssert(factoryDefaults, @"The factory default settings failed to initialize");
    [factoryDefaults applyFactoryDefaults];
    return [GBSettings settingsWithName:cgCommandLineSettingsName parent:factoryDefaults];
}

+ (GBOptionsHelper *)generateOptions {
    GBOptionsHelper * const  options = [GBOptionsHelper new];

    if (options) {
        [options registerOption:'?' long:cgHelpOptionName description:@"Display this help and exit" flags:GBOptionNoValue];
        [options registerOption:0 long:cgVersionOptionName description:@"Display version data and exit" flags:GBOptionNoValue];

        options.printHelpHeader = ^{ return @"Usage: %APPNAME OPTIONS|URL"; };

        options.applicationVersion = ^{ return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]; };
        options.applicationBuild = ^{ return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]; };
    }
    return options;
}

@end

#pragma mark - Main function

int main(int argc, const char * argv[]) {
    __block int  returnCode = cgr_success;

    @autoreleasepool {
        // Process the command-line arguments.
        GBSettings * const         settings = [CGetter generateSettings];
        GBOptionsHelper * const     options = [CGetter generateOptions];
        GBCommandLineParser * const  parser = [GBCommandLineParser new];

        if (!settings || !options || !parser) {
            gbfprintln(stderr, @"Error, initialization: command-line parser");
            returnCode = cgr_initialization_fail;
            goto finish;
        }
        [parser registerSettings:settings];
        [parser registerOptions:options];
        [parser parseOptionsWithArguments:(char **)argv count:argc];

        // Must have a URL or a metadata (version or help text) request, but not both.
        if (argc <= 1) {
            [options printHelp];
            returnCode = cgr_no_url;
            goto finish;
        }
        if (settings.printHelp || settings.printVersion) {
            if (settings.printVersion) {
                [options printVersion];
            }
            if (settings.printHelp) {
                [options printHelp];
            }
            if (parser.arguments.count) {
                returnCode = cgr_metadata_and_url;
            }
            goto finish;
        }

        // Download URLs with NSURLSession, requiring a run loop.
        __block BOOL                shouldExit = NO;
        NSRunLoop * const              runLoop = [NSRunLoop currentRunLoop];
        NSURLSession * const           session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
        NSURLSessionDownloadTask * const  task = [session downloadTaskWithURL:[NSURL URLWithString:parser.arguments.firstObject] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (!error) {
                NSCParameterAssert(location);
                NSCParameterAssert(response);

                NSURL * const  plannedDestination = [NSURL fileURLWithPath:response.suggestedFilename isDirectory:NO];
                NSURL *        stagedLocation = nil;
                NSURL *        actualDestination = nil;
                
                NSCAssert(plannedDestination, @"Creating destination URL failed");
                if (CgMoveFileToDestinationTemporaryDirectory(location, plannedDestination, &stagedLocation, &error) && [[NSFileManager defaultManager] replaceItemAtURL:plannedDestination withItemAtURL:stagedLocation backupItemName:CgBackupFilename(plannedDestination.path.lastPathComponent) options:(NSFileManagerItemReplacementUsingNewMetadataOnly | NSFileManagerItemReplacementWithoutDeletingBackupItem) resultingItemURL:&actualDestination error:&error]) {
                    gbprintln(@"%@", actualDestination.path);
                    // To-do: Is there a way to find out if a backup file was needed and created?
                } else {
                    gbfprintln(stderr, @"Error, copying: %@", error.localizedDescription);
                    returnCode = cgr_copying_fail;
                }
            } else {
                gbfprintln(stderr, @"Error, downloading: %@", error.localizedDescription);
                returnCode = cgr_downloading_fail;
            }
            shouldExit = YES;
        }];

        if (!task) {
            returnCode = cgr_initialization_fail;
            goto finish;
        }
        [task resume];
        while (!shouldExit && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
            ;
    }

finish:
    return returnCode;
}
