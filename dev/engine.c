//
//	sbagenlib implementation.  Included at the end of sbagen.c under
//	-DSBAGEN_LIB, after all the state it drives; see sbagenlib.h for the
//	public contract.
//
//	The render path is deliberately the CLI's own: readSeqImm() builds the
//	same Period ring that `-i` builds, correctPeriods() resolves it the
//	same way, and loop()/corrVal()/outChunk() generate the same samples
//	into the same out_buf.  The only difference is where writeOut()
//	delivers bytes -- a caller-supplied buffer instead of a file.  That is
//	what makes the byte-identity test in tests/run.sh meaningful: if the
//	library ever diverges from the CLI, the test catches it.
//

#ifdef SBAGEN_LIB

#include <string.h>
#include "sbagenlib.h"

static short *sink_buf;			// caller's samples
static size_t sink_len;			// capacity in bytes
static size_t sink_fill;		// bytes written so far

// Called from writeOut() when out_fd == LIB_SINK_FD.  A short overrun is an
// internal error -- sink_len is sized above the largest possible render --
// but silently truncating audio would be worse than dying loudly.
void
sbagen_sink_write(const char *buf, int siz) {
  if (sink_fill + (size_t)siz > sink_len)
    error("Library sink overflow: %zu written + %d exceeds %zu capacity",
	  sink_fill, siz, sink_len);
  memcpy((char*)sink_buf + sink_fill, buf, siz);
  sink_fill += siz;
}

void
sbagen_free(short *buf) {
  free(buf);
}

int
sbagen_render_immediate(const char *specs, int rate, int len_ms,
			int fade_ms, short **out, int *nframes) {
  static int inited= 0;
  char *av[1];

  if (!specs || !*specs) error("sbagen_render_immediate: empty tone-spec");
  if (rate <= 0 || len_ms <= 0) error("sbagen_render_immediate: bad rate/length");
  if (!out || !nframes) error("sbagen_render_immediate: null out param");

  // One-time setup mirroring main(): endianness probe and the sine table.
  // init_sin_table() allocates, so it must not run twice.
  if (!inited) {
    short test= 0x1100;
    bigendian= ((char*)&test)[0] != 0;
    init_sin_table();
    inited= 1;
  }

  // Reset the knobs the render reads.  These are normally set by the CLI
  // option parser; the library owns them for the duration of a render.
  out_rate= rate;
  out_rate_def= 0;
  out_mode= 1;				// 16-bit
  out_prate= 10;			// parameter-update rate, as default -R
  fade_int= fade_ms;
  opt_Q= 1;				// never print status
  opt_S= 1;				// render from time 0, not wall clock
  if (!fast_mult) fast_mult= 1;
  opt_L= len_ms;			// loop() turns this into byte_count
  opt_E= 0;
  opt_D= 0;
  opt_W= 0;
  opt_w= 0;
  opt_T= -1;

  // Parse the tone-specs exactly as `sbagen -i ...` would.  readSeqImm()
  // writes an "immediate: ..." name-def plus a 00:00 time-line, so
  // fast_tim0/fast_tim1 end up at 0 and loop()'s `now` starts there.
  av[0]= (char*)specs;
  readSeqImm(1, av);

  // NB: main() owns this call for the CLI (it was moved out of the readers
  // to fix '-i' inside a sequence file); the library is main() here, so it
  // owns the call too.
  correctPeriods();

  // Size the sink before loop() runs.  Must mirror setup_device()'s buffer
  // arithmetic: blen is rounded down to a power of two, and the final
  // partial block is written whole, so capacity is the exact byte_count
  // rounded up to a whole number of out_bsiz blocks plus one block of
  // headroom.
  {
    int blen= rate * 2 / out_prate;
    while (blen & (blen-1)) blen &= blen-1;
    out_bsiz= blen * 2;			// out_mode 1: 2 bytes per sample
    out_bps= 4;				// 16-bit stereo
    sink_len= (size_t)out_bps * ((size_t)rate * len_ms / 1000 + 1);
    sink_len= (sink_len + out_bsiz - 1) / out_bsiz * out_bsiz + out_bsiz;
    sink_buf= (short*)Alloc(sink_len);
    sink_fill= 0;
    out_fd= LIB_SINK_FD;
  }

  loop();

  // Release the render buffers the loop allocated; the sink belongs to the
  // caller.  A second render re-allocates them.
  free(out_buf); out_buf= 0;
  free(tmp_buf); tmp_buf= 0;
  out_fd= -1;

  *out= sink_buf;
  *nframes= (int)(sink_fill / 4);
  return 0;
}

#endif	// SBAGEN_LIB