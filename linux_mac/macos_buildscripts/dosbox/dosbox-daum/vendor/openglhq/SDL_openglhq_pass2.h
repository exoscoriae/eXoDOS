#define SDL_openglhq_pass2_fp \
"!!ARBfp1.0\n" \
"TEMP pixel0, pixel1, pixel2, pixel3;\n" \
"TEMP max;\n" \
"ALIAS coord0 = pixel0;\n" \
"ALIAS coord1 = pixel1;\n" \
"ALIAS coord2 = pixel2;\n" \
"TEMP min;\n" \
"TEMP current_trigger;\n" \
"PARAM pixel_size = program.env[0];\n" \
"PARAM trigger = program.local[0];\n" \
"ATTRIB coord3 = fragment.texcoord[0];\n" \
"PARAM coordmask = { 0, -1, 0, .0625 };\n" \
"PARAM factors = {  0.0627450980392157,  0.125490196078431,  0.250980392156863,   0.501960784313725 };\n" \
"PARAM const = { 65536, 0.1666666666666666, 1, 0 };\n" \
"ALIAS one_sixteenth = coordmask;\n" \
"SUB coord0.xy, coord3, pixel_size;\n" \
"MAD coord1.xy, pixel_size.x, coordmask, coord3;\n" \
"MAD coord2.xy, pixel_size.x, coordmask.gbra, coord3;\n" \
"TEX pixel0, coord0, texture[0], 2D;\n" \
"TEX pixel1, coord1, texture[0], 2D;\n" \
"TEX pixel2, coord2, texture[0], 2D;\n" \
"TEX pixel3, coord3, texture[0], 2D;\n" \
"MOV pixel1.r, pixel0.b;\n" \
"MOV pixel2.g, pixel0.a;\n" \
"ADD min, pixel1, pixel2;\n" \
"ADD min, min, pixel3;\n" \
"DP3 current_trigger.a, min, const.g;\n" \
"MUL_SAT current_trigger.a, current_trigger.a, trigger.a;\n" \
"MAX current_trigger.a, current_trigger.a, trigger.r;\n" \
"MUL current_trigger.a, current_trigger.a, const.r;\n" \
"MAD_SAT pixel1, pixel1, const.r, -current_trigger.a;\n" \
"MAD_SAT pixel2, pixel2, const.r, -current_trigger.a;\n" \
"MAD_SAT pixel3, pixel3, const.r, -current_trigger.a;\n" \
"DP4 result.color.a, pixel3, factors;\n" \
"MAD pixel2, pixel2, one_sixteenth.a, pixel1;\n" \
"DP4 result.color.rgb, pixel2, factors;\n" \
"END\n" \

