/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/**
 * @file ios_v.mm The iOS video driver.
 *
 * Renders OpenTTD's software buffer through OpenGL ES 2.0 on top of a UIKit
 * view. Input is delivered through UIKit touch/gesture events mapped onto
 * OpenTTD's mouse model: single finger = left mouse, long press = right
 * button, pinch = zoom, two-finger pan = map scroll. Keyboard input comes from
 * a hidden UITextField acting as a bridge for the on-screen keyboard.
 */

#if defined(WITH_IOS) || defined(DOXYGEN_API)

#include "../../stdafx.h"
#include "../../os/ios/ios.h"
#include "../../os/ios/ios_main.h"
#include "../../openttd.h"
#include "../../debug.h"
#include "../../error_func.h"
#include "../../core/geometry_func.hpp"
#include "../../core/math_func.hpp"
#include "ios_v.h"
#include "../../blitter/factory.hpp"
#include "../../framerate_type.h"
#include "../../gfx_func.h"
#include "../../gfx_type.h"
#include "../../thread.h"
#include "../../core/random_func.hpp"
#include "../../progress.h"
#include "../../settings_type.h"
#include "../../string_func.h"
#include "../../strings_func.h"
#include "../../window_func.h"
#include "../../window_gui.h"

#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

#include <sys/time.h>

static Palette _local_palette; ///< Current palette to use for drawing.

/** Recorded view size (points, encoded) to detect layout changes. */
static std::atomic<float> _known_view_size{0.0f};
static std::atomic<bool> _ios_resize_pending{false}; ///< View resized; resize the backing store on the game thread.

/* --- Touch state: written on the main thread from gesture callbacks,
       read on the game thread from InputLoop(). --- */

static std::atomic<float> _ios_touch_x{0.0f};
static std::atomic<float> _ios_touch_y{0.0f};
static std::atomic<bool> _ios_touch_active{false};
static std::atomic<bool> _ios_touch_dragging{false};
static std::atomic<bool> _ios_long_press_began{false};
static std::atomic<bool> _ios_long_press_active{false};
static std::atomic<bool> _ios_pinch_active{false};
static std::atomic<float> _ios_pinch_accum{0.0f};
static std::atomic<bool> _ios_scroll_active{false};
static std::atomic<float> _ios_scroll_dx{0.0f};
static std::atomic<float> _ios_scroll_dy{0.0f};

/**
 * The OpenGL ES view. Handles all touch input and provides the CAEAGLLayer
 * the game renders into.
 */
@interface OTTD_iOSView : UIView

@property(nonatomic, assign) VideoDriver_iOS *driver;

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handlePinch:(UIPinchGestureRecognizer *)gesture;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;

@end

/**
 * Hidden text field that forwards the on-screen keyboard to OpenTTD.
 */
@interface OTTD_iOSKeyboard : UITextField <UITextFieldDelegate>

@property(nonatomic, assign) VideoDriver_iOS *driver;

@end

VideoDriver_iOS::VideoDriver_iOS()
{
	this->orig_res = {};
	this->ios_view = nil;
	this->ios_keyboard = nil;
	this->eagl_context = nil;
	this->framebuffer = 0;
	this->color_renderbuffer = 0;
	this->texture = 0;
	this->pixel_buffer = nullptr;
	this->view_width = 0;
	this->view_height = 0;
	this->view_pitch = 0;
	this->buffer_locked = false;
	this->gl_ready = false;
	this->dirty_rect = {};

	memset(this->palette, 0, sizeof(this->palette));
}

