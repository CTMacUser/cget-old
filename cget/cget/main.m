/*
    @file
    @brief The app's program driver.

    @copyright © 2015 Daryle Walker.  All rights reserved.
    @CFBundleIdentifier io.github.ctmacuser.cget
 
    Under the MIT License.
 
    The run-loop structure inspired by the code at <https://gist.github.com/syzdek/3220789>.
 */

@import Foundation;

#include <stdbool.h>
#include <stdlib.h>


#pragma mark Globals

int   returnCode = EXIT_SUCCESS;
bool  shouldExit = false;

#pragma mark - Main function

int main(int argc, const char * argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s URL\n", argv[0]);
        returnCode = EXIT_FAILURE;
        goto finish;
    }

    @autoreleasepool {
        NSRunLoop * const              runLoop = [NSRunLoop currentRunLoop];
        NSURLSession * const           session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
        NSURLSessionDownloadTask * const  task = [session downloadTaskWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                fprintf(stderr, "Error, downloading: %s\n", error.localizedFailureReason.UTF8String ?: error.localizedDescription.UTF8String);
                returnCode = EXIT_FAILURE;
            } else {
                NSURL * const  finalLocation = [NSURL fileURLWithPath:response.suggestedFilename isDirectory:NO];

                [[NSFileManager defaultManager] moveItemAtURL:location toURL:finalLocation error:&error];
                if (error) {
                    fprintf(stderr, "Error, copying: %s\n", error.localizedFailureReason.UTF8String ?: error.localizedDescription.UTF8String);
                    returnCode = EXIT_FAILURE;
                } else {
                    fprintf(stdout, "%s\n", finalLocation.path.UTF8String);
                }
            }
            shouldExit = true;
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
