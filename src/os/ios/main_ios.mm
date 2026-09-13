/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/**
 * @file main_ios.mm Main entry for iOS and the UIKit application glue.
 *
 * The UIKit runtime requires all UI work on its main thread, while OpenTTD's
 * whole simulation runs on its own dedicated thread. This file creates the
 * application window, provides the host view the video driver attaches its
 * OpenGL ES layer to, and forwards lifecycle events to the video driver.
 */

#include "../../stdafx.h"
#include "../../openttd.h"
#include "../../crashlog.h"
#include "../../core/random_func.hpp"
#include "../../string_func.h"

#include <time.h>
#include <signal.h>

#import <UIKit/UIKit.h>
#import <os/log.h>

#include "ios_main.h"
#include "ios.h"

#include "../../safeguards.h"

/**
 * Route OpenTTD's stdout/stderr (the game logs) into a file in the app's
 * Documents directory so it can be retrieved from the Files app without a
 * Mac. Unbuffered so nothing is lost on a crash.
 */
static void RedirectLogToFile()
{
	std::string dir = IosGetDocumentsDir();
	if (dir.empty()) return;

	std::string path = dir + "openttd.log";
	if (freopen(path.c_str(), "w", stderr) != nullptr) {
		setvbuf(stderr, nullptr, _IONBF, 0);
	}
	if (freopen(path.c_str(), "a", stdout) != nullptr) {
		setvbuf(stdout, nullptr, _IONBF, 0);
	}
	std::string msg = "OpenTTD iOS: logging to " + path + "\n";
	fwrite(msg.data(), 1, msg.size(), stderr);
}

/**
 * Convert an Objective-C string to a C++ one.
 * @param str The string to convert.
 * @return The converted string.
 */
std::string NSStringToCpp(NSString *str)
{
	if (str == nil) return {};
	return std::string{ [ str UTF8String ] };
}

/**
 * Host view for the OpenGL ES layer. Reports size changes (rotation, iPad
 * multitasking) to the video driver so it can resize the backing store.
 */
@interface OpenTTDHostView : UIView
@end

@implementation OpenTTDHostView

- (void)layoutSubviews
{
	[ super layoutSubviews ];

	/* The window covers the whole screen on iOS, but report size changes
	 * (e.g. rotation) to the video driver so it can resize the backing store. */
	IosNotifyHostViewSizeChanged(self.bounds.size.width, self.bounds.size.height);
}

@end

/**
 * The main application object. Sets up the window and starts the game thread.
 */
@interface OpenTTDAppDelegate : NSObject <UIApplicationDelegate>
@property(nonatomic, retain) UIWindow *window;
@end

@implementation OpenTTDAppDelegate

@synthesize window = _window;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	os_log(OS_LOG_DEFAULT, "OpenTTD iOS: application did finish launching");
	CGRect screenBounds = [ [ UIScreen mainScreen ] bounds ];
	self.window = [ [ UIWindow alloc ] initWithFrame:screenBounds ];
	self.window.backgroundColor = [ UIColor blackColor ];

	UIViewController *rootController = [ [ UIViewController alloc ] init ];
	self.window.rootViewController = rootController;
	[ rootController release ];

	OpenTTDHostView *hostView = [ [ OpenTTDHostView alloc ] initWithFrame:screenBounds ];
	hostView.multipleTouchEnabled = YES;
	hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[ rootController.view addSubview:hostView ];
	IosSetHostView(hostView);

	[ self.window makeKeyAndVisible ];

	[ self startGameThread ];

	return YES;
}

- (void)startGameThread
{
	NSThread *thread = [ [ NSThread alloc ] initWithBlock:^{
		@autoreleasepool {
			os_log(OS_LOG_DEFAULT, "OpenTTD iOS: game thread starting");
			RedirectLogToFile();

			CrashLog::InitialiseCrashLog();
			fwrite("OpenTTD iOS: crash log handlers installed\n", 1, 42, stderr);
			fflush(stderr);

			SetRandomSeed(time(nullptr));

			signal(SIGPIPE, SIG_IGN);

			/* iOS has no traditional argv, so construct one. The (read-only)
			 * application bundle path is used as the program name; the actual
			 * game data is picked up from the bundle Data directory.
			 * Verbose driver/misc debug is enabled so every startup step is
			 * visible in openttd.log on first launch. */
			std::vector<std::string> args;
			args.emplace_back(NSStringToCpp([ [ NSBundle mainBundle ] bundlePath ]));
			args.emplace_back("-d");
			args.emplace_back("driver=3,misc=2");

			std::vector<std::string_view> params;
			for (const auto &arg : args) params.emplace_back(arg);

			fwrite("OpenTTD iOS: calling openttd_main\n", 1, 34, stderr);
			fflush(stderr);
			os_log(OS_LOG_DEFAULT, "OpenTTD iOS: calling openttd_main");
			int ret = openttd_main(std::span<std::string_view>{ params });

			fwrite("OpenTTD iOS: openttd_main returned\n", 1, 34, stderr);
			fflush(stderr);
			os_log(OS_LOG_DEFAULT, "OpenTTD iOS: openttd_main returned %d", ret);

			/* The game has shut down; leaving is all we can do. */
			exit(ret);
		}
	} ];
	thread.stackSize = 8 * 1024 * 1024;
	thread.name = @"openttd";
	[ thread start ];
	[ thread release ];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	IosVideoPause();
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
	IosVideoResume();
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
	return UIInterfaceOrientationMaskLandscape;
}

@end

int CDECL main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([ OpenTTDAppDelegate class ]));
	}
}