//
//	FLAC and Opus encoding for file/stdout output.
//
//	SBaGen 1.4.5 could only write raw audio and RIFF/WAV, which works out at
//	about 0.6 GB per hour of 16-bit stereo.  That is impractical for the long
//	sessions this program is for -- a 21:00-to-07:00 sleep session is over
//	6 GB, past both the 4 GB WAV ceiling and anyone's patience with ffmpeg
//	one-liners.
//
//	These encoders sit behind the same writeOut() choke point as everything
//	else, so the samples handed to them are the same ones the WAV path would
//	write.  tests/run.sh verifies that by decoding the result back and
//	comparing against the WAV render.
//
//	FLAC is lossless and accepts any rate, so it is the default when you want
//	to keep exactly what sbagen produced.
//
//	Opus only accepts 8/12/16/24/48 kHz and always encodes in whole frames.
//	Rather than resample, the rate is raised to 48 kHz *before* the DSP runs:
//	out_rate drives the oscillator increments in corrVal(), so generating at
//	48 kHz natively produces the identical waveform at the higher rate.  That
//	is lossless in the only sense that matters here -- there is no filtering
//	and no aliasing -- and it is simpler than a resampler.  Asking for 8 kHz
//	via -r would still need resampling, so that is refused rather than
//	silently mangled.
//
//	Opus also needs a fixed frame size, so samples accumulate until a whole
//	20 ms frame is ready.
//

#include <FLAC/stream_encoder.h>
#include <opus/opus.h>

// Ogg container, for Opus.  Raw Opus packets have no framing at all -- a
// decoder cannot tell where one packet ends and the next begins, so a raw
// .opus file is unplayable.  libopusfile has no write API (it is a decoder
// library), so the Ogg container is written directly here.  Only the subset
// needed is used: serial header, two comment headers, then one audio page
// per packet.
//
// NB: this uses the *system* libogg rather than the copy built by
// tests/build-codecs.sh for the Vorbis decoder.  The Opus path must work on a
// clean checkout without running 'make codecs', and libogg is present on any
// system that has libopus, so -w opus never depends on the decoder libraries.
#ifdef HAVE_OGG_SYSTEM
#include <ogg/ogg.h>
#else
#include "libs64/ogg.h"
#endif

#define OGG_HEAD_SERIAL   0x524F4747u	// 'ROGG' as a CRC seed

// Output container selected by the -w option.
enum { ENC_NONE= 0, ENC_FLAC, ENC_OPUS };

static int enc_kind= ENC_NONE;

#ifdef HAVE_FLAC
static FLAC__StreamEncoder *flac_enc;
#endif

#ifdef HAVE_OPUS
static OpusEncoder *opus_enc;
#define OPUS_FRAME_MS     20
#define OPUS_MAX_RATE     48000
static int opus_frame_samples= OPUS_FRAME_MS * OPUS_MAX_RATE / 1000;
static float *opus_frame;			// interleaved, opus_frame_samples*2
static int opus_fill;				// samples buffered so far

// Ogg Opus state
static ogg_stream_state ogg_os;
static int ogg_os_ready= 0;
static int ogg_headers_done= 0;
static int ogg_eos= 0;
static ogg_int64_t ogg_granule;			// samples encoded so far
static unsigned char *ogg_pkt;
static int ogg_pkt_len;
#endif

// ---------------------------------------------------------------------------
// FLAC
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Opus
// ---------------------------------------------------------------------------

#ifdef HAVE_OPUS
// Queue an Ogg page and write it out.  Every audio page is marked
// BOS-less/continued as appropriate and carries the running granule position,
// which is what makes an Ogg Opus stream seekable.
static void
ogg_flush_page(FILE *fp) {
  ogg_page og;
  if (ogg_stream_flush(&ogg_os, &og) != 1) return;
  if (fwrite(og.header, 1, og.header_len, fp) != (size_t)og.header_len ||
      fwrite(og.body, 1, og.body_len, fp) != (size_t)og.body_len)
    error("Short write to Opus output");
}

// Emit one header packet.  Three are required: OpusHead, OpusTags, then a
// third which is optional in the spec but which libopusfile and ffmpeg both
// expect, so all three are written.
static void
ogg_write_header(FILE *fp, const unsigned char *pkt, int len, int first) {
  ogg_packet op;
  memset(&op, 0, sizeof(op));
  op.packet= (unsigned char*)pkt;
  op.bytes= len;
  op.b_o_s= first;
  op.e_o_s= 0;
  op.granulepos= 0;
  op.packetno= ogg_stream_packetin(&ogg_os, &op);
  ogg_flush_page(fp);
}

