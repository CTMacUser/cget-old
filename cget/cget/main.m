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
static NSString * const  cgSuppressHashOptionName = @"suppress-placeholder";

// Settings domains
static NSString * const  cgFactorySettingsName = @"Factory";
static NSString * const  cgCommandLineSettingsName = @"Command Line";

// Download task information dictionary keys
static NSString * const  cgTaskInfoUrlString = @"urlString";        // NSString
static NSString * const  cgTaskInfoResultURL = @"resultURL";        // NSURL, file-reference
static NSString * const  cgTaskInfoResultErr = @"resultErr";        // NSError
static NSString * const  cgTaskInfoMovedFile = @"oldFile";          // NSURL, file-reference
static NSString * const  cgTaskInfoFailDownload = @"failDownload";  // NSNumber, BOOL
static NSString * const  cgTaskInfoFailCopying = @"failCopying";    // NSNumber, BOOL

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
@property (nonatomic, assign) BOOL noPrintHash;   ///< Print nothing, instead of '#', to stdout on failed downloads.
@end

@implementation GBSettings (CgSettings)

GB_SYNTHESIZE_BOOL(printHelp, setPrintHelp, cgHelpOptionName)
GB_SYNTHESIZE_BOOL(printVersion, setPrintVersion, cgVersionOptionName)
GB_SYNTHESIZE_BOOL(noPrintHash, setNoPrintHash, cgSuppressHashOptionName)

/// Initialize the default state for properties set in the factory settings domain.
- (void)applyFactoryDefaults {
    self.printHelp = NO;
    self.printVersion = NO;
    self.noPrintHash = NO;
}

@end

#pragma mark - Main class

/// Handles the main logic of the program
@interface CGetter : NSObject <NSURLSessionDownloadDelegate>

/// @return A configuration object with the program's settings.
+ (GBSettings *)generateSettings;
/// @return A configuration object with the program's options.
+ (GBOptionsHelper *)generateOptions;

/// The task objects to download each submitted URL. Each element is a NSURLSesssionDownloadTask.
@property (nonatomic, readonly) NSArray *                           tasks;
/// The result, file-reference URL or error, and other data for each task. Keys are the elements of `tasks`, values are NSDictionary objects with the various discovered data. See the "cgTaskInfo..." constants for details of the inner pairs.
@property (nonatomic, readonly) NSDictionary *                    results;
/// Changes to YES after all URLs have either been downloaded or erred out.
@property (nonatomic, readonly, assign, getter=isFinished) BOOL  finished;

/**
    @brief Create a URL-downloading object.
    @param urlStrings  An array of URLs to download, each as a `NSString`.
    @param configuration  Configuration data for `session` property.
    @return The created instance.
    @since 0.3

    A session will be created with the given configuration, the returned object as its delegate, and the main thread as its operation queue. Download tasks will be created, with a URL extracted from each given string.
 */
+ (instancetype)createDownloaderFromURLStrings:(NSArray *)urlStrings sessionConfiguration:(NSURLSessionConfiguration *)configuration;
/// Call the `resume` method on the contained tasks.
- (void)resume;

@end

@interface CGetter ()
/// The manager for the download sessions.
@property (nonatomic) NSURLSession *        session;
/// The number of completed tasks.
@property (nonatomic, assign) NSUInteger  doneTasks;
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
        [options registerOption:'h' long:cgHelpOptionName description:@"Display this help and exit" flags:GBOptionNoValue];
        [options registerOption:'V' long:cgVersionOptionName description:@"Display version data and exit" flags:GBOptionNoValue];
        [options registerOption:'#' long:cgSuppressHashOptionName description:@"Prints nothing to standard output, instead of \"#\", when a download fails (Defaults to OFF)" flags:GBOptionNoValue];

        options.printHelpHeader = ^{ return @"Usage: %APPNAME [OPTIONS] [URL...]"; };
        options.printHelpFooter = ^{ return @"\nWhen not printing help and/or version text, at least one URL must be present."; };

        options.applicationVersion = ^{ return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]; };
        options.applicationBuild = ^{ return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]; };
    }
    return options;
}

#pragma mark Properties

- (BOOL)isFinished {
    for (NSURLSessionDownloadTask *task in self.tasks) {
        if (task.state != NSURLSessionTaskStateCompleted) {
            return NO;
        }
    }
    return YES;
}

#pragma mark Initialization and regular methods

/// @return This instance, after initializing containers and such.
- (instancetype)init {
    if (self = [super init]) {
        _tasks = [NSMutableArray new];
        _results = [NSMutableDictionary new];
        _session = nil;
        _doneTasks = 0;

        if (!_tasks || !_results) {
            return nil;
        }
    }
    return self;
}

+ (instancetype)createDownloaderFromURLStrings:(NSArray *)urlStrings
                          sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    CGetter * const      downloader = [self new];
    NSOperationQueue * const  queue = [NSOperationQueue mainQueue];
    id const                   keys = [NSDictionary sharedKeySetForKeys:@[cgTaskInfoUrlString, cgTaskInfoResultURL, cgTaskInfoResultErr, cgTaskInfoMovedFile, cgTaskInfoFailDownload, cgTaskInfoFailCopying]];

    if (!urlStrings || !configuration || !downloader || !queue || !keys) {
        return nil;
    }
    if (!(downloader.session = [NSURLSession sessionWithConfiguration:configuration delegate:downloader delegateQueue:queue])) {
        return nil;
    };
    for (NSString *urlString in urlStrings) {
        NSURL * const                      url = [NSURL URLWithString:urlString];
        NSMutableDictionary * const  taskBlock = [NSMutableDictionary dictionaryWithSharedKeySet:keys];

        if (!url || !taskBlock) {
            return nil;
        }
        [taskBlock setObject:urlString forKey:cgTaskInfoUrlString];
        [(NSMutableArray *)downloader.tasks addObject:[downloader.session downloadTaskWithURL:url]];
        [(NSMutableDictionary *)downloader.results setObject:taskBlock forKey:downloader.tasks.lastObject];
    }
    return downloader;
}

