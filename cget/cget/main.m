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
    cgReturnMetadataAndURL,  ///< A "print and exit" option and a URL were both provided.
    cgReturnBadInputFile,  ///< An input file (holding URLs) could not be opened.
    cgReturnBadInputRead,  ///< An input file (holding URLs) was found but could not be read.
    cgReturnDirectoryFail  ///< An output directory could not be created.
};

// Long option strings
static NSString * const  cgHelpOptionName = @"help";
static NSString * const  cgVersionOptionName = @"version";
static NSString * const  cgSuppressHashOptionName = @"suppress-placeholder";
static NSString * const  cgInputFileOptionName = @"input-file";
static NSString * const  cgOptionNameOutputDocument = @"output-document";
static NSString * const  cgOptionNameOutputAs = @"output-as";

// "Option-as" values
static NSString * const  cgOptionValueFile = @"file";
static NSString * const  cgOptionValueFolder = @"folder";
static NSString * const  cgOptionValueDirectory = @"directory";

// Settings domains
static NSString * const  cgFactorySettingsName = @"Factory";
static NSString * const  cgCommandLineSettingsName = @"Command Line";

// Download task information dictionary keys
static NSString * const  cgTaskInfoUrl = @"url";                    // NSURL
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

@property (nonatomic, copy) id          urlInputFile;     ///< File (path as NSString), or stdin (NSNumber BOOL YES), to read URLs from.
@property (nonatomic, copy) NSString *  destinationName;  ///< File path (or simple name in current directory) for the downloaded file, overriding the default name. Will be directory when multiple URLs are downloaded.
@property (nonatomic, copy) NSString *  useFileOrFolder;  ///< "file," "folder," or "directory": when `destinationName` is not NIL, force it to name either a file or directory, instead of the default of using single vs. multiple URLs.
@end

@implementation GBSettings (CgSettings)

GB_SYNTHESIZE_BOOL(printHelp, setPrintHelp, cgHelpOptionName)
GB_SYNTHESIZE_BOOL(printVersion, setPrintVersion, cgVersionOptionName)
GB_SYNTHESIZE_BOOL(noPrintHash, setNoPrintHash, cgSuppressHashOptionName)
GB_SYNTHESIZE_COPY(id, urlInputFile, setUrlInputFile, cgInputFileOptionName)
GB_SYNTHESIZE_COPY(NSString *, destinationName, setDestinationName, cgOptionNameOutputDocument)
GB_SYNTHESIZE_COPY(NSString *, useFileOrFolder, setUseFileOrFolder, cgOptionNameOutputAs)

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

/// When not `nil`, the downloaded file's name, overriding the default filename.
@property (nonatomic, copy) NSString *  destinationFilename;

/**
    @brief Create a URL-downloading object.
    @param urls  An array of URLs to download, each as a `NSURL`.
    @param configuration  Configuration data for `session` property.
    @return The created instance.
    @since 0.3

    A session will be created with the given configuration, the returned object as its delegate, and the main thread as its operation queue. Download tasks will be created, one for each given URL.
 */
+ (instancetype)createDownloaderFromURLs:(NSArray *)urls sessionConfiguration:(NSURLSessionConfiguration *)configuration;
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
        [options registerSeparator:@"Basic Startup Options"];
        [options registerOption:'h' long:cgHelpOptionName description:@"Display this help and exit" flags:GBOptionNoValue];
        [options registerOption:'V' long:cgVersionOptionName description:@"Display version data and exit" flags:GBOptionNoValue];
        [options registerSeparator:@"Logging and Input File Options"];
        [options registerOption:'#' long:cgSuppressHashOptionName description:@"Prints nothing to standard output, instead of \"#\", when a download fails (Defaults to OFF)" flags:GBOptionNoValue];
        [options registerOption:'i' long:cgInputFileOptionName description:@"Download the additional URLs listed in the given file, or standard input if the file path is omitted (Defaults to no additional reading)" flags:GBOptionOptionalValue];
        [options registerSeparator:@"Download Options"];
        [options registerOption:'O' long:cgOptionNameOutputDocument description:@"Use the given name or path as the destination file (with one URL) or directory (with multiple URLs) for the downloaded file(s)" flags:GBOptionRequiredValue];
        [options registerOption:0 long:cgOptionNameOutputAs description:@"When using the output document option, use 'file' to force the document path to be a file, and 'directory' or 'folder' to make it a directory (Defaults to using the number of URLs)" flags:GBOptionRequiredValue];

        options.printHelpHeader = ^{ return @"Usage: %APPNAME [OPTIONS] [URL...]"; };
        options.printHelpFooter = ^{ return @"\nWhen not printing help and/or version text, at least one URL should be submitted as an argument and/or any number though an input file (or standard input)."; };

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
        _destinationFilename = nil;
        _session = nil;
        _doneTasks = 0;

        if (!_tasks || !_results) {
            return nil;
        }
    }
    return self;
}