static void
ogg_write_headers(FILE *fp) {
  unsigned char head[19];
  unsigned char tags[8+23+4];
  int n;

  // OpusHead: "OpusHead", version 1, channels, pre-skip, input rate,
  // output gain, mapping family.
  memcpy(head, "OpusHead", 8);
  head[8] = 1;				// version
  head[9] = 2;				// channel count
  head[10]= 0; head[11]= 312;		// pre-skip, little-endian
  head[12]= (unsigned char)(OPUS_MAX_RATE & 0xff);
  head[13]= (unsigned char)((OPUS_MAX_RATE >> 8) & 0xff);
  head[14]= (unsigned char)((OPUS_MAX_RATE >> 16) & 0xff);
  head[15]= (unsigned char)((OPUS_MAX_RATE >> 24) & 0xff);
  head[16]= 0; head[17]= 0;		// output gain
  head[18]= 0;				// channel mapping family 0
  ogg_write_header(fp, head, sizeof(head), 1);

  // OpusTags: vendor string and a comment count of zero.
  memcpy(tags, "OpusTags", 8);
  n= 0;
  memcpy(tags+8+n, "SBaGen", 5); n+= 5;	// vendor length
  tags[8+n]= 0; n+= 4;			// user comment list length

  ogg_write_header(fp, tags, 8+n, 0);
  ogg_headers_done= 1;
}

static void
opus_emit(FILE *fp, int eos) {
  unsigned char pkt[4000];
  ogg_packet op;
  int n;

  // opus_encode_float() takes the samples as they already are, which avoids a
  // round trip through int16 and the quantisation that would imply.
  n= opus_encode_float(opus_enc, opus_frame, opus_frame_samples, pkt, sizeof(pkt));
  if (n < 0)
    error("Opus encoding failed: %s", opus_strerror(n));
  if (n == 0) return;			// DTX silence; nothing to page out

  if (!ogg_headers_done)
    ogg_write_headers(fp);

  ogg_granule += opus_frame_samples;

  memset(&op, 0, sizeof(op));
  op.packet= pkt;
  op.bytes= n;
  op.b_o_s= 0;
  op.e_o_s= eos;			// libogg sets the page EOS flag for us
  op.granulepos= ogg_granule;
  op.packetno= ogg_stream_packetin(&ogg_os, &op);
  ogg_flush_page(fp);
}

// ogg_final_frame is set while padding the stream out, so that the last
// packet emitted carries the end-of-stream flag.
static int ogg_final_frame;

static void
opus_push(FILE *fp, float l, float r) {
  opus_frame[opus_fill*2  ]= l;
  opus_frame[opus_fill*2+1]= r;
  if (++opus_fill == opus_frame_samples) {
    opus_emit(fp, ogg_final_frame);
    opus_fill= 0;
  }
}
#endif

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

// enc_want_rate() reports the rate this container requires, or 0 for "no
// requirement".  The caller applies it to out_rate before the DSP starts.
int
enc_want_rate(void) {
#ifdef HAVE_OPUS
  if (enc_kind == ENC_OPUS) return OPUS_MAX_RATE;
#endif
  return 0;
}

