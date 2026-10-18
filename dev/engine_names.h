//
//	engine_names.h - the Engine field "globals".
//
//	All parser/render state lives in struct Engine; the code below still
//	uses the historical names, which resolve through the thread-local
//	E_current.  Included ON by default; define SBAGEN_ENGINE_NAMES_OFF and
//	re-include to switch the names off around third-party headers that
//	use the same identifiers as parameter names (libmad's mad.h and
//	libogg's ogg.h both do).
//
//	The list is maintained in lockstep with struct Engine's fields.
//

#ifdef SBAGEN_ENGINE_NAMES_OFF
#undef per
#undef nlist
#undef now
#undef fast_tim0
#undef fast_tim1
#undef fast_mult
#undef fade_int
#undef chan
#undef sin_table
#undef waves
#undef spin_carr_max
#undef ampadj
#undef opt_c
#undef seed
#undef ntbl
#undef nt_off
#undef noise_buf
#undef noise_off
#undef ns_tbl
#undef ns_off
#undef rand0
#undef rand1
#undef tmp_buf
#undef out_buf
#undef out_bsiz
#undef out_blen
#undef out_bps
#undef out_buf_ms
#undef out_buf_lo
#undef out_fd
#undef out_rate
#undef out_rate_def
#undef out_mode
#undef out_prate
#undef byte_count
#undef loop_stop
#undef mix_flag
#undef mix_in
#undef mix_cnt
#undef in
#undef in_lin
#undef buf
#undef buf_copy
#undef lin
#undef lin_copy
#undef opt_D
#undef opt_M
#undef opt_Q
#undef opt_S
#undef opt_E
#undef opt_W
#undef opt_O
#undef opt_L
#undef opt_T
#undef opt_o
#undef opt_m
#undef opt_d
#undef opt_a
#undef opt_w
#undef tty_erase
#undef lib_sink
#undef lib_sink_len
#undef lib_sink_fill

#else

#define per		(E_current->per)
#define nlist		(E_current->nlist)
#define now		(E_current->now)
#define fast_tim0	(E_current->fast_tim0)
#define fast_tim1	(E_current->fast_tim1)
#define fast_mult	(E_current->fast_mult)
#define fade_int	(E_current->fade_int)
#define chan		(E_current->chan)
#define sin_table	(E_current->sin_table)
#define waves		(E_current->waves)
#define spin_carr_max	(E_current->spin_carr_max)
#define ampadj		(E_current->ampadj)
#define opt_c		(E_current->opt_c)
#define seed		(E_current->seed)
#define ntbl		(E_current->ntbl)
#define nt_off		(E_current->nt_off)
#define noise_buf	(E_current->noise_buf)
#define noise_off	(E_current->noise_off)
#define ns_tbl		(E_current->ns_tbl)
#define ns_off		(E_current->ns_off)
#define rand0		(E_current->rand0)
#define rand1		(E_current->rand1)
#define tmp_buf		(E_current->tmp_buf)
#define out_buf		(E_current->out_buf)
#define out_bsiz	(E_current->out_bsiz)
#define out_blen	(E_current->out_blen)
#define out_bps		(E_current->out_bps)
#define out_buf_ms	(E_current->out_buf_ms)
#define out_buf_lo	(E_current->out_buf_lo)
#define out_fd		(E_current->out_fd)
#define out_rate	(E_current->out_rate)
#define out_rate_def	(E_current->out_rate_def)
#define out_mode	(E_current->out_mode)
#define out_prate	(E_current->out_prate)
#define byte_count	(E_current->byte_count)
#define loop_stop	(E_current->loop_stop)
#define mix_flag	(E_current->mix_flag)
#define mix_in		(E_current->mix_in)
#define mix_cnt		(E_current->mix_cnt)
#define in		(E_current->in)
#define in_lin		(E_current->in_lin)
#define buf		(E_current->buf)
#define buf_copy	(E_current->buf_copy)
#define lin		(E_current->lin)
#define lin_copy	(E_current->lin_copy)
#define opt_D		(E_current->opt_D)
#define opt_M		(E_current->opt_M)
#define opt_Q		(E_current->opt_Q)
#define opt_S		(E_current->opt_S)
#define opt_E		(E_current->opt_E)
#define opt_W		(E_current->opt_W)
#define opt_O		(E_current->opt_O)
#define opt_L		(E_current->opt_L)
#define opt_T		(E_current->opt_T)
#define opt_o		(E_current->opt_o)
#define opt_m		(E_current->opt_m)
#define opt_d		(E_current->opt_d)
#define opt_a		(E_current->opt_a)
#define opt_w		(E_current->opt_w)
#define tty_erase	(E_current->tty_erase)
#define lib_sink	(E_current->lib_sink)
#define lib_sink_len	(E_current->lib_sink_len)
#define lib_sink_fill	(E_current->lib_sink_fill)

#endif	// SBAGEN_ENGINE_NAMES_OFF
