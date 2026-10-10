//
//	unit_render - render via sbagenlib and write raw 16-bit LE samples
//
//	Not a unit test in the assert sense: it is a thin CLI over
//	sbagen_render_immediate() so tests/run.sh can compare its output
//	byte-for-byte against the equivalent `sbagen -Q -S -W` invocation.
//	If the two ever diverge, the library and the CLI have split.
//
//	  unit_render <out.raw> <rate> <len_ms> <fade_ms> <specs...>
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sbagenlib.h"

int
main(int argc, char **argv) {
  short *buf;
  int nframes, rate, len_ms, fade_ms;
  FILE *fp;
  char *specs;
  int i, spec_len;
  size_t written;

  if (argc < 6) {
    fprintf(stderr, "usage: %s <out.raw> <rate> <len_ms> <fade_ms> <specs...>\n",
	    argv[0]);
    return 2;
  }

  rate= atoi(argv[2]);
  len_ms= atoi(argv[3]);
  fade_ms= atoi(argv[4]);

  // Re-join the remaining args into one tone-spec string, as the shell
  // would have passed them to sbagen -i.
  spec_len= 0;
  for (i= 5; i<argc; i++) spec_len+= strlen(argv[i]) + 1;
  specs= malloc(spec_len + 1);
  specs[0]= 0;
  for (i= 5; i<argc; i++) {
    strcat(specs, argv[i]);
    if (i < argc-1) strcat(specs, " ");
  }

  if (0 != sbagen_render_immediate(specs, rate, len_ms, fade_ms,
				   &buf, &nframes))
    return 1;

  fp= fopen(argv[1], "wb");
  if (!fp) { perror(argv[1]); return 1; }
  written= fwrite(buf, sizeof(short) * 2, nframes, fp);
  if (written != (size_t)nframes) { perror("short write"); return 1; }
  if (0 != fclose(fp)) { perror("fclose"); return 1; }

  sbagen_free(buf);
  free(specs);
  return 0;
}