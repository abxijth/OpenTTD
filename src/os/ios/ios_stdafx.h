/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_stdafx.h iOS is different on some places. */

#ifndef IOS_STDAFX_H
#define IOS_STDAFX_H

#include <Availability.h>
#include <stdint.h>
#include <stddef.h>

/* Some gcc versions include assert.h via this header. As this would interfere
 * with our own assert redefinition, include this header first. */
#if !defined(__clang__) && defined(__GNUC__) && (__GNUC__ > 3 || (__GNUC__ == 3 && __GNUC_MINOR__ >= 3))
#	include <debug/debug.h>
#endif

/* Check for mismatching 'architectures' */
#if defined(__LP64__) && !defined(POINTER_IS_64BIT)
#	error "Compiling 64 bits without POINTER_IS_64BIT set!"
#endif

/* Name conflicts between OpenTTD and CoreFoundation/UIKit headers. */
#define Rect        OTTDRect
#define Point       OTTDPoint
#define WindowClass OTTDWindowClass
#define ScriptOrder OTTDScriptOrder
#define Palette     OTTDPalette
#define GlyphID     OTTDGlyphID

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#undef Rect
#undef Point
#undef WindowClass
#undef ScriptOrder
#undef Palette
#undef GlyphID

/* Remove the variables that the system headers define, but we define ourselves too. */
#undef bool
#undef false
#undef true

/* Name conflicts */
#define GetTime OTTD_GetTime
#define GetString OTTD_GetString
#define DrawString OTTD_DrawString
#define CloseConnection OTTD_CloseConnection

/* iOS has a non-const iconv. */
#define HAVE_NON_CONST_ICONV

#endif /* IOS_STDAFX_H */