/** Stop the video driver. */
void VideoDriver_iOS::Stop()
{
	this->StopGameThread();

	IosRunSyncOnMain(^{
		[ this->ios_keyboard removeFromSuperview ];
		[ this->ios_keyboard release ];
		this->ios_keyboard = nil;

		[ this->ios_view removeFromSuperview ];
		[ this->ios_view release ];
		this->ios_view = nil;
	});

	if (this->eagl_context != nil) {
		[ EAGLContext setCurrentContext:this->eagl_context ];
		this->CleanupGL();
		[ EAGLContext setCurrentContext:nil ];
		[ this->eagl_context release ];
		this->eagl_context = nil;
	}

	if (this->pixel_buffer != nullptr) {
		delete[] this->pixel_buffer;
		this->pixel_buffer = nullptr;
	}
}

/**
 * Start the video driver.
 * @param param Optional parameters.
 * @return Error message on failure, std::nullopt on success.
 */
std::optional<std::string_view> VideoDriver_iOS::Start(const StringList &param)
{
	os_log(OS_LOG_DEFAULT, "OpenTTD iOS: video driver Start");
	if (this->gl_ready) return "Already started";

	__block int width = 0;
	__block int height = 0;

	/* Create the drawable view on the main thread. */
	IosRunSyncOnMain(^{
		UIView *host = IosGetHostView();
		if (host == nil) return;

		CGFloat scale = IosGetScreenScale();
		CGSize bounds = host.bounds.size;

		this->ios_view = [ [ OTTD_iOSView alloc ] initWithFrame:CGRectMake(0, 0, bounds.width, bounds.height) ];
		this->ios_view.driver = this;
		this->ios_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		this->ios_view.multipleTouchEnabled = YES;
		[ host addSubview:this->ios_view ];

		this->ios_keyboard = [ [ OTTD_iOSKeyboard alloc ] initWithFrame:CGRectMake(0, 0, 1, 1) ];
		this->ios_keyboard.driver = this;
		[ host addSubview:this->ios_keyboard ];

		width = (int)(bounds.width * scale);
		height = (int)(bounds.height * scale);
	});

	if (this->ios_view == nil) return "Could not create the iOS view";

	/* Fill in the resolutions list. */
	_resolutions.clear();
	_resolutions.emplace_back(width, height);

	this->UpdateAutoResolution();
	this->orig_res = _cur_resolution;

	this->SetupGL();

	this->AllocateBackingStore(true);

	this->GameSizeChanged();

	return std::nullopt;
}

/**
 * Setup the OpenGL ES context and framebuffer.
 */
void VideoDriver_iOS::SetupGL()
{
	this->eagl_context = [ [ EAGLContext alloc ] initWithAPI:kEAGLRenderingAPIOpenGLES2 ];
	if (this->eagl_context == nil) {
		FatalError("Could not create an OpenGL ES 2.0 context.");
		return;
	}

	[ EAGLContext setCurrentContext:this->eagl_context ];

	glGenFramebuffers(1, &this->framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, this->framebuffer);

	glGenRenderbuffers(1, &this->color_renderbuffer);
	glBindRenderbuffer(GL_RENDERBUFFER, this->color_renderbuffer);

	/* Get the CAEAGLLayer to render into. The layer may be used from any
	 * thread; the renderbuffer binding must happen while this context is
	 * current, which is the case on the game (rendering) thread. */
	CAEAGLLayer *eaglLayer = (CAEAGLLayer *)this->ios_view.layer;

	BOOL storage_ok = [ this->eagl_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer ];

	if (!storage_ok) {
		FatalError("Could not allocate the OpenGL ES renderbuffer storage.");
		return;
	}

	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, this->color_renderbuffer);

	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		FatalError("OpenGL ES framebuffer is not complete.");
		return;
	}

	/* Create the texture the game draws into. */
	glGenTextures(1, &this->texture);
	glBindTexture(GL_TEXTURE_2D, this->texture);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

	this->gl_ready = true;

	Debug(Facility::Driver, Severity::Error, "OpenGL ES 2.0 set up");
}

/**
 * Cleanup OpenGL ES resources.
 */
