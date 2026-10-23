#define SDL_openglhq_pass3_fp \
"!!ARBfp1.0\n" \
"TEMP coord1, coord2, coord3, pixel0;\n" \
"ALIAS pixel1 = coord1;\n" \
"ALIAS pixel2 = coord2;\n" \
"ALIAS pixel3 = coord3;\n" \
"TEMP diff;\n" \
"TEMP center_offset;\n" \
"TEMP factors;\n" \
"PARAM pixel_size = program.env[0];\n" \
"PARAM const = { .0625, .5, .99609375, .001953125 };\n" \
"ATTRIB coord0 = fragment.texcoord[0];\n" \
"PARAM cap = program.env[1];\n" \
"TEX diff, coord0, texture[1], 2D;\n" \
"MUL center_offset.xy, coord0, pixel_size.abgr;\n" \
"FRC center_offset.xy, center_offset;\n" \
"SUB coord3.xy, center_offset, const.g;\n" \
"CMP coord3.xy, coord3, -pixel_size, pixel_size;\n" \
"ADD coord3.xy, coord0, coord3;\n" \
"MOV coord1.x, coord3;\n" \
"MOV coord1.y, coord0;\n" \
"MOV coord2.x, coord0;\n" \
"MOV coord2.y, coord3;\n" \
"MAD_SAT center_offset.xy, center_offset, cap.r, cap.g;\n" \
"MAD center_offset.xy, center_offset, cap.b, cap.a;\n" \
"MAD center_offset.x, center_offset, const, diff.a;\n" \
"MAD center_offset.z, diff, const.b, const.a;\n" \
"TEX pixel0, coord0, texture[0], 2D;\n" \
"TEX pixel1, coord1, texture[0], 2D;\n" \
"TEX pixel2, coord2, texture[0], 2D;\n" \
"TEX pixel3, coord3, texture[0], 2D;\n" \
"TEX factors, center_offset, texture[2], 3D;\n" \
"MUL pixel0, pixel0, factors.r;\n" \
"MAD pixel0, pixel1, factors.g, pixel0;\n" \
"MAD pixel0, pixel2, factors.b, pixel0;\n" \
"MAD result.color, pixel3, factors.a, pixel0;\n" \
"END\n" \

