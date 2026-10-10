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
//	  - one engine per process.  The parse/render core still works from
//	    file-scope state; the sink and the library entry points are
//	    re-entrant enough for one render at a time, which is what an
//	    embedder realistically does (render a sequence, get samples).
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

#ifdef __cplusplus
extern "C" {
#endif

// Sentinel out_fd value marking the memory sink (no real fd uses it).
#define LIB_SINK_FD (-7777)

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
// limitations note above), like the CLI does.
int sbagen_render_immediate(const char *specs, int rate, int len_ms,
			    int fade_ms, short **out, int *nframes);

// Free a buffer returned by sbagen_render_immediate().
void sbagen_free(short *buf);

#ifdef __cplusplus
}
#endif

#endif	// SBAGENLIB_H