void VideoDriver_iOS::CleanupGL()
{
	if (!this->gl_ready) return;

	glDeleteTextures(1, &this->texture);
	this->texture = 0;
	glDeleteRenderbuffers(1, &this->color_renderbuffer);
	this->color_renderbuffer = 0;
	glDeleteFramebuffers(1, &this->framebuffer);
	this->framebuffer = 0;

	this->gl_ready = false;
}

/**
 * Set dirty a rectangle managed by the iOS video driver.
 * @param left Left x coordinate of the dirty rectangle.
 * @param top Upper y coordinate of the dirty rectangle.
 * @param width Width of the dirty rectangle.
 * @param height Height of the dirty rectangle.
 */
void VideoDriver_iOS::MakeDirty(int left, int top, int width, int height)
{
	Rect r = { left, top, left + width, top + height };
	this->dirty_rect = BoundingRect(this->dirty_rect, r);
}

/**
 * Allocate the backing store (offscreen pixel buffer + texture).
 * @param ignore Unused.
 */
void VideoDriver_iOS::AllocateBackingStore(bool ignore)
{
	this->ResizeBackingStore();
}

/**
 * The view (or screen) dimensions changed: reallocate the backing store.
 */
void VideoDriver_iOS::ResizeBackingStore()
{
	if (!this->gl_ready) return;

	__block int width = 0;
	__block int height = 0;

	/* The view's bounds are only valid on the main thread. When this runs on
	 * the game thread (the normal case) we hop to the main thread to read
	 * them; the GL work below is done here, on the rendering thread. */
	IosRunSyncOnMain(^{
		if (this->ios_view == nil) return;
		CGFloat scale = IosGetScreenScale();
		CGSize bounds = this->ios_view.bounds.size;
		width = (int)(bounds.width * scale);
		height = (int)(bounds.height * scale);
	});
	if (width == 0 || height == 0) return;
	if (width == this->view_width && height == this->view_height) return;

	[ EAGLContext setCurrentContext:this->eagl_context ];

	this->view_width = width;
	this->view_height = height;
	this->view_pitch = width;

	if (this->pixel_buffer != nullptr) delete[] this->pixel_buffer;
	this->pixel_buffer = new uint32_t[static_cast<size_t>(this->view_width) * this->view_height];
	memset(this->pixel_buffer, 0, static_cast<size_t>(this->view_width) * this->view_height * sizeof(uint32_t));

	glBindTexture(GL_TEXTURE_2D, this->texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, this->view_width, this->view_height, 0, GL_BGRA_EXT, GL_UNSIGNED_BYTE, this->pixel_buffer);

	_screen.width = this->view_width;
	_screen.height = this->view_height;
	_screen.pitch = this->view_pitch;

	this->MakeDirty(0, 0, _screen.width, _screen.height);
	this->GameSizeChanged();

	Debug(Facility::Driver, Severity::Error, "backing store {}x{}", _screen.width, _screen.height);
}

/**
 * Change the resolution.
 * @param w New window width.
 * @param h New window height.
 * @return Whether the video driver was updated successfully.
 */
bool VideoDriver_iOS::ChangeResolution(int w, int h)
{
	/* On iOS there is exactly one usable resolution: the physical screen. */
	this->AllocateBackingStore(true);
	_cur_resolution.width = _screen.width;
	_cur_resolution.height = _screen.height;
	return true;
}

/**
 * Toggle fullscreen mode.
 * @param fullscreen Whether to be fullscreen.
 * @return Always true; iOS is always fullscreen.
 */
bool VideoDriver_iOS::ToggleFullscreen(bool fullscreen)
{
	/* iOS is always fullscreen. */
	return true;
}

/**
 * Callback invoked after the blitter was changed.
 * @return True if no error.
 */
bool VideoDriver_iOS::AfterBlitterChange()
{
	this->AllocateBackingStore(true);
	return true;
}

/**
 * Get list of refresh rates of the only connected display.
 * @return Refresh rates of the main display.
 */
