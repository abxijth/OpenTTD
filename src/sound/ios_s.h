/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_s.h Base for iOS sound handling. */

#ifndef SOUND_IOS_H
#define SOUND_IOS_H

#include "sound_driver.hpp"

class SoundDriver_iOS : public SoundDriver {
public:
	std::optional<std::string_view> Start(const StringList &param) override;

	void Stop() override;
	std::string_view GetName() const override { return "ios"; }
};

class FSoundDriver_iOS : public DriverFactoryBase {
public:
	FSoundDriver_iOS() : DriverFactoryBase(Driver::Type::Sound, 10, "ios", "iOS Sound Driver (param hz)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<SoundDriver_iOS>(); }
};

#endif /* SOUND_IOS_H */