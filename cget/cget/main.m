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
    cgReturnUnknownFail = -1, ///< Unknown problem occurred.
    cgReturnSuccess,  ///< No problems occurred.
    cgReturnNoURL,  ///< No URL was given.
    cgReturnInitializationFail,  ///< A work object could not be allocated or initialized.
    cgReturnDownloadingFail,  ///< Downloading of a target URL could not be completed.
    cgReturnCopyingFail,  ///< A downloaded file could not be moved to the designated directory.
    cgReturnMetadataAndURL  ///< A "print and exit" option and a URL were both provided.
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
@interface CGetter : NSObject <NSURLSessionDownloadDelegate>

/// @return A configuration object with the program's settings.
+ (GBSettings *)generateSettings;
/// @return A configuration object with the program's options.
+ (GBOptionsHelper *)generateOptions;

/// The result, file-reference URL or error, of the download task.
@property (nonatomic, readonly) id  result;
/// Changes to YES after the URL has either been downloaded or erred out.
@property (nonatomic, assign, getter=isFinished) BOOL  finished;
/// Set if the task failed, and did so during the file-downloading phase.
@property (nonatomic, assign, readonly) BOOL  failedDuringDownload;
/// Set if the task failed, and did so during the file-copying phase.
@property (nonatomic, assign, readonly) BOOL  failedDuringCopying;

/**
    @brief Create a URL-downloading object.
    @param urlString  The URL to download, in string form.
    @param configuration  Configuration data for the `session` property.
    @return The created instance.
    @since 0.2

    A session will be created with the given configuration, the returned object as the delegate, and the main thread as the operation queue. A download task will be created with the URL contained in the given string.
 */
+ (instancetype)createDownloaderFromURLString:(NSString *)urlString sessionConfiguration:(NSURLSessionConfiguration *)configuration;
/// Call the `resume` method on the contained task.
- (void)resume;

@end

@interface CGetter ()
@property (nonatomic, readwrite) id  result;
@property (nonatomic, assign, readwrite) BOOL  failedDuringDownload;
@property (nonatomic, assign, readwrite) BOOL  failedDuringCopying;

/// The manager for the download sessions.
@property (nonatomic) NSURLSession *  session;
/// Downloads the desired URL.
@property (nonatomic) NSURLSessionDownloadTask *  task;
@end

@implementation CGetter

#pragma mark Command-line processing

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

#pragma mark Properties

- (BOOL)isFinished {
    return self.result != nil;
}

#pragma mark Initialization and regular methods

+ (instancetype)createDownloaderFromURLString:(NSString *)urlString
                         sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    NSURL * const               url = [NSURL URLWithString:urlString];  // Implied NIL check on urlString
    CGetter * const      downloader = [self new];
    NSOperationQueue * const  queue = [NSOperationQueue mainQueue];

    if (configuration && url && downloader && queue) {
        if ((downloader.session = [NSURLSession sessionWithConfiguration:configuration delegate:downloader delegateQueue:queue])) {
            if ((downloader.task = [downloader.session downloadTaskWithURL:url])) {
                return downloader;
            }
        }
    }
    return nil;
}

- (void)resume {
    [self.task resume];
}

#pragma mark Delegate methods