std::vector<int> VideoDriver_iOS::GetListOfMonitorRefreshRates()
{
	return { static_cast<int>([ [ UIScreen mainScreen ] maximumFramesPerSecond ]) };
}

/**
 * Get the resolution of the main screen (physical pixels).
 * @return The resolution of the main screen.
 */
Dimension VideoDriver_iOS::GetScreenSize() const
{
	CGSize bounds = [ [ UIScreen mainScreen ] nativeBounds ].size;
	return { static_cast<uint>(bounds.width), static_cast<uint>(bounds.height) };
}

/**
 * Lock video buffer for drawing if it isn't already mapped.
 * @return True on success and false otherwise.
 */
bool VideoDriver_iOS::LockVideoBuffer()
{
	if (this->buffer_locked) return false;
	this->buffer_locked = true;

	_screen.dst_ptr = this->pixel_buffer;
	assert(_screen.dst_ptr != nullptr);

	return true;
}

/** Unlock video buffer. */
void VideoDriver_iOS::UnlockVideoBuffer()
{
	_screen.dst_ptr = nullptr;
	this->buffer_locked = false;
}

/**
 * Update the palette from the global palette.
 */
void VideoDriver_iOS::CheckPaletteAnim()
{
	Blitter *blitter = BlitterFactory::GetCurrentBlitter();

	switch (blitter->UsePaletteAnimation()) {
		case Blitter::PaletteAnimation::Blitter:
			if (CopyPalette(_local_palette)) blitter->PaletteAnimate(_local_palette);
			break;

		case Blitter::PaletteAnimation::VideoBackend:
		case Blitter::PaletteAnimation::None:
			break;

		default:
			NOT_REACHED();
	}
}

/**
 * Handle a change of the display area.
 */
void VideoDriver_iOS::GameSizeChanged()
{
	BlitterFactory::GetCurrentBlitter()->PostResize();

	::GameSizeChanged();
}

/**
 * Main game loop.
 */
void VideoDriver_iOS::MainLoop()
{
	this->StartGameThread();

	for (;;) {
		@autoreleasepool {
			if (_exit_game) break;

			this->Tick();
			this->SleepTillNextTick();
		}
	}

	this->StopGameThread();
}

/**
 * Process input; called once per draw tick on the game thread.
 */
void VideoDriver_iOS::InputLoop()
{
	/* A view/screen size change was deferred to the game thread: the GL
	 * resources belong to the rendering thread, so do the resize here. */
	if (_ios_resize_pending.exchange(false)) {
		this->ResizeBackingStore();
	}

	/* Map the touch position into the game's pixel space; the game buffer
	 * has the same dimensions as the view, so scale by the screen factor. */
	CGFloat scale = IosGetScreenScale();

	float x = _ios_touch_x.load() * scale;
	float y = _ios_touch_y.load() * scale;

	_cursor.UpdateCursorPosition((int)x, (int)y);
	_cursor.in_window = true;

	/* Pinch-to-zoom maps to the mouse wheel. */
	if (_ios_pinch_active.load()) {
		float delta = _ios_pinch_accum.exchange(0.0f);
		if (delta != 0.0f) _cursor.wheel += (int)delta;
	}

	/* Two-finger pan maps to the 2D wheel (map scroll). */
	if (_ios_scroll_active.load()) {
		_cursor.h_wheel -= _ios_scroll_dx.exchange(0.0f);
		_cursor.v_wheel -= _ios_scroll_dy.exchange(0.0f);
		_cursor.wheel_moved = true;
	}

	/* Long press maps to the right mouse button. */
	if (_ios_long_press_began.exchange(false)) {
		_right_button_down = true;
		_right_button_clicked = true;
	}
	if (!_ios_long_press_active.load() && _right_button_down) {
		_right_button_down = false;
	}

	/* Single finger maps to the left mouse button. */
	bool dragging = _ios_touch_dragging.load();
	if (dragging) {
		if (!_left_button_down) {
			_left_button_down = true;
			_left_button_clicked = false;
		}
	} else {
		_left_button_down = false;
		_left_button_clicked = false;
	}

	this->fast_forward_key_pressed = false;
}

