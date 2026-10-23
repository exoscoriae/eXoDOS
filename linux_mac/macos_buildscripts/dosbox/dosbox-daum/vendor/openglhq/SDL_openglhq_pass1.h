#define SDL_openglhq_pass1_fp \
"!!ARBfp1.0\n" \
"TEMP pixel0, pixel1, pixel2, pixel3;\n" \
"ALIAS coord1 = pixel1;\n" \
"ALIAS coord2 = pixel2;\n" \
"ALIAS coord3 = pixel3;\n" \
"ALIAS rmean = pixel3;\n" \
"TEMP diff;\n" \
"PARAM pixel_size = program.env[0];\n" \
"ATTRIB coord0 = fragment.texcoord[0];\n" \
"OUTPUT res = result.color;\n" \
"PARAM coordmask = { 1, 0, 1, 0 };\n" \
"PARAM weight = { 1.884313725490196078431372549, 3.768627450980392156862745098, 2.822790287990196078431372548, 0 };\n" \
"PARAM mask = { 0.4710784313725490196078431372, 0, -0.4710784313725490196078431372, 0 };\n" \
"MAD coord1.xy, pixel_size, coordmask, coord0;\n" \
"MAD coord2.xy, pixel_size, coordmask.gbra, coord0;\n" \
"ADD coord3.xy, pixel_size, coord0;\n" \
"TEX pixel0.rgb, coord0, texture[0], 2D;\n" \
"TEX pixel1.rgb, coord1, texture[0], 2D;\n" \
"TEX pixel2.rgb, coord2, texture[0], 2D;\n" \
"TEX pixel3.rgb, coord3, texture[0], 2D;\n" \
"SUB diff.rgb, pixel0, pixel3;\n" \
"ADD rmean.a, pixel0.r, pixel3.r;\n" \
"MAD rmean.rgb, rmean.a, mask, weight;\n" \
"MUL diff.rgb, diff, diff;\n" \
"DP3_SAT res.b, rmean, diff;\n" \
"SUB diff.rgb, pixel0, pixel1;\n" \
"ADD rmean.a, pixel0.r, pixel1.r;\n" \
"MAD rmean.rgb, rmean.a, mask, weight;\n" \
"MUL diff.rgb, diff, diff;\n" \
"DP3_SAT res.r, rmean, diff;\n" \
"SUB diff.rgb, pixel0, pixel2;\n" \
"ADD rmean.a, pixel0.r, pixel2.r;\n" \
"MAD rmean.rgb, rmean.a, mask, weight;\n" \
"MUL diff.rgb, diff, diff;\n" \
"DP3_SAT res.g, rmean, diff;\n" \
"SUB diff.rgb, pixel1, pixel2;\n" \
"ADD rmean.a, pixel1.r, pixel2.r;\n" \
"MAD rmean.rgb, rmean.a, mask, weight;\n" \
"MUL diff.rgb, diff, diff;\n" \
"DP3_SAT res.a, rmean, diff;\n" \
"END\n" \