// enc_set(kind, FILE *fp, int rate, int channels, int bits)
void
enc_set(int kind, FILE *fp, int rate, int channels, int bits) {
  enc_kind= kind;

#ifdef HAVE_FLAC
  if (kind == ENC_FLAC) {
    flac_enc= FLAC__stream_encoder_new();
    if (!flac_enc) error("Can't create FLAC encoder");

    if (FLAC__stream_encoder_set_channels(flac_enc, channels) < 0 ||
	FLAC__stream_encoder_set_bits_per_sample(flac_enc, bits) < 0 ||
	FLAC__stream_encoder_set_sample_rate(flac_enc, rate) < 0 ||
	FLAC__stream_encoder_set_compression_level(flac_enc, 5) < 0) {
      FLAC__stream_encoder_delete(flac_enc);
      error("Can't configure FLAC encoder for %d Hz %d-bit %d channel",
	    rate, bits, channels);
    }

    // Verification would re-decode every frame; far too slow for a
    // multi-hour session.  tests/run.sh decodes the output instead.
    FLAC__stream_encoder_set_verify(flac_enc, 0);

    // init_FILE rather than init_stream: it takes the FILE* directly and sets
    // up the seek/tell callbacks itself, which init_stream would require
    // writing by hand.  It only works for real files, not a pipe.
    if (FLAC__stream_encoder_init_FILE(flac_enc, fp, NULL, NULL) < 0) {
      FLAC__stream_encoder_delete(flac_enc);
      error("Can't initialise FLAC output");
    }
    return;
  }
#endif

#ifdef HAVE_OPUS
  if (kind == ENC_OPUS) {
    int err;

    if (rate != OPUS_MAX_RATE)
      error("Opus output needs %d Hz, not %d Hz (try -r %d)",
	    OPUS_MAX_RATE, rate, OPUS_MAX_RATE);

    opus_enc= opus_encoder_create(OPUS_MAX_RATE, channels,
				  OPUS_APPLICATION_AUDIO, &err);
    if (!opus_enc) error("Can't create Opus encoder: %s", opus_strerror(err));

    opus_encoder_ctl(opus_enc, OPUS_SET_BITRATE(96000));
    opus_encoder_ctl(opus_enc, OPUS_SET_VBR(1));

    opus_frame= (float*)Alloc(sizeof(float) * opus_frame_samples * 2);
    opus_fill= 0;
    ogg_granule= 0;
    ogg_headers_done= 0;
    ogg_eos= 0;
    if (ogg_stream_init(&ogg_os, 20217220) != 0)	// arbitrary serial number
       error("Can't initialise Ogg stream for Opus output");
    ogg_os_ready= 1;
    return;
  }
#endif

  error("This build has no FLAC or Opus encoder compiled in");
}

// enc_write(fp, buf, frames, channels)
//
//   frames counts sample frames; buf holds frames*channels interleaved shorts.
void
enc_write(FILE *fp, const short *buf, int frames, int channels) {
  int a, i;

#ifdef HAVE_FLAC
  if (enc_kind == ENC_FLAC) {
    FLAC__int32 tmp[8192];
    int n= 0;
    for (a= 0; a<frames; a++) {
      for (i= 0; i<channels; i++)
	 tmp[n++]= buf[a*channels + i];
      if (n >= 8192 - channels) {	// keep one frame in reserve
	 FLAC__stream_encoder_process_interleaved(flac_enc, tmp, n/channels);
	 n= 0;
      }
    }
    if (n)
      FLAC__stream_encoder_process_interleaved(flac_enc, tmp, n/channels);
    return;
  }
#endif

#ifdef HAVE_OPUS
  if (enc_kind == ENC_OPUS) {
    for (a= 0; a<frames; a++)
      opus_push(fp, buf[a*channels] / 32768.0f, buf[a*channels+1] / 32768.0f);
    return;
  }
#endif
}

// Flush and close out the encoder.  Registered with atexit because loop()
// never returns -- it exits from outChunk() when the length is reached.
// Takes the destination as an argument since encdec.c is included above the
// globals in sbagen.c.
void
enc_finish(FILE *fp) {
#ifdef HAVE_FLAC
  if (enc_kind == ENC_FLAC && flac_enc) {
    FLAC__stream_encoder_finish(flac_enc);	// emits the tail metadata
    FLAC__stream_encoder_delete(flac_enc);
    flac_enc= 0;
  }
#endif

#ifdef HAVE_OPUS
  if (enc_kind == ENC_OPUS && opus_enc) {
    // Pad the final partial frame with silence, flagging the last packet as
    // end-of-stream.  Opus signals the end of a stream this way, which libogg
    // turns into the page EOS flag -- a zero-length EOS packet is *not* the
    // convention here, and decoders reject it.
    if (!ogg_headers_done)
      ogg_write_headers(fp);
    if (ogg_os_ready && !ogg_eos) {
      // Always emit one more frame, flagged end-of-stream.  If the render
      // stopped part-way through a frame this pads it out; if it stopped
      // exactly on a boundary this adds up to one frame of trailing silence.
      // Doing it unconditionally avoids having to re-issue an already-paged
      // packet just to attach the flag.
      ogg_final_frame= 1;
      do {
	 opus_push(fp, 0, 0);		// NB: this zeroes opus_fill at frame end
      } while (opus_fill);
      ogg_stream_clear(&ogg_os);
      ogg_eos= 1;
    }
    opus_encoder_destroy(opus_enc);
    opus_enc= 0;
  }
#endif
}