/**
 * Upload the dirty region and present the frame.
 */
void VideoDriver_iOS::Paint()
{
	if (IsEmptyRect(this->dirty_rect)) return;

	PerformanceMeasurer framerate(PerformanceElement::Video);

	[ EAGLContext setCurrentContext:this->eagl_context ];

	glBindTexture(GL_TEXTURE_2D, this->texture);
	glTexSubImage2D(
		GL_TEXTURE_2D,
		0,
		this->dirty_rect.left,
		this->dirty_rect.top,
		this->dirty_rect.right - this->dirty_rect.left,
		this->dirty_rect.bottom - this->dirty_rect.top,
		GL_BGRA_EXT,
		GL_UNSIGNED_BYTE,
		this->pixel_buffer + static_cast<size_t>(this->dirty_rect.top) * this->view_pitch + this->dirty_rect.left
	);

	glBindFramebuffer(GL_FRAMEBUFFER, this->framebuffer);
	glViewport(0, 0, this->view_width, this->view_height);

	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);

	this->draw_textured_quad();

	[ this->eagl_context presentRenderbuffer:GL_RENDERBUFFER ];

	this->dirty_rect = {};
}

/**
 * Draw a full-screen textured quad that scales the game buffer to the display,
 * preserving the aspect ratio.
 */
void VideoDriver_iOS::draw_textured_quad()
{
	static const GLfloat quad_vertices[] = {
		-1.0f, -1.0f, 0.0f, 0.0f, 1.0f,
		 1.0f, -1.0f, 0.0f, 1.0f, 1.0f,
		-1.0f,  1.0f, 0.0f, 0.0f, 0.0f,
		 1.0f,  1.0f, 0.0f, 1.0f, 0.0f,
	};
	static const GLuint quad_indices[] = { 0, 1, 2, 2, 1, 3 };
	static GLuint program = 0;
	static GLuint vao = 0;
	static GLuint vbo = 0;
	static GLuint ibo = 0;

	if (program == 0) {
		const char *vertex_shader =
			"attribute vec4 aPos;\n"
			"attribute vec2 aTexCoord;\n"
			"varying vec2 vTexCoord;\n"
			"void main() {\n"
			"    vTexCoord = aTexCoord;\n"
			"    gl_Position = aPos;\n"
			"}\n";
		const char *fragment_shader =
			"precision mediump float;\n"
			"varying vec2 vTexCoord;\n"
			"uniform sampler2D uTexture;\n"
			"void main() {\n"
			"    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
			"}\n";

		GLuint vs = glCreateShader(GL_VERTEX_SHADER);
		glShaderSource(vs, 1, &vertex_shader, nullptr);
		glCompileShader(vs);
		GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
		glShaderSource(fs, 1, &fragment_shader, nullptr);
		glCompileShader(fs);

		program = glCreateProgram();
		glAttachShader(program, vs);
		glAttachShader(program, fs);
		glBindAttribLocation(program, 0, "aPos");
		glBindAttribLocation(program, 1, "aTexCoord");
		glLinkProgram(program);
		glDeleteShader(vs);
		glDeleteShader(fs);

		glGenBuffers(1, &vbo);
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW);

		glGenBuffers(1, &ibo);
		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
		glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(quad_indices), quad_indices, GL_STATIC_DRAW);
	}

	glUseProgram(program);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, this->texture);
	glUniform1i(glGetUniformLocation(program, "uTexture"), 0);

	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);

	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), (const void *)0);

	glEnableVertexAttribArray(1);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), (const void *)(3 * sizeof(GLfloat)));

	glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, (const void *)0);
}

/**
 * An edit box gained focus: show the on-screen keyboard.
 */
