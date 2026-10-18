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

// The sink lives in the engine (e->lib_sink*), not here: these calls come
// from writeOut() with E_current already pointing at the rendering engine,
// so concurrent renders each fill their own buffer.

// Called from writeOut() when out_fd == LIB_SINK_FD.  A short overrun is an
// internal error -- lib_sink_len is sized above the largest possible render
// -- but silently truncating audio would be worse than dying loudly.
void
sbagen_sink_write(const char *data, int siz) {
  // NB: lib_sink* are Engine fields through the name macros; E_current
  // already points at the rendering engine when writeOut() calls this.
  if (lib_sink_fill + (size_t)siz > lib_sink_len)
    error("Library sink overflow: %zu written + %d exceeds %zu capacity",
	  lib_sink_fill, siz, lib_sink_len);
  memcpy((char*)lib_sink + lib_sink_fill, data, siz);
  lib_sink_fill += siz;
}

void
sbagen_free(short *mem) {
  free(mem);
}

int
sbagen_render_immediate(const char *specs, int rate, int len_ms,
			int fade_ms, short **out, int *nframes) {
  Engine *saved= E_current;
  Engine *e;
  char *av[1];

  if (!specs || !*specs) error("sbagen_render_immediate: empty tone-spec");
  if (rate <= 0 || len_ms <= 0) error("sbagen_render_immediate: bad rate/length");
  if (!out || !nframes) error("sbagen_render_immediate: null out param");

  // Fresh engine per render: the caller gets samples out, and every table
  // the parse allocates (sin table, waves, periods) is freed at the end.
  // E_current is thread-local, so two threads can render concurrently,
  // each against its own engine -- tests/unit_two proves it.
  e= engine_new();
  if (!e) error("sbagen_render_immediate: out of memory for engine");
  E_current= e;

  {	// Machine endianness probe (global, not per-engine)
    static int be_done= 0;
    if (!be_done) {
      short test= 0x1100;
      bigendian= ((char*)&test)[0] != 0;
      be_done= 1;
    }
  }
  init_sin_table();		// Per-engine: allocates e->sin_table, freed by engine_free()

  // The knobs the render reads.  These are normally set by the CLI option
  // parser; the library owns them for the duration of a render.
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
    lib_sink_len= (size_t)out_bps * ((size_t)rate * len_ms / 1000 + 1);
    lib_sink_len= (lib_sink_len + out_bsiz - 1) / out_bsiz * out_bsiz + out_bsiz;
    lib_sink= (short*)Alloc(lib_sink_len);
    lib_sink_fill= 0;
    out_fd= LIB_SINK_FD;
  }

  loop();

  *out= lib_sink;			// Caller owns the samples
  *nframes= (int)(lib_sink_fill / 4);

  // Release everything the parse and render allocated (period ring, name
  // defs, waves, sin table, buffers).  engine_free() memsets the engine;
  // free the shell afterwards and hand E_current back.
  engine_free(e);
  free(e);
  E_current= saved;
  return 0;
}

#endif	// SBAGEN_LIB