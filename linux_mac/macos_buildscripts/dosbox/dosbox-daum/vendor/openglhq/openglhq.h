/* openglhq.h -- OpenGL-HQ scaler for DOSBox, reimplemented as a renderer.
 *
 * Upstream OpenGL-HQ is an SDL 1.2 *video driver*: it plugs into SDL 1.2's
 * SDL_VideoDevice bootstrap table and transparently intercepts any 2D SDL
 * program.  sdl12-compat is an API shim over SDL2 with no such driver model,
 * so none of that machinery can be reused.  What is reused is the part that
 * matters -- the three ARB fragment programs and the edge-classification
 * table -- driven directly from DOSBox's own OpenGL output path.
 *
 * Pipeline (unchanged from upstream):
 *
 *   texture[0]  emulator framebuffer, GL_NEAREST
 *        |  pass 1  (program 0)   ->  FBO 0
 *   texture[1]  edge classification
 *        |  pass 2  (program 1)   ->  FBO 1
 *   texture[2]  interpolation selection
 *        |  pass 3  (program 2)   ->  default framebuffer
 *   samples texture[0] (unit 0), texture[2] (unit 1) and the 3D
 *   interpolation-factor table texture[3] (unit 2)
 *
 * Requires GL_ARB_fragment_program, GL_EXT_framebuffer_object,
 * GL_ARB_multitexture and 3D textures -- all present in the OpenGL 2.1
 * compatibility profile that macOS still ships (verified by tools/glprobe.c).
 *
 * Original shaders and table: Copyright (C) 2004 Jorg Walter, GPL-2.
 * See LICENSE-NOTICE.txt.
 */
#ifndef DOSBOX_OPENGLHQ_H
#define DOSBOX_OPENGLHQ_H

/* True once Init has succeeded; every entry point below is a no-op otherwise,
 * so a caller that ignores the return value still cannot crash. */
bool OpenGLHQ_Active(void);

/* Compile the programs, allocate textures/FBOs and build the interpolation
 * table.  srcw/srch are the emulated resolution; outx/outy/outw/outh are
 * DOSBox's clip rectangle -- the aspect-corrected, possibly letterboxed region
 * of the drawable, NOT the whole window.  Pass 3 restores exactly that
 * viewport, so plain opengl and openglhq put the picture in the same place.
 * Returns false (having cleaned up) if anything is unavailable, which is the
 * caller's cue to fall back to plain output=opengl. */
bool OpenGLHQ_Init(int srcw, int srch, int outx, int outy, int outw, int outh);

/* Rebuild the interpolation table for a new output size.  The table is a
 * function of the source:output scale ratio, so it is NOT resize-invariant --
 * but it costs ~11 ms to build, so this belongs on resize, never per frame. */
void OpenGLHQ_Resize(int outx, int outy, int outw, int outh);

/* Upload `height` rows starting at row `y` of the emulated framebuffer.
 * `pixels` points at the first row to upload; `pitch` is in bytes. */
void OpenGLHQ_UploadRows(const void *pixels, int pitch, int y, int height);

/* Run the three passes and leave the result in the current draw buffer. */
void OpenGLHQ_Render(void);

void OpenGLHQ_Shutdown(void);

/* Diagnostic breadcrumb.  Appends one line to the file named by
 * SDL_OPENGLHQ_PROBE and does nothing at all if that variable is unset, which
 * is every normal run.  sdlmain.cpp calls it at the points where the openglhq
 * path can be abandoned, so verify-bundle.sh can tell WHICH step did not
 * happen instead of only that the scaler never announced itself.
 *
 * Only declared when C_OPENGL is on -- openglhq.cpp is compiled out otherwise,
 * so a call from a #else arm would be a link error rather than a diagnostic. */
/* Called from SDL_SetVideoMode_Wrap immediately BEFORE it calls
 * SDL_SetVideoMode -- i.e. on the one path that really replaces the GL context,
 * at the last moment the old context is still current.
 *
 * Both halves matter.  Its SETMODE_SAVES short-circuit returns the existing
 * surface untouched when nothing changed, so calling this only on the real path
 * means a run of identical GFX_SetSize calls costs openglhq nothing.  And
 * calling it BEFORE the replacement means the objects are deleted against the
 * context that owns them; afterwards their names could belong to DOSBox's own
 * texture or display list in the new context, and deleting would destroy those
 * instead. */
#if C_OPENGL
void OpenGLHQ_ReleaseForContextChange(void);

void OpenGLHQ_ProbeLog(const char *fmt, ...)
#ifdef __GNUC__
	__attribute__((format(printf, 1, 2)))
#endif
	;
#endif

#endif /* DOSBOX_OPENGLHQ_H */
