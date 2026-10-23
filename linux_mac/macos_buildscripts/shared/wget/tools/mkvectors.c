/* Write a test payload and one compressed copy per HTTP Content-Encoding that
 * wget2 can decode.  Used by test.sh to check every decompressor in the
 * bundle.  usage: mkvectors OUTDIR */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <zlib.h>
#include <bzlib.h>
#include <lzma.h>
#include <brotli/encode.h>
#include <zstd.h>
#include <lzlib.h>

static const char *outdir;

static void die(const char *what)
{
	fprintf(stderr, "mkvectors: %s failed\n", what);
	exit(1);
}

static void put(const char *name, const void *data, size_t len)
{
	char path[4096];
	FILE *f;

	snprintf(path, sizeof(path), "%s/%s", outdir, name);
	if (!(f = fopen(path, "wb")) || fwrite(data, 1, len, f) != len || fclose(f) != 0)
		die(path);
}

int main(int argc, char **argv)
{
	size_t len = 300000, i, outlen;
	unsigned char *in, *out;
	uint32_t x = 2463534242u;

	if (argc != 2)
		return 2;
	outdir = argv[1];

	/* deterministic, compressible but not trivial text */
	in = malloc(len);
	for (i = 0; i < len; i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		in[i] = (i % 61 == 60) ? '\n' : "abcdefghij klmnop QRSTUV 0123456789"[x % 35];
	}
	put("payload.txt", in, len);
	out = malloc(len * 2 + 65536);

	{ /* gzip */
		z_stream z;
		memset(&z, 0, sizeof(z));
		if (deflateInit2(&z, 9, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) die("deflateInit2");
		z.next_in = in; z.avail_in = (uInt) len; z.next_out = out; z.avail_out = (uInt) (len * 2);
		if (deflate(&z, Z_FINISH) != Z_STREAM_END) die("deflate");
		put("payload.gz", out, z.total_out);
		deflateEnd(&z);
	}
	{ /* deflate (zlib format, as used by HTTP "deflate") */
		uLongf zl = (uLongf) (len * 2);
		if (compress2(out, &zl, in, (uLong) len, 9) != Z_OK) die("compress2");
		put("payload.deflate", out, zl);
	}
	{ /* bzip2 */
		unsigned int bl = (unsigned int) (len * 2);
		if (BZ2_bzBuffToBuffCompress((char *) out, &bl, (char *) in, (unsigned int) len, 9, 0, 0) != BZ_OK) die("bzip2");
		put("payload.bz2", out, bl);
	}
	{ /* xz */
		size_t pos = 0;
		if (lzma_easy_buffer_encode(6, LZMA_CHECK_CRC64, NULL, in, len, out, &pos, len * 2) != LZMA_OK) die("xz");
		put("payload.xz", out, pos);
	}
	{ /* brotli */
		outlen = len * 2;
		if (!BrotliEncoderCompress(9, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_TEXT, len, in, &outlen, out)) die("brotli");
		put("payload.br", out, outlen);
	}
	{ /* zstd */
		outlen = ZSTD_compress(out, len * 2, in, len, 19);
		if (ZSTD_isError(outlen)) die("zstd");
		put("payload.zst", out, outlen);
	}
	{ /* lzip */
		struct LZ_Encoder *e = LZ_compress_open(1 << 20, 36, INT64_MAX);
		size_t done = 0, got = 0;
		int n, finishing = 0;
		if (!e || LZ_compress_errno(e) != LZ_ok) die("LZ_compress_open");
		while (!LZ_compress_finished(e)) {
			if (done < len) {
				int room = LZ_compress_write_size(e);
				if (room > 0) {
					size_t chunk = len - done < (size_t) room ? len - done : (size_t) room;
					if ((n = LZ_compress_write(e, in + done, (int) chunk)) < 0) die("LZ_compress_write");
					done += (size_t) n;
				}
			}
			if (done == len && !finishing) {
				if (LZ_compress_finish(e) < 0) die("LZ_compress_finish");
				finishing = 1;
			}
			if ((n = LZ_compress_read(e, out + got, 65536)) < 0) die("LZ_compress_read");
			got += (size_t) n;
		}
		LZ_compress_close(e);
		put("payload.lz", out, got);
	}
	return 0;
}
