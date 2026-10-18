//
//	unit_two - render two sequences concurrently, in two threads
//
//	The point of the Engine struct: two independent parse+render pipelines
//	in one process.  Each thread creates its own engine (inside
//	sbagen_render_immediate), parses its own tone-spec, and renders into
//	its own buffer.  tests/run.sh then proves each thread's output is
//	byte-identical to the equivalent CLI render -- concurrency must not
//	change a single sample.
//
//	  unit_two <out1.raw> <spec1> <out2.raw> <spec2> <rate> <len_ms> <fade_ms>
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include "sbagenlib.h"

typedef struct {
  const char *out, *spec;
  int rate, len_ms, fade_ms;
  int rc;
} Job;

static void *
work(void *vp) {
  Job *j= vp;
  short *buf;
  int nframes;
  FILE *fp;
  size_t w;

  j->rc= sbagen_render_immediate(j->spec, j->rate, j->len_ms, j->fade_ms,
				 &buf, &nframes);
  if (j->rc != 0) return 0;

  fp= fopen(j->out, "wb");
  if (!fp) { perror(j->out); j->rc= 1; return 0; }
  w= fwrite(buf, sizeof(short) * 2, nframes, fp);
  if (w != (size_t)nframes) { perror("short write"); j->rc= 1; }
  if (0 != fclose(fp)) { perror("fclose"); j->rc= 1; }
  sbagen_free(buf);
  return 0;
}

int
main(int argc, char **argv) {
  Job j1, j2;
  pthread_t t1, t2;

  if (argc != 8) {
    fprintf(stderr,
	    "usage: %s <out1.raw> <spec1> <out2.raw> <spec2> <rate> <len_ms> <fade_ms>\n",
	    argv[0]);
    return 2;
  }

  memset(&j1, 0, sizeof(j1)); memset(&j2, 0, sizeof(j2));
  j1.out= argv[1]; j1.spec= argv[2];
  j2.out= argv[3]; j2.spec= argv[4];
  j1.rate= j2.rate= atoi(argv[5]);
  j1.len_ms= j2.len_ms= atoi(argv[6]);
  j1.fade_ms= j2.fade_ms= atoi(argv[7]);

  if (0 != pthread_create(&t1, 0, work, &j1) ||
      0 != pthread_create(&t2, 0, work, &j2)) {
    fprintf(stderr, "pthread_create failed\n");
    return 1;
  }
  pthread_join(t1, 0);
  pthread_join(t2, 0);

  return j1.rc | j2.rc;
}