/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_s.cpp Sound driver for iOS. */

/*****************************************************************************
 *                              iOS sound driver                             *
 * Based on the Cocoa sound driver but using kAudioUnitSubType_RemoteIO,      *
 * which is the output audio unit type used on iOS.                          *
 *****************************************************************************/

#ifdef WITH_IOS

#include "../stdafx.h"
#include "../debug.h"
#include "../driver.h"
#include "../mixer.h"
#include "ios_s.h"

#define Rect        OTTDRect
#define Point       OTTDPoint
#include <AudioUnit/AudioUnit.h>
#undef Rect
#undef Point

#include "../safeguards.h"

static FSoundDriver_iOS iFSoundDriver_iOS;

static AudioUnit _outputAudioUnit;

/* The CoreAudio callback */
static OSStatus audioCallback(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *ioData)
{
	MxMixSamples(ioData->mBuffers[0].mData, ioData->mBuffers[0].mDataByteSize / 4);

	return noErr;
}


std::optional<std::string_view> SoundDriver_iOS::Start(const StringList &parm)
{
	struct AURenderCallbackStruct callback;
	AudioStreamBasicDescription requestedDesc;

	/* Setup a AudioStreamBasicDescription with the requested format */
	requestedDesc.mFormatID = kAudioFormatLinearPCM;
	requestedDesc.mFormatFlags = kLinearPCMFormatFlagIsPacked;
	requestedDesc.mChannelsPerFrame = 2;
	requestedDesc.mSampleRate = GetDriverParamInt(parm, "hz", 44100);

	requestedDesc.mBitsPerChannel = 16;
	requestedDesc.mFormatFlags |= kLinearPCMFormatFlagIsSignedInteger;

	if constexpr (std::endian::native == std::endian::big) {
		requestedDesc.mFormatFlags |= kLinearPCMFormatFlagIsBigEndian;
	}

	requestedDesc.mFramesPerPacket = 1;
	requestedDesc.mBytesPerFrame = requestedDesc.mBitsPerChannel * requestedDesc.mChannelsPerFrame / 8;
	requestedDesc.mBytesPerPacket = requestedDesc.mBytesPerFrame * requestedDesc.mFramesPerPacket;

	MxInitialize((uint)requestedDesc.mSampleRate);

	/* Locate the default output audio unit */
	AudioComponentDescription desc;
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	desc.componentFlags = 0;
	desc.componentFlagsMask = 0;

	AudioComponent comp = AudioComponentFindNext (nullptr, &desc);
	if (comp == nullptr) {
		return "ios_s: Failed to start CoreAudio: AudioComponentFindNext returned nullptr";
	}

	/* Open & initialize the default output audio unit */
	if (AudioComponentInstanceNew(comp, &_outputAudioUnit) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioComponentInstanceNew";
	}

	if (AudioUnitInitialize(_outputAudioUnit) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioUnitInitialize";
	}

	/* Set the input format of the audio unit. */
	if (AudioUnitSetProperty(_outputAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &requestedDesc, sizeof(requestedDesc)) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioUnitSetProperty (kAudioUnitProperty_StreamFormat)";
	}

	/* Set the audio callback */
	callback.inputProc = audioCallback;
	callback.inputProcRefCon = nullptr;
	if (AudioUnitSetProperty(_outputAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioUnitSetProperty (kAudioUnitProperty_SetRenderCallback)";
	}

	/* Finally, start processing of the audio unit */
	if (AudioOutputUnitStart(_outputAudioUnit) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioOutputUnitStart";
	}

	/* We're running! */
	return std::nullopt;
}


void SoundDriver_iOS::Stop()
{
	struct AURenderCallbackStruct callback;

	/* stop processing the audio unit */
	if (AudioOutputUnitStop(_outputAudioUnit) != noErr) {
		Debug(Facility::Driver, Severity::Critical, "ios_s: Core_CloseAudio: AudioOutputUnitStop failed");
		return;
	}

	/* Remove the input callback */
	callback.inputProc = 0;
	callback.inputProcRefCon = 0;
	if (AudioUnitSetProperty(_outputAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) {
		Debug(Facility::Driver, Severity::Critical, "ios_s: Core_CloseAudio: AudioUnitSetProperty (kAudioUnitProperty_SetRenderCallback) failed");
		return;
	}

	if (AudioComponentInstanceDispose(_outputAudioUnit) != noErr) {
		Debug(Facility::Driver, Severity::Critical, "ios_s: Core_CloseAudio: AudioComponentInstanceDispose failed");
		return;
	}
}

#endif /* WITH_IOS */