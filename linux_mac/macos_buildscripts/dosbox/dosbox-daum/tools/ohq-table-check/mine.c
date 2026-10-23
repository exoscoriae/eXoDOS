#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define OHQ_RESOLUTION 16
#include "SDL_openglhq_table.h"
static struct { int srcw, srch; } ohq = { 800, 600 };
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

/* border bits */
#define OHQ_R 1
#define OHQ_T 2
#define OHQ_RT 4
#define OHQ_RT2 8
#define OHQ_L 16
#define OHQ_LB2 32
#define OHQ_LT2 64
#define OHQ_LT 128
#define OHQ_LB 256
#define OHQ_B 512
#define OHQ_RB2 1024
#define OHQ_RB 2048
#define OHQ_NODIAG 0x90
#define OHQ_H 1
#define OHQ_V 2
#define OHQ_D 4

#define ohq_hmirror(p) swap_bits(swap_bits(swap_bits(swap_bits(swap_bits(p,OHQ_R,OHQ_L),OHQ_RT,OHQ_LT),OHQ_RT2,OHQ_LT2),OHQ_RB,OHQ_LB),OHQ_RB2,OHQ_LB2)
#define ohq_vmirror(p) swap_bits(swap_bits(swap_bits(swap_bits(swap_bits(p,OHQ_T,OHQ_B),OHQ_RT,OHQ_RB),OHQ_RT2,OHQ_RB2),OHQ_LT,OHQ_LB),OHQ_LT2,OHQ_LB2)
#define NO_BORDER(x) ((b & (x)) == 0)
#define IS_BORDER(x) ((b & (x)) == (x))

int main(void)
{
    unsigned char table[4096] = SDL_openglhq_table_dat;
    const size_t bytes = (size_t)OHQ_RESOLUTION * OHQ_RESOLUTION * 4096 * 4;
    unsigned char *texture = (unsigned char *)malloc(bytes);
    double xsize, ysize;
    int border, x, y;

    if (!texture) return 1;
    memset(texture, 0, bytes);

    /* Scale ratio: this is why the table is not resize-invariant. */
    xsize = (double)ohq.srcw / (double)800;
    ysize = (double)ohq.srch / (double)600;

    for (border = 0; border < 4096; border++) {
        for (y = 0; y < OHQ_RESOLUTION; y++) {
            for (x = 0; x < OHQ_RESOLUTION; x++) {
                double xcenter = fabs((((double)x) + .5) / (double)OHQ_RESOLUTION - .5);
                double ycenter = fabs((((double)y) + .5) / (double)OHQ_RESOLUTION - .5);
                int sx = (x < OHQ_RESOLUTION / 2 ? -1 : 1);
                int sy = (y < OHQ_RESOLUTION / 2 ? -1 : 1);
                int b = (sy > 0 ? (sx > 0 ? border : ohq_hmirror(border))
                                : (sx > 0 ? ohq_vmirror(border)
                                          : ohq_vmirror(ohq_hmirror(border))));
                unsigned char *factors = texture +
                    ((x + (border % 16) * OHQ_RESOLUTION +
                      y * 16 * OHQ_RESOLUTION +
                      (border & ~15) * OHQ_RESOLUTION * OHQ_RESOLUTION) * 4);
                double pct;

                if ((table[b] & OHQ_NODIAG) == OHQ_NODIAG) {
                    if (table[b] & OHQ_H) {
                        if (table[b] & OHQ_V)
                            pct = (table[b] & OHQ_D) ? intersect_hvd(xcenter, ycenter, xsize, ysize)
                                                     : intersect_hv (xcenter, ycenter, xsize, ysize);
                        else
                            pct = intersect_h(xcenter, ycenter, xsize, ysize);
                    } else if (table[b] & OHQ_V) {
                        pct = intersect_v(xcenter, ycenter, xsize, ysize);
                    } else {
                        pct = 1.0;
                    }
                } else {
                    double yoff = (table[b] &  4 ? 1 : -1) * (((table[b] >> 3) & 3) + 1) / 4.0;
                    double grad = (table[b] & 32 ? 1 : -1) * (((table[b] >> 6) & 3) + 1) / 2.0;
                    if (table[b] & OHQ_H) {
                        pct = (table[b] & OHQ_V)
                            ? intersect_any_hv(xcenter, ycenter, xsize, ysize, yoff, grad)
                            : intersect_any_h (xcenter, ycenter, xsize, ysize, yoff, grad);
                    } else if (table[b] & OHQ_V) {
                        pct = intersect_any_v(xcenter, ycenter, xsize, ysize, yoff, grad);
                    } else {
                        pct = intersect_any(xcenter, ycenter, xsize, ysize, yoff, grad);
                    }
                }
                setinterp(xcenter, ycenter, pct,
                          NO_BORDER(OHQ_R), NO_BORDER(OHQ_T), NO_BORDER(OHQ_RT),
                          IS_BORDER(OHQ_R), IS_BORDER(OHQ_T), IS_BORDER(OHQ_RT),
                          factors);
            }
        }
    }


    { FILE*f=fopen("/tmp/ohq/gen/mine.bin","wb");
      fwrite(texture,1,(size_t)OHQ_RESOLUTION*OHQ_RESOLUTION*4096*4,f); fclose(f); }
    free(texture);
    return 0;
}
