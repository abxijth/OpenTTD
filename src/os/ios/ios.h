/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios.h Centralised functions of the iOS OS layer. */

#ifndef IOS_H
#define IOS_H

#include "../macosx/macos.h"

void IosShowErrorDialog(std::string_view title, std::string_view message, std::string_view button_label);

void IosSetApplicationBundleDir();

std::string IosGetDocumentsDir();

#endif /* IOS_H */