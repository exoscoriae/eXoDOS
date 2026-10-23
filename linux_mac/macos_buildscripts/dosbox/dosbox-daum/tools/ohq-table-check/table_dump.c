/* Standalone extraction of OpenGL-HQ's interpolation-table builder.
   Pure math, no GL -- the part that ports verbatim into DOSBox. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <time.h>
#define OHQ_RESOLUTION 16
#include "SDL_openglhq_table.h"

static double sign(double a) {
    return (a < 0?-1:1);
}

/*
 This function calculates what percentage of a rectangle intersected by a line lies near the center of the
 cordinate system. It is mathematically exact, and well-tested for xcenter > 0 and ycenter > 0 (it's only
 used that way). It should be correct for other cases as well, but well... famous last words :)
*/
static double intersect_any(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double g = fabs(gradient)*xsize/ysize;
    double o = -((yoffset-ycenter) + gradient*xcenter)/ysize*sign(ycenter)*sign(yoffset)-g*0.5+0.5;
    double yl = o, yr = o+g, xb = -o/g, xt = (1-o)/g;
    double area = 1.0;

    if (yl >= 1.0) xt = xb = area = 0.0;
    else if (yl > 0.0) {
        area = 1.0-yl;
        xb = 0.0;
    }
    else if (yr <= 0.0) yl = yr = area = 1.0;
    else yl = o+xb*g;

    if (xt <= 0.0) yr = yl = area = 0.0;
    else if (xt < 1.0) {
        area *= xt;
        yr = 1.0;
    }
    else if (xb >= 1.0) xb = xt = area = 1.0;
    else xt = (yr-o)/g;

    area -= (xt-xb)*(yr-yl)/2;

    return area;
}

static double intersect_h(double xcenter, double ycenter, double xsize, double ysize) {
    return fmax(0.0,fmin(1.0,(.55-fabs(xcenter)+xsize/2.0)/xsize));
    //return fmax(0.0,fmin(1.0,(.50-fabs(xcenter)+xsize/2.0)/xsize));
}

static double intersect_any_h(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double hinside = intersect_h(xcenter,ycenter,xsize,ysize);
    return hinside*hinside*intersect_any(xcenter,ycenter,xsize,ysize,yoffset,gradient);
}

static double intersect_v(double xcenter, double ycenter, double xsize, double ysize) {
    return fmax(0.0,fmin(1.0,(.55-fabs(ycenter)+ysize/2.0)/ysize));
    //return fmax(0.0,fmin(1.0,(.50-fabs(ycenter)+ysize/2.0)/ysize));
}

static double intersect_any_v(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double vinside = intersect_v(xcenter,ycenter,xsize,ysize);
    return vinside*vinside*intersect_any(xcenter,ycenter,xsize,ysize,yoffset,gradient);
}

static double intersect_hv(double xcenter, double ycenter, double xsize, double ysize) {
    double hinside = intersect_h(xcenter,ycenter,xsize,ysize);
    double vinside = intersect_v(xcenter,ycenter,xsize,ysize);
    return (1-hinside)*(1-vinside)+hinside*vinside;
}

/* FIXME: not sure if this is correct, but it is rare enough and most likely near enough. fixes welcome :) */
static double intersect_any_hv(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double hvinside = intersect_hv(xcenter,ycenter,xsize,ysize);
    return hvinside*hvinside*intersect_any(xcenter,ycenter,xsize,ysize,yoffset,gradient);
}

static double intersect_hvd(double xcenter, double ycenter, double xsize, double ysize) {
    return intersect_h(xcenter,ycenter,xsize,ysize)*intersect_v(xcenter,ycenter,xsize,ysize);
}

static void setinterp(double xcenter, double ycenter, double percentage_inside, int i1, int i2, int i3, int o1, int o2, int o3, unsigned char *factors) {
    double d0, d1, d2, d3, percentage_outside, totaldistance_i, totaldistance_o;
    xcenter = fabs(xcenter);
    ycenter = fabs(ycenter);
    d0 = (1-xcenter)*(1-ycenter);
    d1 = xcenter*(1-ycenter);
    d2 = (1-xcenter)*ycenter;
    d3 = xcenter*ycenter;
    if (i1 && i2) i3 = 0;
    if (o1 && o2) o3 = 0;
    percentage_outside = 1.0-percentage_inside;
    totaldistance_i = d0+i1*d1+i2*d2+i3*d3;
    totaldistance_o = o1*d1+o2*d2+o3*d3+1e-12; /* +1e-12: prevent division by zero */

    factors[1] = (unsigned char)(((d1/totaldistance_i*percentage_inside*i1)+(d1/totaldistance_o*percentage_outside*o1))*255+.5);
    factors[2] = (unsigned char)(((d2/totaldistance_i*percentage_inside*i2)+(d2/totaldistance_o*percentage_outside*o2))*255+.5);
    factors[3] = (unsigned char)(((d3/totaldistance_i*percentage_inside*i3)+(d3/totaldistance_o*percentage_outside*o3))*255+.5);
    factors[0] = 255-factors[1]-factors[2]-factors[3];/*(unsigned char)((d0/totaldistance_i*percentage_inside)*255+.5);*/
}

/* Wanna have gcc fun? #define this as a macro, get a fast machine and go fetch a coffe or two. See how it is used to get an idea why.
   I aborted compilation after 5 minutes of CPU time on an Athlon64 3700+. */
static int swap_bits(int num, int bit1, int bit2) {
    return ((num & ~(bit1|bit2))|((num&bit1)?bit2:0)|((num&bit2)?bit1:0));
}

