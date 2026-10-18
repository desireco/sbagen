//
//	sbagenlib - render SBaGen audio in-process
//
//	The CLI binary is built as usual.  A library build compiles the same
//	sbagen.c with -DSBAGEN_LIB, which supplies main() from the embedder
//	rather than from sbagen.c, and exposes the calls below (implemented in
//	engine.c).
//
//	Everything the library does goes through the same parse, period
//	resolution and sample-generation code as the command line, so an
//	in-process render is byte-identical to the equivalent `sbagen -Q -S -W`
//	invocation.  tests/run.sh proves that by comparing the two directly.
//
//	Limitations, deliberately:
//
//	  - error() still exits the process on failure.  Threading error
//	    returns through a 2011 codebase that treats exit as its error
//	    handling is a project of its own; until then the library is
//	    honest about it.
//	  - mix input (-m) and compressed output (-w) are not available
//	    in-process; the library renders 16-bit stereo to memory only.
//	  - the backends (ALSA/OSS, encoder state, the mix reader thread)
//	    remain process-global and are CLI-only; engines themselves are
//	    fully per-instance, so concurrent renders are safe (and tested).
//	  - mix input (-m) is not available in-process.
//
//	Example:
//
//	    short *buf; int nframes;
//	    sbagen_render_immediate("200+10/0.5 pink/0.15",
//				    44100, 5000, 3000, &buf, &nframes);
//	    // buf now holds nframes*2 interleaved 16-bit LE samples:
//	    // 5 seconds at 44100 Hz, 3 second fades.
//	    sbagen_free(buf);
//

#ifndef SBAGENLIB_H
#define SBAGENLIB_H

struct Engine;
#ifdef __cplusplus
extern "C" {
#endif

// Sentinel out_fd value marking the memory sink (no real fd uses it).
#define LIB_SINK_FD (-7777)

// Engine lifecycle.  Each render creates its own engine internally; these
// are exposed for callers that want to drive the parse/render machinery
// themselves.  All engine state is per-instance and thread-local through
// E_current, so engines can be created and rendered concurrently.
struct Engine *engine_new(void);
void engine_init(struct Engine *e);
void engine_free(struct Engine *e);

// Render a tone-set specification (immediate mode, as `sbagen -i`) into
// memory.
//
//   specs     tone-spec string, e.g. "200+10/0.5 pink/0.15"
//   rate      sample rate in Hz (e.g. 44100)
//   len_ms    length to render in milliseconds
//   fade_ms   fade in/out time in milliseconds (as sbagen's -F)
//   out       receives a malloc'd buffer of nframes*2 interleaved 16-bit
//             little-endian samples; free with sbagen_free()
//   nframes   receives the number of sample frames rendered
//
// Returns 0 on success.  On any failure this exits the process (see the
// limitations note above), like the CLI does.  Safe to call concurrently
// from multiple threads: each call runs against its own engine.
int sbagen_render_immediate(const char *specs, int rate, int len_ms,
			    int fade_ms, short **out, int *nframes);

// Free a buffer returned by sbagen_render_immediate().
void sbagen_free(short *buf);

#ifdef __cplusplus
}
#endif

#endif	// SBAGENLIB_H