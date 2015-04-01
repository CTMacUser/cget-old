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
    cgr_copying_fail  ///< A downloaded file could not be moved to the designated directory.
};

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

#pragma mark - Main function

int main(int argc, const char * argv[]) {
    __block int  returnCode = cgr_success;

    if (argc != 2) {
        gbfprintln(stderr, @"Usage: %s URL", argv[0]);
        returnCode = cgr_no_url;
        goto finish;
    }

    @autoreleasepool {
        __block BOOL                shouldExit = NO;
        NSRunLoop * const              runLoop = [NSRunLoop currentRunLoop];
        NSURLSession * const           session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
        NSURLSessionDownloadTask * const  task = [session downloadTaskWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
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
