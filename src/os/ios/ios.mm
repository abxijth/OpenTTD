/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/**
 * @file ios.mm iOS OS layer.
 *
 * This file contains Objective-C++ code that bridges OpenTTD's core with the
 * UIKit based runtime of iOS. It provides sandbox-aware paths, error dialogs,
 * clipboard access, locale lookup and a few small OS utilities.
 */

#include "../../stdafx.h"
#include "../../core/bitmath_func.hpp"
#include "../../rev.h"
#include "../../string_func.h"
#include "../../fileio_func.h"
#include "../../3rdparty/fmt/format.h"
#include "ios.h"
#include <pthread.h>
#include <UIKit/UIKit.h>

/**
 * Show a modal alert. As OpenTTD's game thread is not the main thread, the
 * dialog is created and presented on the main thread.
 * @param title   The title of the dialog.
 * @param message The message in the dialog.
 * @param button_label The label of the (single) button.
 */
void IosShowErrorDialog(std::string_view title, std::string_view message, std::string_view button_label)
{
	NSString *ns_title = [ NSString stringWithUTF8String:std::string(title).c_str() ];
	NSString *ns_message = [ NSString stringWithUTF8String:std::string(message).c_str() ];
	NSString *ns_button = [ NSString stringWithUTF8String:std::string(button_label).c_str() ];

	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindow *window = [[[ UIApplication sharedApplication ] windows ] firstObject ];
		UIViewController *root = window != nil ? [ window rootViewController ] : nil;

		UIAlertController *alert = [ UIAlertController alertControllerWithTitle:ns_title message:ns_message preferredStyle:UIAlertControllerStyleAlert ];
		[ alert addAction:[ UIAlertAction actionWithTitle:ns_button style:UIAlertActionStyleDefault handler:nil ] ];

		if (root != nil) {
			[ root presentViewController:alert animated:YES completion:nil ];
		} else {
			fmt::print(stderr, "{}: {}\n", std::string(title), std::string(message));
		}
	});
}

/**
 * Show the system dialogue message, uses an iOS alert if possible, console otherwise.
 * @param title Window title.
 * @param message Message text.
 * @param buttonLabel Button text.
 */
void ShowMacDialog(std::string_view title, std::string_view message, std::string_view buttonLabel)
{
	IosShowErrorDialog(title, message, buttonLabel);
}

/**
 * Show an error message.
 * @param buf Text with error message.
 * @param system Whether message text originates from OS.
 */
void ShowOSErrorBox(std::string_view buf, bool system)
{
	/* Display the error in the best way possible. */
	if (system) {
		ShowMacDialog("OpenTTD has encountered an error", buf, "Quit");
	} else {
		ShowMacDialog(buf, "See the readme for more info.", "Quit");
	}
}

/**
 * Opens the given URL in the default browser (Safari on iOS).
 * @param url Web page address to open.
 */
void OSOpenBrowser(const std::string &url)
{
	NSURL *ns_url = [ NSURL URLWithString:[ NSString stringWithUTF8String:url.c_str() ] ];
	UIApplication *app = [ UIApplication sharedApplication ];
	if (app != nil && ns_url != nil) {
		if ([ app respondsToSelector:@selector(openURL:options:completionHandler:) ]) {
			[ app openURL:ns_url options:@{ UIApplicationOpenURLOptionsExternalApplicationKey : @YES } completionHandler:nil ];
		} else {
			[ app openURL:ns_url ];
		}
	}
}

/**
 * Determine and return the current user's preferred language.
 * @return String containing the current locale, or std::nullopt if not-determinable.
 */
std::optional<std::string> GetCurrentLocale(const char *)
{
	NSString *preferredLang = [ [ NSLocale preferredLanguages ] firstObject ];
	if (preferredLang == nil) return std::nullopt;

	return std::string{ [ preferredLang UTF8String ] };
}

/**
 * Return the contents of the clipboard.
 * @return The (optional) clipboard contents.
 */
std::optional<std::string> GetClipboardContents()
{
	NSString *string = [ [ UIPasteboard generalPasteboard ] string ];
	if (string == nil || [ string length ] == 0) return std::nullopt;

	return std::string{ [ string UTF8String ] };
}

/** Set the application's bundle directory.
 *
 * On iOS the game data is shipped inside the application bundle, in a
 * subdirectory "Data". Point the ApplicationBundleDir search path there.
 */
void IosSetApplicationBundleDir()
{
	extern EnumIndexArray<std::string, Searchpath, Searchpath::End> _searchpaths;

	NSString *bundleDir = [ [ NSBundle mainBundle ] bundlePath ];
	NSString *dataDir = [ bundleDir stringByAppendingPathComponent:@"Data" ];

	_searchpaths[Searchpath::ApplicationBundleDir] = std::string{ [ dataDir UTF8String ] };
	AppendPathSeparator(_searchpaths[Searchpath::ApplicationBundleDir]);
}

/**
 * Returns the path to the app's Documents directory (with trailing path separator).
 *
 * This is the user-visible, persistent storage location in the sandbox, so all
 * saves, screenshots and settings live here.
 */
std::string IosGetDocumentsDir()
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = [ paths firstObject ];
	if (documentsPath == nil) return {};

	std::string ret = [ documentsPath UTF8String ];
	AppendPathSeparator(ret);
	return ret;
}

/**
 * Get the version of the iOS we are running under.
 * @return Tuple with major, minor and patch of the iOS version.
 */
std::tuple<int, int, int> GetMacOSVersion()
{
	NSOperatingSystemVersion ver = [ [ NSProcessInfo processInfo ] operatingSystemVersion ];
	return { static_cast<int>(ver.majorVersion), static_cast<int>(ver.minorVersion), static_cast<int>(ver.patchVersion) };
}

/**
 * Check if a font is a monospace font.
 * @param name Name of the font.
 * @return True if the font is a monospace font.
 */
bool IsMonospaceFont(CFStringRef name)
{
	CTFontRef font = CTFontCreateWithName(name, 0, nullptr);
	if (font == nullptr) return false;

	CTFontSymbolicTraits traits = CTFontGetSymbolicTraits(font);
	CFRelease(font);

	return (traits & kCTFontTraitMonoSpace) != 0;
}

/**
 * Set the name of the current thread for the debugger.
 * @param name The new name of the current thread.
 */
void MacOSSetThreadName(const std::string &name)
{
	pthread_setname_np(name.c_str());
}

/**
 * Ask OS how much RAM it has physically attached.
 * @return Number of available bytes.
 */
uint64_t MacOSGetPhysicalMemory()
{
	return [ [ NSProcessInfo processInfo ] physicalMemory ];
}