- (void)        URLSession:(NSURLSession *)session
              downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {
    NSAssert(session == self.session, @"Given session (%@) isn't the one (%@) owned by this object (%@)", session, self.session, self);
    NSAssert(downloadTask == self.task, @"Given task (%@) isn't the one (%@) owned by this object (%@)", downloadTask, self.task, self);

    NSURL * const  plannedDestination = [NSURL fileURLWithPath:downloadTask.response.suggestedFilename isDirectory:NO];
    NSURL *        stagedLocation = nil;
    NSError *      error = nil;

    NSAssert(plannedDestination, @"Creating destination URL failed");
    if (CgMoveFileToDestinationTemporaryDirectory(location, plannedDestination, &stagedLocation, &error)) {
        NSURL * const     locationReference = [stagedLocation fileReferenceURL];
        NSString * const  backupName = CgBackupFilename(plannedDestination.path.lastPathComponent);
        NSURL *           actualDestination = nil;

        NSAssert(locationReference, @"Creating file-reference URL to downloaded file failed");
        if ([[NSFileManager defaultManager] replaceItemAtURL:plannedDestination withItemAtURL:stagedLocation backupItemName:backupName options:(NSFileManagerItemReplacementUsingNewMetadataOnly | NSFileManagerItemReplacementWithoutDeletingBackupItem) resultingItemURL:&actualDestination error:&error]) {
            self.result = locationReference;

            // Discovered that [actualDestination fileReferenceURL] returns a pointer to the backed-up file!
            // Maybe that can be used to flag moved around files.
            return;
        }
    }
    self.result = error;
    self.failedDuringCopying = YES;
}

- (void)   URLSession:(NSURLSession *)session
                 task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error {
    NSAssert(session == self.session, @"Given session (%@) isn't the one (%@) owned by this object (%@)", session, self.session, self);
    NSAssert(task == (NSURLSessionTask *)self.task, @"Given task (%@) isn't the one (%@) owned by this object (%@)", task, self.task, self);

    self.result = error;
    self.failedDuringDownload = YES;
}

@end

#pragma mark - Main function

int main(int argc, const char * argv[]) {
    int  returnCode = cgReturnSuccess;

    @autoreleasepool {
        // Process the command-line arguments.
        GBSettings * const         settings = [CGetter generateSettings];
        GBOptionsHelper * const     options = [CGetter generateOptions];
        GBCommandLineParser * const  parser = [GBCommandLineParser new];

        if (!settings || !options || !parser) {
            gbfprintln(stderr, @"Error, initialization: command-line parser");
            returnCode = cgReturnInitializationFail;
            goto finish;
        }
        [parser registerSettings:settings];
        [parser registerOptions:options];
        [parser parseOptionsWithArguments:(char **)argv count:argc];

        // Must have a URL or a metadata (version or help text) request, but not both.
        if (argc <= 1) {
            [options printHelp];
            returnCode = cgReturnNoURL;
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
                returnCode = cgReturnMetadataAndURL;
            }
            goto finish;
        }

        // Set up the session with configuration data. (None for now.)
        NSURLSessionConfiguration * const  configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];

        if (!configuration) {
            gbfprintln(stderr, @"Error, initialization: session configuration");
            returnCode = cgReturnInitializationFail;
            goto finish;
        }

        // Download URLs with NSURLSession, requiring a run loop.
        NSRunLoop * const   runLoop = [NSRunLoop currentRunLoop];
        CGetter * const  downloader = [CGetter createDownloaderFromURLString:parser.arguments.firstObject sessionConfiguration:configuration];

        if (!runLoop || !downloader) {
            gbfprintln(stderr, @"Error, initialization: run loop or action object");
            returnCode = cgReturnInitializationFail;
            goto finish;
        }
        [downloader resume];
        while (!downloader.finished && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
            ;

        // Handle the result
        if ([downloader.result isKindOfClass:[NSURL class]]) {
            NSURL * const  url = downloader.result;

            gbprintln(@"%@", url.filePathURL.path);
        } else if ([downloader.result isKindOfClass:[NSError class]]) {
            NSError * const  error = downloader.result;

            if (downloader.failedDuringDownload) {
                gbfprintln(stderr, @"Error, downloading: %@", error.localizedDescription);
                returnCode = cgReturnDownloadingFail;
            } else if (downloader.failedDuringCopying) {
                gbfprintln(stderr, @"Error, copying: %@", error.localizedDescription);
                returnCode = cgReturnCopyingFail;
            } else {
                gbfprintln(stderr, @"Error: %@", error.localizedDescription);
                returnCode = cgReturnUnknownFail;
            }
        } else {
            gbfprintln(stderr, @"Error, unknown");
            returnCode = cgReturnUnknownFail;
        }
    }

finish:
    return returnCode;
}
