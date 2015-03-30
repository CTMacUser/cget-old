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
            if (error) {
                gbfprint(stderr, @"Error, downloading: %@", error.localizedDescription);
                gbfprintln(stderr, error.localizedFailureReason ? @" (%@)" : @"", error.localizedFailureReason);
                returnCode = EXIT_FAILURE;
            } else {
                NSURL * const  finalLocation = [NSURL fileURLWithPath:response.suggestedFilename isDirectory:NO];

                [[NSFileManager defaultManager] moveItemAtURL:location toURL:finalLocation error:&error];
                if (error) {
                    gbfprint(stderr, @"Error, copying: %@", error.localizedDescription);
                    gbfprintln(stderr, error.localizedFailureReason ? @" (%@)" : @"", error.localizedFailureReason);
                    returnCode = EXIT_FAILURE;
                } else {
                    gbprintln(@"%@", finalLocation.path);
                }
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
