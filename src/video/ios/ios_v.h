/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_v.h iOS video driver. */

#ifndef VIDEO_IOS_H
#define VIDEO_IOS_H

#include "../video_driver.hpp"
#include "../../core/geometry_type.hpp"

#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>

@class OTTD_iOSView;
@class OTTD_iOSKeyboard;
@class EAGLContext;

class VideoDriver_iOS : public VideoDriver {
private:
	Dimension orig_res;

	OTTD_iOSView *ios_view;    ///< The OpenGL ES view.
	OTTD_iOSKeyboard *ios_keyboard; ///< The hidden keyboard text field.

	EAGLContext *eagl_context; ///< The OpenGL ES context.
	GLuint framebuffer;       ///< The OpenGL ES framebuffer.
	GLuint color_renderbuffer; ///< The color renderbuffer attached to the framebuffer.
	GLuint texture;           ///< Texture the game draws into.

	uint32_t *pixel_buffer;   ///< The pixel buffer for the current screen depth.
	uint32_t palette[256];    ///< Colour palette.

	int view_width;           ///< The current width of the view, in pixels.
	int view_height;          ///< The current height of the view, in pixels.
	int view_pitch;           ///< The current pitch of the pixel buffer, in pixels.

	Rect dirty_rect;          ///< Region of the screen that needs redrawing.

	bool buffer_locked;       ///< Video buffer was locked by the main thread.
	bool gl_ready;            ///< True once GL context and resources are set up.

public:
	VideoDriver_iOS();

	void Stop() override;
	void MainLoop() override;

	void MakeDirty(int left, int top, int width, int height) override;
	bool AfterBlitterChange() override;

	bool ChangeResolution(int w, int h) override;
	bool ToggleFullscreen(bool fullscreen) override;

	void EditBoxLostFocus() override;
	void EditBoxGainedFocus() override;

	std::optional<std::string_view> Start(const StringList &param) override;
	std::string_view GetName() const override { return "ios"; }

	std::vector<int> GetListOfMonitorRefreshRates() override;

	void AllocateBackingStore(bool force = false);
	void ResizeBackingStore();

protected:
	Dimension GetScreenSize() const override;
	void InputLoop() override;
	bool LockVideoBuffer() override;
	void UnlockVideoBuffer() override;
	void CheckPaletteAnim() override;
	void Paint() override;

	void GameSizeChanged();

private:
	void SetupGL();
	void CleanupGL();
	void draw_textured_quad();
};

class FVideoDriver_iOS : public DriverFactoryBase {
public:
	FVideoDriver_iOS() : DriverFactoryBase(Driver::Type::Video, 8, "ios", "iOS Video Driver") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_iOS>(); }
};

#endif /* VIDEO_IOS_H */