void VideoDriver_iOS::EditBoxGainedFocus()
{
	IosRunOnMain(^{
		if (this->ios_keyboard != nil) {
			this->ios_keyboard.text = @" ";
			this->ios_keyboard.hidden = NO;
			[ this->ios_keyboard becomeFirstResponder ];
		}
	});
}

/**
 * An edit box lost focus: hide the on-screen keyboard.
 */
void VideoDriver_iOS::EditBoxLostFocus()
{
	IosRunOnMain(^{
		if (this->ios_keyboard != nil && [ this->ios_keyboard isFirstResponder ]) {
			[ this->ios_keyboard resignFirstResponder ];
			this->ios_keyboard.hidden = YES;
		}
	});
}

/** Register the iOS video driver. */
static FVideoDriver_iOS iFVideoDriver_iOS;

/* ---------------------------------------------------------------------- */
/* Objective-C++ view / keyboard classes                                   */
/* ---------------------------------------------------------------------- */

@implementation OTTD_iOSView

@synthesize driver;

+ (Class)layerClass
{
	return [ CAEAGLLayer class ];
}

- (instancetype)initWithFrame:(CGRect)frame
{
	if (self = [ super initWithFrame:frame ]) {
		CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
		layer.opaque = YES;
		layer.contentsScale = IosGetScreenScale();
		layer.drawableProperties = @{
			kEAGLDrawablePropertyRetainedBacking : @NO,
			kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8
		};

		/* Right-click via a long press. */
		UILongPressGestureRecognizer *longPress = [ [ UILongPressGestureRecognizer alloc ] initWithTarget:self action:@selector(handleLongPress:) ];
		longPress.minimumPressDuration = 0.5;
		[ self addGestureRecognizer:longPress ];
		[ longPress release ];

		/* Zoom via a pinch. */
		UIPinchGestureRecognizer *pinch = [ [ UIPinchGestureRecognizer alloc ] initWithTarget:self action:@selector(handlePinch:) ];
		[ self addGestureRecognizer:pinch ];
		[ pinch release ];

		/* Map scroll via a two-finger pan. */
		UIPanGestureRecognizer *pan = [ [ UIPanGestureRecognizer alloc ] initWithTarget:self action:@selector(handlePan:) ];
		pan.minimumNumberOfTouches = 2;
		pan.maximumNumberOfTouches = 2;
		[ self addGestureRecognizer:pan ];
		[ pan release ];
	}
	return self;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture
{
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan:
			_ios_touch_x = [ gesture locationInView:self ].x;
			_ios_touch_y = [ gesture locationInView:self ].y;
			_ios_long_press_began = true;
			_ios_long_press_active = true;
			break;

		case UIGestureRecognizerStateEnded:
		case UIGestureRecognizerStateCancelled:
			_ios_long_press_active = false;
			break;

		default:
			break;
	}
}

- (void)handlePinch:(UIPinchGestureRecognizer *)gesture
{
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan:
			_ios_pinch_active = true;
			_ios_pinch_accum = 0.0f;
			break;

		case UIGestureRecognizerStateChanged:
			_ios_pinch_accum += (gesture.scale - 1.0f) * 10.0f;
			gesture.scale = 1.0f;
			break;

		case UIGestureRecognizerStateEnded:
		case UIGestureRecognizerStateCancelled:
			_ios_pinch_active = false;
			_ios_pinch_accum = 0.0f;
			break;

		default:
			break;
	}
}

static CGPoint _last_pan_translation; ///< Last recorded translation of the two-finger pan.