+ (instancetype)createDownloaderFromURLs:(NSArray *)urls
                    sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    NSParameterAssert(urls);
    NSParameterAssert(configuration);

    CGetter * const  downloader = [self new];
    id const         keys = [NSDictionary sharedKeySetForKeys:@[cgTaskInfoUrl, cgTaskInfoResultURL, cgTaskInfoResultErr, cgTaskInfoMovedFile, cgTaskInfoFailDownload, cgTaskInfoFailCopying]];

    downloader.session = [NSURLSession sessionWithConfiguration:configuration
                                                       delegate:downloader
                                                  delegateQueue:[NSOperationQueue mainQueue]];
    for (NSURL *url in urls) {
        NSMutableDictionary * const  taskBlock = [NSMutableDictionary dictionaryWithSharedKeySet:keys];

        [taskBlock setObject:url forKey:cgTaskInfoUrl];
        [(NSMutableArray *)downloader.tasks addObject:[downloader.session downloadTaskWithURL:url]];
        [(NSMutableDictionary *)downloader.results setObject:taskBlock forKey:downloader.tasks.lastObject];
    }
    if (!downloader.tasks.count) {
        // No tasks -> no way to finish a session (after the last task) -> kill the session early
        downloader.session = nil;
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
    NSURL * const       plannedDestination = [NSURL fileURLWithPath:(self.destinationFilename ?: downloadTask.response.suggestedFilename) isDirectory:NO];
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

        // Print version information and/or help text. Cannot also have a URL request.
        if (argc <= 1) {
            // Since the help print-out goes to stdout, we must return a non-success code so a script can check it and make sure not to interpret the text as the normal output (a list of file paths of the downloads). To safely submit a list of URLs that may be empty, use the input-file option.
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
            if (parser.arguments.count || settings.urlInputFile) {
                returnCode = cgReturnMetadataAndURL;
            }
            goto finish;
        }

        // Check for a file to read URLs from. Can be standard-input instead.
        NSFileHandle *  inputFile = nil;

        if ([settings.urlInputFile isKindOfClass:[NSString class]]) {
            NSString * const  inputFilePathString = settings.urlInputFile;
            NSError *         error = nil;

            inputFile = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:inputFilePathString.stringByExpandingTildeInPath] error:&error];
            if (!inputFile) {
                gbfprintln(stderr, @"Error, checking for input file: %@", error.localizedDescription);
                returnCode = cgReturnBadInputFile;
                goto finish;
            }
        } else if ([settings.urlInputFile isKindOfClass:[NSNumber class]]) {
            NSCAssert([settings.urlInputFile boolValue], @"Should have gotten @YES");
            inputFile = [NSFileHandle fileHandleWithStandardInput];
        }

        // Now scan the arguments and input for any URLs.
        NSMutableArray * const  inputFileURLs = [NSMutableArray arrayWithCapacity:parser.arguments.count];

        for (NSString *argument in parser.arguments) {
            [inputFileURLs addObject:[NSURL URLWithString:argument]];
        }
        if (inputFile) {
            NSString * const     inputFileString = [[NSString alloc] initWithData:[inputFile readDataToEndOfFile]
                                                                         encoding:NSUTF8StringEncoding];
            NSError *               error = inputFileString ? nil : [NSError errorWithDomain:NSCocoaErrorDomain
                                                                                        code:NSFileReadUnknownError
                                                                                    userInfo:nil];
            NSDataDetector * const  linkDetector = error ? nil : [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink
                                                                                                 error:&error];

            if (error) {
                gbfprintln(stderr, [NSString stringWithFormat:@"Error, reading %@:%%@", inputFile == [NSFileHandle fileHandleWithStandardInput] ? @"standard input" : @"input file"], error.localizedDescription);
                returnCode = cgReturnBadInputRead;
                goto finish;
            }
            [linkDetector enumerateMatchesInString:inputFileString
                                           options:kNilOptions
                                             range:NSMakeRange(0, inputFileString.length)
                                        usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                switch (result.resultType) {
                    case NSTextCheckingTypeLink:
                        [inputFileURLs addObject:result.URL];
                    default:
                        break;
                }
            }];
        }

        // Change working directory for filename (or directory) override.
        BOOL const  useOverrideAsFile = settings.useFileOrFolder && [cgOptionValueFile caseInsensitiveCompare:settings.useFileOrFolder] == NSOrderedSame;
        BOOL const  useOverrideAsFolder = settings.useFileOrFolder && ([cgOptionValueFolder caseInsensitiveCompare:settings.useFileOrFolder] == NSOrderedSame || [cgOptionValueDirectory caseInsensitiveCompare:settings.useFileOrFolder] == NSOrderedSame);
        BOOL const  useAsDirectory = useOverrideAsFile ? NO : useOverrideAsFolder ? YES : inputFileURLs.count > 1;
        NSURL *   filenameOverride = settings.destinationName ? [NSURL fileURLWithPath:settings.destinationName.stringByExpandingTildeInPath isDirectory:useAsDirectory] : nil;

        if (filenameOverride) {
            NSError *      error = nil;
            NSURL * const  workingDirectory = useAsDirectory ? filenameOverride : filenameOverride.URLByDeletingLastPathComponent;
            NSFileManager * const   manager = [NSFileManager defaultManager];

            if ([manager createDirectoryAtURL:workingDirectory withIntermediateDirectories:YES attributes:nil error:&error]) {
                if (![manager changeCurrentDirectoryPath:workingDirectory.path]) {
                    gbfprintln(stderr, @"Error, changing working directory failed");
                    returnCode = cgReturnDirectoryFail;
                    goto finish;
                }
            } else {
                gbfprintln(stderr, @"Error, creating destination directory failed: %@", error.localizedDescription);
                returnCode = cgReturnDirectoryFail;
                goto finish;
            }
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
        CGetter * const  downloader = [CGetter createDownloaderFromURLs:inputFileURLs sessionConfiguration:configuration];

        if (!runLoop || !downloader) {
            gbfprintln(stderr, @"Error, initialization: run loop or action object");
            returnCode = cgReturnInitializationFail;
            goto finish;
        }
        if (!useAsDirectory) {
            downloader.destinationFilename = filenameOverride.lastPathComponent;
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
