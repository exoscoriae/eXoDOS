/* glprobe.c -- does this Mac still expose what OpenGL-HQ needs?
 *
 * OpenGL-HQ is built on ARB_fragment_program (the pre-GLSL assembly shader
 * extension), EXT_framebuffer_object, multitexturing and 3D textures.  All of
 * those live in OpenGL 2.1's compatibility profile, which Apple deprecated but
 * still ships.  If they are present the three .fp programs port across
 * unchanged; if not they have to be rewritten in GLSL, which is a much larger
 * and riskier job.
 *
 * Uses CGL directly so it needs no SDL and no window server session.
 *
 *   clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
 *         -framework OpenGL -o glprobe tools/glprobe.c && ./glprobe
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <stdio.h>
#include <string.h>

static int has(const char *ext, const char *name)
{
    const char *p = ext;
    size_t n = strlen(name);
    while ((p = strstr(p, name)) != NULL) {
        if ((p == ext || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0'))
            return 1;
        p += n;
    }
    return 0;
}

int main(void)
{
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAAccelerated,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pix = NULL;
    GLint npix = 0;
    CGLContextObj ctx = NULL;

    if (CGLChoosePixelFormat(attrs, &pix, &npix) != kCGLNoError || pix == NULL) {
        printf("  FAIL  could not choose a pixel format\n");
        return 1;
    }
    if (CGLCreateContext(pix, NULL, &ctx) != kCGLNoError || ctx == NULL) {
        printf("  FAIL  could not create a GL context\n");
        CGLDestroyPixelFormat(pix);
        return 1;
    }
    CGLSetCurrentContext(ctx);

    const char *ver = (const char *)glGetString(GL_VERSION);
    const char *ren = (const char *)glGetString(GL_RENDERER);
    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    printf("  renderer   %s\n", ren ? ren : "?");
    printf("  version    %s\n", ver ? ver : "?");
    if (!ext) {
        printf("  FAIL  no extension string (core profile?)\n");
        return 1;
    }

    static const char *need[] = {
        "GL_ARB_fragment_program",       /* the three .fp passes          */
        "GL_EXT_framebuffer_object",     /* render-to-texture, passes 1-2 */
        "GL_ARB_multitexture",           /* pass 3 samples two units      */
        "GL_ARB_texture_non_power_of_two",
        "GL_EXT_paletted_texture",       /* optional fast path only       */
    };
    int required_missing = 0;
    for (unsigned i = 0; i < sizeof(need)/sizeof(*need); i++) {
        int ok = has(ext, need[i]);
        int optional = (i == 4);
        printf("  %-4s %s%s\n", ok ? "ok" : (optional ? "--" : "MISS"),
               need[i], optional ? "  (optional)" : "");
        if (!ok && !optional) required_missing++;
    }

    GLint units = 0, tex3d = 0;
    glGetIntegerv(GL_MAX_TEXTURE_UNITS, &units);
    glGetIntegerv(GL_MAX_3D_TEXTURE_SIZE, &tex3d);
    printf("  texture units %d, max 3D texture %d\n", (int)units, (int)tex3d);

    printf("\n  %s\n", required_missing == 0
           ? "VERDICT: OpenGL-HQ can be ported with its original ARB programs."
           : "VERDICT: required extensions missing -- the shaders need a GLSL rewrite.");

    CGLSetCurrentContext(NULL);
    CGLDestroyContext(ctx);
    CGLDestroyPixelFormat(pix);
    return required_missing ? 2 : 0;
}
