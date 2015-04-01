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
#include <stdlib.h>

#import <GBCli/GBCli.h>


#pragma mark Globals

int   returnCode = EXIT_SUCCESS;
BOOL  shouldExit = NO;

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
    if (argc != 2) {
        gbfprintln(stderr, @"Usage: %s URL", argv[0]);
        returnCode = EXIT_FAILURE;
        goto finish;
    }

    @autoreleasepool {
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
                    returnCode = EXIT_FAILURE;
                    gbfprintln(stderr, @"Error, copying: %@", error.localizedDescription);
                }
            } else {
                returnCode = EXIT_FAILURE;
                gbfprintln(stderr, @"Error, downloading: %@", error.localizedDescription);
            }
            shouldExit = YES;
        }];

        if (!task) {
            returnCode = EXIT_FAILURE;
            goto finish;
        }
        [task resume];
        while (!shouldExit && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
            ;
    }

finish:
    return returnCode;
}
