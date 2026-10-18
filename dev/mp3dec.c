//
//	MP3 decoding using libMAD
//
//      (c) 1999-2004 Jim Peters <jim@uazu.net>.  All Rights Reserved.
//      For latest version see http://sbagen.sf.net/ or
//      http://uazu.net/sbagen/.  Released under the GNU GPL version 2.
//

#define SBAGEN_ENGINE_NAMES_OFF
#include "engine_names.h"
#include "libs/mad.h"
#undef SBAGEN_ENGINE_NAMES_OFF
#include "engine_names.h"


// NB: this file is included by sbagen.c AFTER the Engine name macros.
// mp3_read runs on the inbuf producer thread, where the __thread E_current
// is 0, so it must not touch engine state: it reads mix_fp (captured from
// e->mix_in by main) and reports the stream rate through the captured
// pointers below instead of writing e->out_rate directly.
extern void *Alloc(size_t);
extern void error(char *fmt, ...);

static int *mp3_ratep, *mp3_ratedefp;	// -> e->out_rate / e->out_rate_def

int mp3_read(int *dst, int dlen);

static struct mad_stream stream;
static struct mad_frame frame;
static struct mad_synth synth;
static char *mp3_buf;
static int mp3_len;
static int synth_extra;		// Extra samples carried over from previous frame

void 
mp3_init() {
   mp3_len= 32768;
   mp3_buf= (char*)Alloc(mp3_len);

   // Setup MAD decoder
   mad_stream_init(&stream);
   mad_frame_init(&frame);
   mad_synth_init(&synth);
   mad_stream_options(&stream, 0);

   // Force first data read
   stream.error= MAD_ERROR_BUFLEN;
   synth_extra= 0;

   mp3_ratep= &out_rate;		// Engine fields, captured for the thread
   mp3_ratedefp= &out_rate_def;
   inbuf_start(mp3_read, 256*1024);	// 1024K buffer: 3s@44.1kHz
}

void 
mp3_term() {
   mad_synth_finish(&synth);
   mad_frame_finish(&frame);
   mad_stream_finish(&stream);
   free(mp3_buf);
}


// Limiting and truncation to 20 bits
#define ROUND(xx) ((((xx)<-MAD_F_ONE) ? -MAD_F_ONE : 	\
		    ((xx)>=MAD_F_ONE) ? MAD_F_ONE-1 : 	\
		    (xx)) >> (MAD_F_FRACBITS-15-4))

int 
mp3_read(int *dst, int dlen) {
   int *dst0= dst;
   int cnt, a, val;

   //debug("mp3_read %d", dlen);

   while (dlen > 0) {
      // First use up any samples from previous synth frame
      if (synth_extra > 0) {
	 cnt= dlen/2;
	 if (cnt > synth_extra) cnt= synth_extra;
	 for (a= 0; a<cnt; a++) {
	    int ii= synth.pcm.length - synth_extra--;
	    val= synth.pcm.samples[0][ii]; *dst++= ROUND(val);
	    // libmad only fills samples[1] for joint-stereo/dual-channel input.
	    // For a mono stream it is left untouched, so reading it yields
	    // whatever was in that buffer -- which put noise in one ear.  Mirror
	    // channel 0 instead, which is what a mono source means anyway.
	    val= (2 == synth.pcm.channels) ? synth.pcm.samples[1][ii]
					  : synth.pcm.samples[0][ii];
	    *dst++= ROUND(val);
	    dlen -= 2;
	 }
	 continue;
      }

      // Load up more MP3 data from disk if required
      if (stream.error == MAD_ERROR_BUFLEN) {
	 char *rp= mp3_buf;

	 // Preserve start of last frame
	 if (stream.next_frame) {
	    cnt= stream.bufend - stream.next_frame;
	    memmove(mp3_buf, stream.next_frame, cnt);
	    rp += cnt;
	 }
	 
	 // Fill buffer
	 cnt= fread(rp, 1, mp3_buf + mp3_len - rp, mix_fp);
	 if (cnt == 0) {
	    if (feof(mix_fp))
	       return dst-dst0;
	    error("Read error on MP3 input stream:\n  %s", strerror(errno));
	 }
	 rp += cnt;

	 mad_stream_buffer(&stream, (const unsigned char*)mp3_buf, rp - mp3_buf);
	 stream.error= 0;
      }

      // Decode frame
      if (mad_frame_decode(&frame, &stream)) {	 
	 if (MAD_RECOVERABLE(stream.error)) {
	    warn("MAD recoverable error: %s", mad_stream_errorstr(&stream));
	    continue;
	 }
	 if (stream.error == MAD_ERROR_BUFLEN) 
	    continue;
	 error("Fatal error decoding MP3 stream: %s", 
	       mad_stream_errorstr(&stream));
      }

      // Pickup sampling rate if not picked up yet.  NB through the captured
      // pointers: this runs on the reader thread (see note above).
      if (*mp3_ratedefp) {
	 *mp3_ratep= frame.header.samplerate;
	 *mp3_ratedefp= 0;
      }
      
      // Synthesize frame into samples
      mad_synth_frame(&synth, &frame);
      synth_extra= synth.pcm.length;
   }
   return dst-dst0;
}

// END //
