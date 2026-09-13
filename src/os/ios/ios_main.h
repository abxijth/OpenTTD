/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_main.h Bridge between the UIKit app-shell and the OpenTTD video driver. */

#ifndef IOS_MAIN_H
#define IOS_MAIN_H

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <string>

std::string NSStringToCpp(NSString *str);

void IosRunOnMain(dispatch_block_t block);
void IosRunSyncOnMain(dispatch_block_t block);

UIView *IosGetHostView();
CGFloat IosGetScreenScale();

void IosNotifyHostViewSizeChanged(CGFloat width, CGFloat height);
void IosVideoPause();
void IosVideoResume();

#endif /* IOS_MAIN_H */