- (void)handlePan:(UIPanGestureRecognizer *)gesture
{
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan:
			_ios_scroll_active = true;
			_ios_scroll_dx = 0.0f;
			_ios_scroll_dy = 0.0f;
			_last_pan_translation = [ gesture translationInView:self ];
			break;

		case UIGestureRecognizerStateChanged: {
			CGPoint translation = [ gesture translationInView:self ];
			_ios_scroll_dx = translation.x - _last_pan_translation.x;
			_ios_scroll_dy = translation.y - _last_pan_translation.y;
			_last_pan_translation = translation;
			break;
		}

		case UIGestureRecognizerStateEnded:
		case UIGestureRecognizerStateCancelled:
			_ios_scroll_active = false;
			break;

		default:
			break;
	}
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if (!_ios_pinch_active.load() && event.allTouches.count < 2) {
		UITouch *touch = [ touches anyObject ];
		if (touch != nil) {
			_ios_touch_x = [ touch locationInView:self ].x;
			_ios_touch_y = [ touch locationInView:self ].y;
		}
		_ios_touch_active = true;
		_ios_touch_dragging = true;
	}
	[ super touchesBegan:touches withEvent:event ];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	UITouch *touch = [ touches anyObject ];
	if (touch != nil) {
		_ios_touch_x = [ touch locationInView:self ].x;
		_ios_touch_y = [ touch locationInView:self ].y;
	}
	[ super touchesMoved:touches withEvent:event ];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	_ios_touch_active = false;
	_ios_touch_dragging = false;
	_ios_long_press_began = false;
	_ios_long_press_active = false;
	[ super touchesEnded:touches withEvent:event ];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	_ios_touch_active = false;
	_ios_touch_dragging = false;
	_ios_long_press_began = false;
	_ios_long_press_active = false;
	[ super touchesCancelled:touches withEvent:event ];
}

@end

@implementation OTTD_iOSKeyboard

@synthesize driver;

- (instancetype)initWithFrame:(CGRect)frame
{
	if (self = [ super initWithFrame:frame ]) {
		self.backgroundColor = [ UIColor clearColor ];
		self.textColor = [ UIColor clearColor ];
		self.tintColor = [ UIColor clearColor ];
		self.keyboardAppearance = UIKeyboardAppearanceDark;
		self.delegate = self;
		self.autocorrectionType = UITextAutocorrectionTypeNo;
		self.autocapitalizationType = UITextAutocapitalizationTypeNone;
		self.smartQuotesType = UITextSmartQuotesTypeNo;
		self.smartDashesType = UITextSmartDashesTypeNo;
		self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
		self.text = @" ";
		self.hidden = YES;
	}
	return self;
}

- (BOOL)canBecomeFirstResponder
{
	return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
	HandleKeypress(WKC_RETURN, '\r');
	[ textField resignFirstResponder ];
	return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
	self.hidden = YES;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
	if (string.length == 0 && range.length > 0) {
		/* Backspace / delete key. */
		for (NSUInteger i = 0; i < range.length; i++) {
			HandleKeypress(WKC_BACKSPACE, '\b');
		}
		return NO;
	}

	if (string.length > 0) {
		HandleTextInput(std::string_view{ [ string UTF8String ], [ string lengthOfBytesUsingEncoding:NSUTF8StringEncoding ] });
	}

	return NO;
}

@end

/**
 * Handle application lifecycle: the app went to the background.
 */
void IosVideoPause()
{
	_ios_touch_active = false;
	_ios_touch_dragging = false;
	_ios_long_press_began = false;
	_ios_long_press_active = false;
	_ios_pinch_active = false;
}

/**
 * Handle application lifecycle: the app came to the foreground.
 */
void IosVideoResume()
{
}

/**
 * Called by the host view when its size changes.  Records the new size and
 * flags the video driver to perform the actual GL resize on the next tick
 * (the game thread owns the rendering context, so we must not touch GL
 * here).
 */
void IosNotifyHostViewSizeChanged(CGFloat width, CGFloat height)
{
	float new_size = width * 1000.0f + height;
	if (_known_view_size.load() != 0.0f && new_size != _known_view_size.load()) {
		_ios_resize_pending.store(true);
	}
	_known_view_size = new_size;
}

#endif /* WITH_IOS or DOXYGEN_API */