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

static
BOOL  CgMoveFileToDestinationTemporaryDirectory(NSURL *sourceTemporaryFile, NSURL *fileOnDestinationVolume, NSURL **newTemporaryFile, NSError **error) {
    NSCParameterAssert(sourceTemporaryFile);
    NSCParameterAssert(fileOnDestinationVolume);
    NSCParameterAssert(newTemporaryFile);

    // Don't move if the source and destination files use the same volume.
    id  sourceVolume = nil, destinationVolume = nil;

    if ([sourceTemporaryFile getResourceValue:&sourceVolume forKey:NSURLVolumeIdentifierKey error:error] && [fileOnDestinationVolume getResourceValue:&destinationVolume forKey:NSURLVolumeIdentifierKey error:error]) {
        if ([sourceVolume isEqual:destinationVolume]) {
            *newTemporaryFile = sourceTemporaryFile;
            return YES;
        }
        // Else: move the source file across volumes, see below.
    } else {
        return NO;
    }

    // Move the source file to the destination file's volume's temporary directory.
    NSFileManager * const  filer = [NSFileManager defaultManager];
    NSURL * const        tempDir = [filer URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:fileOnDestinationVolume create:YES error:error];

    if (!tempDir) {
        return NO;
    }
    *newTemporaryFile = [tempDir URLByAppendingPathComponent:sourceTemporaryFile.lastPathComponent];
    return [filer moveItemAtURL:sourceTemporaryFile toURL:*newTemporaryFile error:error];
}

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