/* border bits, transcribed from SDL_ohqthread.h */
#define R 1
#define T 2
#define RT 4
#define RT2 8
#define L 16
#define LB2 32
#define LT2 64
#define LT 128
#define LB 256
#define B 512
#define RB2 1024
#define RB 2048
#define NODIAG 0x90
#define H 1
#define V 2
#define D 4
#define hmirror(p) swap_bits(swap_bits(swap_bits(swap_bits(swap_bits(p,R,L),RT,LT),RT2,LT2),RB,LB),RB2,LB2)
#define vmirror(p) swap_bits(swap_bits(swap_bits(swap_bits(swap_bits(p,T,B),RT,RB),RT2,RB2),LT,LB),LT2,LB2)
#define NO_BORDER(x) ((b&(x)) == 0)
#define IS_BORDER(x) ((b&(x)) == (x))
#define SETINTERP(percentage_inside) setinterp(xcenter,ycenter,percentage_inside, \
                        NO_BORDER(R),NO_BORDER(T),NO_BORDER(RT), \
                        IS_BORDER(R),IS_BORDER(T),IS_BORDER(RT), \
                        texture+((x+(border%16)*OHQ_RESOLUTION+y*16*OHQ_RESOLUTION+(border&~15)*OHQ_RESOLUTION*OHQ_RESOLUTION)*4))
#define adjust 1

int main(void) {
    unsigned char table[4096] = SDL_openglhq_table_dat;
    unsigned char *texture = (unsigned char *)malloc((size_t)OHQ_RESOLUTION*OHQ_RESOLUTION*4096*4);
    int border, x, y;
    /* xsize/ysize are source:output scale -- so this table is a function of the
       output size and must be rebuilt whenever the window is resized. */
    double xsize = 800.0/800.0, ysize = 600.0/600.0;
    clock_t t0;
    if (!texture) return 1;
    t0 = clock();
    memset(texture, 0, (size_t)OHQ_RESOLUTION*OHQ_RESOLUTION*4096*4);

    for (border = 0; border < 4096; border++) {
        for (y = 0; y < OHQ_RESOLUTION; y++) {
            for (x = 0; x < OHQ_RESOLUTION; x++) {
                double xcenter = fabs((((double)x)+.5)/(double)(OHQ_RESOLUTION)-.5)*adjust;
                double ycenter = fabs((((double)y)+.5)/(double)(OHQ_RESOLUTION)-.5)*adjust;
                int sx = (x < OHQ_RESOLUTION/2?-1:1);
                int sy = (y < OHQ_RESOLUTION/2?-1:1);
                int b = (sy > 0?(sx > 0?border:hmirror(border)):(sx > 0?vmirror(border):vmirror(hmirror(border))));

                if ((table[b] & NODIAG) == NODIAG) {
                    if (table[b] & H) {
                        if (table[b] & V) {
                            if (table[b] & D) SETINTERP(intersect_hvd(xcenter,ycenter,xsize,ysize));
                            else SETINTERP(intersect_hv(xcenter,ycenter,xsize,ysize));
                        } else {
                            SETINTERP(intersect_h(xcenter,ycenter,xsize,ysize));
                        }
                    } else if (table[b] & V) {
                        SETINTERP(intersect_v(xcenter,ycenter,xsize,ysize));
                    } else {
                        SETINTERP(1.0);
                    }
                } else {
                    double yoff = (table[b]&4?1:-1)*(((table[b] >> 3) & 3) + 1)/4.0;
                    double grad = (table[b]&32?1:-1)*(((table[b] >> 6) & 3) + 1)/2.0;
                    if (table[b] & H) {
                        if (table[b] & V) {
                            SETINTERP(intersect_any_hv(xcenter,ycenter,xsize,ysize,yoff,grad));
                        } else {
                            SETINTERP(intersect_any_h(xcenter,ycenter,xsize,ysize,yoff,grad));
                        }
                    } else if (table[b] & V) {
                        SETINTERP(intersect_any_v(xcenter,ycenter,xsize,ysize,yoff,grad));
                    } else {
                        SETINTERP(intersect_any(xcenter,ycenter,xsize,ysize,yoff,grad));
                    }
                }

            }
        }
    }

    printf("  build time      : %.0f ms (640x400 -> 1920x1200)\n",
           1000.0*(clock()-t0)/CLOCKS_PER_SEC);
    {
        size_t i, n = (size_t)OHQ_RESOLUTION*OHQ_RESOLUTION*4096*4, nonzero = 0;
        unsigned long sum = 0; int mn = 255, mx = 0;
        for (i = 0; i < n; i++) {
            sum += texture[i];
            if (texture[i] < mn) mn = texture[i];
            if (texture[i] > mx) mx = texture[i];
            if (texture[i]) nonzero++;
        }
        printf("  bytes generated : %zu (%.1f MB)\n", n, n/1048576.0);
        printf("  value range     : %d..%d\n", mn, mx);
        printf("  non-zero        : %zu (%.1f%%)\n", nonzero, 100.0*nonzero/n);
        printf("  checksum        : %lu\n", sum);
        printf("  uploaded as     : %d x %d x %d RGBA8 (%.1f MB)\n",
               16*OHQ_RESOLUTION, OHQ_RESOLUTION, 256,
               16.0*OHQ_RESOLUTION*OHQ_RESOLUTION*256*4/1048576.0);
    }
    { FILE*f=fopen("/tmp/ohq/gen/upstream.bin","wb");
      fwrite(texture,1,(size_t)OHQ_RESOLUTION*OHQ_RESOLUTION*4096*4,f); fclose(f); }
    free(texture);
    return 0;
}