- (void)resume {
    for (NSURLSessionDownloadTask *task in self.tasks) {
        [task resume];
    }
}

#pragma mark Delegate methods

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
                              didFinishDownloadingToURL:(NSURL *)location {
    NSAssert(session == self.session, @"Given session (%@) isn't the one (%@) owned by this object (%@)", session, self.session, self);
    NSAssert([self.tasks containsObject:downloadTask], @"Given task (%@) isn't one owned by this object (%@)", downloadTask, self);

    NSMutableDictionary * const  taskBlock = self.results[downloadTask];
    NSURL * const       plannedDestination = [NSURL fileURLWithPath:downloadTask.response.suggestedFilename isDirectory:NO];
    NSURL *             stagedLocation = nil;
    NSError *           error = nil;

    NSAssert(plannedDestination, @"Creating destination URL failed");
    if (CgMoveFileToDestinationTemporaryDirectory(location, plannedDestination, &stagedLocation, &error)) {
        NSURL * const     locationReference = [stagedLocation fileReferenceURL];
        NSString * const  backupName = CgBackupFilename(plannedDestination.path.lastPathComponent);
        NSURL *           actualDestination = nil;

        NSAssert(locationReference, @"Creating file-reference URL to downloaded file failed");
        if ([[NSFileManager defaultManager] replaceItemAtURL:plannedDestination withItemAtURL:stagedLocation backupItemName:backupName options:(NSFileManagerItemReplacementUsingNewMetadataOnly | NSFileManagerItemReplacementWithoutDeletingBackupItem) resultingItemURL:&actualDestination error:&error]) {
            NSURL * const  oldBackupFile = [actualDestination fileReferenceURL];

            taskBlock[cgTaskInfoResultURL] = locationReference;
            if (oldBackupFile) {
                taskBlock[cgTaskInfoMovedFile] = oldBackupFile;  // No use for this yet.
            }
            return;
        }
    }

    taskBlock[cgTaskInfoResultErr] = error;
    taskBlock[cgTaskInfoFailCopying] = @YES;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
                           didCompleteWithError:(NSError *)error {
    NSAssert(session == self.session, @"Given session (%@) isn't the one (%@) owned by this object (%@)", session, self.session, self);
    NSAssert([self.tasks containsObject:task], @"Given task (%@) isn't one owned by this object (%@)", task, self);

    if (error) {
        NSMutableDictionary * const  taskBlock = self.results[task];

        taskBlock[cgTaskInfoResultErr] = error;
        taskBlock[cgTaskInfoFailDownload] = @YES;
    }
    if (++self.doneTasks >= self.tasks.count) {
        [self.session performSelector:@selector(finishTasksAndInvalidate) withObject:nil afterDelay:0.0];
    }
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
        CGetter * const  downloader = [CGetter createDownloaderFromURLStrings:parser.arguments sessionConfiguration:configuration];

        if (!runLoop || !downloader) {
            gbfprintln(stderr, @"Error, initialization: run loop or action object");
            returnCode = cgReturnInitializationFail;
            goto finish;
        }
        [downloader resume];
        while (!downloader.finished && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
            ;

        // Handle the result
        NSUInteger  errDownload = 0, errCopy = 0, errOther = 0;

        for (NSURLSessionDownloadTask *task in downloader.tasks) {
            NSDictionary * const  result = downloader.results[task];
            NSURL * const            url = result[cgTaskInfoResultURL];
            NSError * const        error = result[cgTaskInfoResultErr];
            BOOL const  failedAtDownload = [(NSNumber *)result[cgTaskInfoFailDownload] boolValue];
            BOOL const   failedAtCopying = [(NSNumber *)result[cgTaskInfoFailCopying] boolValue];

            if (url) {
                gbprintln(@"%@", url.filePathURL.path);
            } else {
                if (!settings.noPrintHash) {
                    // When matching to each input URL, and a URL fails to download, this replaces the output file path.
                    gbprintln(@"#");
                }

                if (error) {
                    if (failedAtDownload) {
                        gbfprintln(stderr, @"Error, downloading: %@", error.localizedDescription);
                        ++errDownload;
                    } else if (failedAtCopying) {
                        gbfprintln(stderr, @"Error, copying: %@", error.localizedDescription);
                        ++errCopy;
                    } else {
                        gbfprintln(stderr, @"Error: %@", error.localizedDescription);
                        ++errOther;
                    }
                } else {
                    gbfprintln(stderr, @"Error, unknown");
                    ++errOther;
                }
            }
        }
        returnCode = errDownload ? cgReturnDownloadingFail : errCopy ? cgReturnCopyingFail : errOther ? cgReturnUnknownFail : cgReturnSuccess;
    }

finish:
    return returnCode;
}
