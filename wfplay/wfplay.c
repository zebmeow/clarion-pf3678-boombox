/* wfplay: local MP3 player service behind the boombox's WEFUNK app.
 *
 * Plays <root>/audio/<show>.mp3. Decoding is minimp3 and output goes straight to the
 * ALSA kernel device (/dev/snd/pcmC0D0p, the card Bluetooth audio plays on) through
 * ioctls, so the binary is fully static and does not depend on the unit's glibc 2.11.
 * The software EQ (../eq/dsp.c) is applied with the settings the EQ screen writes.
 *
 * The QML app talks to it over HTTP on 127.0.0.1 (XMLHttpRequest):
 *   /status                     {"state":"playing",...}
 *   /play?show=N[&pos=MS]       load a show (resumes where it was left without pos)
 *   /pause /resume /toggle /stop /seek?pos=MS
 *   /recent                     shows with saved positions, most recent first
 *   /log?m=TEXT                 append TEXT to the QML log on the card (qtapp's own
 *                               output goes to /dev/null on the unit)
 *   anything else               a file under the root (catalog JSON, art)
 * Commands answer with the status. The device is closed while paused or stopped so
 * Bluetooth audio can use it.
 *
 *   wfplay --root DIR [--port 8089] [--pcm DEV] [--state FILE] [--eq FILE] [--null]
 *         [--idle-pause SECONDS]   pause when the app stops polling (default 4, 0 = never)
 *   wfplay --probe [--pcm DEV]      print what the output device accepts, then exit
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define MINIMP3_ONLY_MP3
#define MINIMP3_IMPLEMENTATION
#include "third_party/minimp3.h"
#include "../eq/dsp.h"

#ifdef __linux__
#include <sound/asound.h>
#endif

#define MAX_SHOWS 4096
#define SAVE_EVERY_MS 30000

static const char *root = ".";
static const char *pcm_dev = "/dev/snd/pcmC0D0p";
static const char *state_path = "/var/local/boombox/wefunk.pos";
static const char *eq_path = "/var/local/btaeq.conf";
static const char *qml_log = "/media/map/BOOMBOX/QMLLOG.TXT"; /* /log: messages from the QML */
static int port = 8089;
static int null_out;
static unsigned null_rate;  /* --null-rate: pretend the device runs at this rate */
static FILE *dump;          /* --dump: write what would be played (raw S16 stereo) */

static void logf_(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	time_t now = time(NULL);
	size_t n = strftime(buf, sizeof buf, "%H:%M:%S ", localtime(&now));
	va_start(ap, fmt);
	vsnprintf(buf + n, sizeof buf - n, fmt, ap);
	va_end(ap);
	fputs(buf, stderr);
	fflush(stderr);
}
#define LOG(...) logf_(__VA_ARGS__)

static long long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

/* ---------------------------------------------------------------- output device */

struct out {
	int fd;
	unsigned rate, channels;
	unsigned long period, buffer;
	long long t0, written; /* null output: pacing */
	char desc[128];
};

#ifdef __linux__
static struct snd_mask *pmask(struct snd_pcm_hw_params *p, int n)
{
	return &p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK];
}

static struct snd_interval *pint(struct snd_pcm_hw_params *p, int n)
{
	return &p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
}

static void hw_init(struct snd_pcm_hw_params *p)
{
	memset(p, 0, sizeof *p);
	for (int n = SNDRV_PCM_HW_PARAM_FIRST_MASK; n <= SNDRV_PCM_HW_PARAM_LAST_MASK; n++)
		memset(pmask(p, n)->bits, 0xff, sizeof pmask(p, n)->bits);
	for (int n = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; n <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; n++) {
		pint(p, n)->min = 0;
		pint(p, n)->max = UINT_MAX;
	}
	p->rmask = ~0u;
	p->info = ~0u;
}

static void hw_mask(struct snd_pcm_hw_params *p, int n, unsigned v)
{
	struct snd_mask *m = pmask(p, n);
	memset(m->bits, 0, sizeof m->bits);
	m->bits[v >> 5] |= 1u << (v & 31);
}

static void hw_exact(struct snd_pcm_hw_params *p, int n, unsigned v)
{
	struct snd_interval *i = pint(p, n);
	i->min = i->max = v;
	i->integer = 1;
}

static void hw_base(struct snd_pcm_hw_params *p)
{
	hw_init(p);
	hw_mask(p, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	hw_mask(p, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	hw_mask(p, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
}

static int open_dev(char *err, size_t errlen)
{
	/* O_NONBLOCK: a blocking open waits while another process (PhoneBTA) has it */
	int fd = open(pcm_dev, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		snprintf(err, errlen, errno == EBUSY ? "audio output busy (Bluetooth playing?)"
		                                      : "cannot open %s: %s", pcm_dev, strerror(errno));
		return -1;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
	return fd;
}

static int out_open(struct out *o, unsigned want_rate, char *err, size_t errlen)
{
	struct snd_pcm_hw_params p, q;
	struct snd_pcm_sw_params sw;
	unsigned rates[3], ch;
	int fd = open_dev(err, errlen), ok = 0;

	if (fd < 0)
		return -1;
	hw_base(&p);
	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &p) < 0) {
		snprintf(err, errlen, "audio output rejects S16 interleaved: %s", strerror(errno));
		goto fail;
	}
	ch = pint(&p, SNDRV_PCM_HW_PARAM_CHANNELS)->min <= 2 && pint(&p, SNDRV_PCM_HW_PARAM_CHANNELS)->max >= 2
	     ? 2 : pint(&p, SNDRV_PCM_HW_PARAM_CHANNELS)->min;
	rates[0] = want_rate;
	rates[1] = 48000;
	rates[2] = pint(&p, SNDRV_PCM_HW_PARAM_RATE)->min;
	for (int r = 0; r < 3 && !ok; r++) {
		for (int strict = 1; strict >= 0 && !ok; strict--) {
			hw_base(&q);
			hw_exact(&q, SNDRV_PCM_HW_PARAM_CHANNELS, ch);
			hw_exact(&q, SNDRV_PCM_HW_PARAM_RATE, rates[r]);
			if (strict) {
				hw_exact(&q, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 1024);
				hw_exact(&q, SNDRV_PCM_HW_PARAM_PERIODS, 4);
			}
			ok = ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &q) == 0;
		}
	}
	if (!ok) {
		snprintf(err, errlen, "audio output: no usable rate (%u-%u Hz, %u ch): %s",
		         pint(&p, SNDRV_PCM_HW_PARAM_RATE)->min, pint(&p, SNDRV_PCM_HW_PARAM_RATE)->max,
		         ch, strerror(errno));
		goto fail;
	}
	o->rate = pint(&q, SNDRV_PCM_HW_PARAM_RATE)->min;
	o->channels = ch;
	o->period = pint(&q, SNDRV_PCM_HW_PARAM_PERIOD_SIZE)->min;
	o->buffer = pint(&q, SNDRV_PCM_HW_PARAM_BUFFER_SIZE)->min;

	memset(&sw, 0, sizeof sw);
	sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
	sw.period_step = 1;
	sw.avail_min = o->period;
	sw.start_threshold = o->period * 2 < o->buffer ? o->period * 2 : o->buffer;
	sw.stop_threshold = o->buffer;
	sw.xfer_align = 1;
	sw.boundary = o->buffer;
	while (sw.boundary * 2 <= LONG_MAX - o->buffer)
		sw.boundary *= 2;
	if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw) < 0 || ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) {
		snprintf(err, errlen, "audio output setup failed: %s", strerror(errno));
		goto fail;
	}
	o->fd = fd;
	snprintf(o->desc, sizeof o->desc, "%s %u Hz %u ch, period %lu, buffer %lu",
	         pcm_dev, o->rate, o->channels, o->period, o->buffer);
	return 0;
fail:
	close(fd);
	return -1;
}

static int out_write(struct out *o, const short *buf, unsigned long frames)
{
	while (frames) {
		struct snd_xferi x = { .result = 0, .buf = (void *)buf, .frames = frames };
		if (ioctl(o->fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &x) < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EPIPE || errno == ESTRPIPE) { /* underrun: restart the stream */
				ioctl(o->fd, SNDRV_PCM_IOCTL_PREPARE);
				continue;
			}
			return -1;
		}
		buf += x.result * o->channels;
		frames -= x.result;
	}
	return 0;
}

/* frames queued in the device, for an accurate position */
static long out_delay(struct out *o)
{
	snd_pcm_sframes_t d = 0;
	return ioctl(o->fd, SNDRV_PCM_IOCTL_DELAY, &d) == 0 && d > 0 ? (long)d : 0;
}

static void out_close(struct out *o)
{
	ioctl(o->fd, SNDRV_PCM_IOCTL_DROP);
	close(o->fd);
}

static int probe(void)
{
	struct snd_pcm_hw_params p;
	char err[160];
	int fd = open_dev(err, sizeof err);

	if (fd < 0) {
		printf("probe: %s\n", err);
		return 1;
	}
	hw_init(&p);
	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &p) < 0) {
		printf("probe: HW_REFINE failed: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	printf("probe: %s formats %08x%08x access %08x\n", pcm_dev,
	       pmask(&p, SNDRV_PCM_HW_PARAM_FORMAT)->bits[1], pmask(&p, SNDRV_PCM_HW_PARAM_FORMAT)->bits[0],
	       pmask(&p, SNDRV_PCM_HW_PARAM_ACCESS)->bits[0]);
	printf("probe: channels %u-%u rate %u-%u period %u-%u periods %u-%u\n",
	       pint(&p, SNDRV_PCM_HW_PARAM_CHANNELS)->min, pint(&p, SNDRV_PCM_HW_PARAM_CHANNELS)->max,
	       pint(&p, SNDRV_PCM_HW_PARAM_RATE)->min, pint(&p, SNDRV_PCM_HW_PARAM_RATE)->max,
	       pint(&p, SNDRV_PCM_HW_PARAM_PERIOD_SIZE)->min, pint(&p, SNDRV_PCM_HW_PARAM_PERIOD_SIZE)->max,
	       pint(&p, SNDRV_PCM_HW_PARAM_PERIODS)->min, pint(&p, SNDRV_PCM_HW_PARAM_PERIODS)->max);
	close(fd);
	return 0;
}
#else
static int out_open(struct out *o, unsigned want_rate, char *err, size_t errlen)
{
	(void)o; (void)want_rate;
	snprintf(err, errlen, "no audio device on this platform (use --null)");
	return -1;
}
static int out_write(struct out *o, const short *buf, unsigned long frames) { (void)o; (void)buf; (void)frames; return -1; }
static long out_delay(struct out *o) { (void)o; return 0; }
static void out_close(struct out *o) { (void)o; }
static int probe(void) { printf("probe: no ALSA on this platform\n"); return 1; }
#endif

/* --null: no device, writes are paced by the clock (desktop preview, tests) */
static int null_open(struct out *o, unsigned want_rate)
{
	o->fd = -1;
	o->rate = null_rate ? null_rate : want_rate;
	o->channels = 2;
	o->period = 1152;
	o->buffer = 4608;
	o->t0 = now_ms();
	o->written = 0;
	snprintf(o->desc, sizeof o->desc, "null output %u Hz", o->rate);
	return 0;
}

static void null_write(struct out *o, unsigned long frames)
{
	long long due;
	o->written += frames;
	due = o->t0 + o->written * 1000 / o->rate - 50; /* stay ~50 ms ahead, like a buffer */
	while (now_ms() < due)
		usleep(5000);
}

/* ---------------------------------------------------------------- shared state */

enum { ST_STOPPED, ST_PLAYING, ST_PAUSED, ST_LOADING };
static const char *state_names[] = { "stopped", "playing", "paused", "loading" };

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;

static struct {
	int want_play;      /* 1 = should be producing sound */
	int load_show;      /* > 0: open this show */
	long long load_pos; /* < 0: resume from the saved position */
	long long seek;     /* >= 0: jump here */
} req = { 0, 0, -1, -1 };

/* the app polls /status twice a second while it is on screen; when the polling stops
   (Exit, Home, a source change) the show pauses so nothing plays behind the stock UI */
static long long last_seen;
static int idle_pause_ms = 4000;

static struct {
	int state, show, ended;
	long long pos, dur;
	char err[160], out[128];
} st;

/* saved positions, most recent first */
static struct saved { int show; long long ms; } saved[MAX_SHOWS];
static int nsaved;
static int saved_dirty;

static long long saved_get(int show)
{
	for (int i = 0; i < nsaved; i++)
		if (saved[i].show == show)
			return saved[i].ms;
	return 0;
}

static void saved_put(int show, long long ms)
{
	int i;
	for (i = 0; i < nsaved && saved[i].show != show; i++)
		;
	if (i == nsaved && nsaved < MAX_SHOWS)
		nsaved++;
	if (i == nsaved)
		i = nsaved - 1;
	memmove(&saved[1], &saved[0], i * sizeof saved[0]);
	saved[0].show = show;
	saved[0].ms = ms;
	saved_dirty = 1;
}

static void saved_load(void)
{
	FILE *f = fopen(state_path, "r");
	int show;
	long long ms;
	if (!f)
		return;
	while (nsaved < MAX_SHOWS && fscanf(f, "%d %lld", &show, &ms) == 2)
		saved[nsaved++] = (struct saved){ show, ms };
	fclose(f);
}

/* caller holds mu; writes a copy then renames, so a power cut leaves the old file */
static void saved_write(void)
{
	char tmp[PATH_MAX];
	FILE *f;
	if (!saved_dirty)
		return;
	snprintf(tmp, sizeof tmp, "%s.tmp", state_path);
	if (!(f = fopen(tmp, "w")))
		return;
	for (int i = 0; i < nsaved; i++)
		fprintf(f, "%d %lld\n", saved[i].show, saved[i].ms);
	if (fflush(f) == 0 && fsync(fileno(f)) == 0 && fclose(f) == 0)
		rename(tmp, state_path);
	else
		unlink(tmp);
	saved_dirty = 0;
}

static void set_err(const char *e)
{
	snprintf(st.err, sizeof st.err, "%s", e);
	if (*e)
		LOG("error: %s\n", e);
}

/* ---------------------------------------------------------------- player thread */

struct stream {
	FILE *f;
	int show;
	long data_start;
	unsigned kbps, rate, channels;
	long long base_ms, src_frames; /* position = base + frames decoded since the last seek */
	mp3dec_t dec;
	unsigned char buf[16384];
	size_t have, off;
	int eof;
};

static struct stream s;

static void stream_close(void)
{
	if (s.f)
		fclose(s.f);
	s.f = NULL;
	s.show = 0;
}

static int stream_fill(void)
{
	size_t n;
	if (s.off) {
		memmove(s.buf, s.buf + s.off, s.have - s.off);
		s.have -= s.off;
		s.off = 0;
	}
	if (s.eof || s.have == sizeof s.buf)
		return 0;
	n = fread(s.buf + s.have, 1, sizeof s.buf - s.have, s.f);
	if (n == 0)
		s.eof = 1;
	s.have += n;
	return (int)n;
}

static void stream_seek(long long ms)
{
	long long byte = s.data_start + ms * s.kbps / 8; /* constant bitrate: ms * kbit/s / 8 = bytes */
	fseek(s.f, (long)byte, SEEK_SET);
	s.have = s.off = 0;
	s.eof = 0;
	mp3dec_init(&s.dec);
	s.base_ms = ms;
	s.src_frames = 0;
}

static int stream_open(int show, char *err, size_t errlen)
{
	char path[PATH_MAX];
	mp3dec_frame_info_t info;
	short pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
	struct stat sb;

	stream_close();
	snprintf(path, sizeof path, "%s/audio/%d.mp3", root, show);
	if (!(s.f = fopen(path, "rb")) || fstat(fileno(s.f), &sb) != 0) {
		snprintf(err, errlen, "cannot open show %d: %s", show, strerror(errno));
		stream_close();
		return -1;
	}
	s.show = show;
	s.have = s.off = 0;
	s.eof = 0;
	s.data_start = 0;
	stream_fill();
	if (s.have >= 10 && !memcmp(s.buf, "ID3", 3)) /* skip an ID3v2 tag */
		s.data_start = 10 + ((s.buf[6] & 0x7f) << 21 | (s.buf[7] & 0x7f) << 14 |
		                     (s.buf[8] & 0x7f) << 7 | (s.buf[9] & 0x7f));
	mp3dec_init(&s.dec);
	memset(&info, 0, sizeof info);
	mp3dec_decode_frame(&s.dec, s.buf + (s.data_start < (long)s.have ? s.data_start : 0),
	                    (int)(s.have - (s.data_start < (long)s.have ? s.data_start : 0)), pcm, &info);
	if (!info.frame_bytes || !info.bitrate_kbps) {
		snprintf(err, errlen, "show %d: not an MP3 file", show);
		stream_close();
		return -1;
	}
	s.kbps = info.bitrate_kbps;
	s.rate = info.hz;
	s.channels = info.channels;
	st.dur = (sb.st_size - s.data_start) * 8 / s.kbps;
	stream_seek(0);
	return 0;
}

/* linear resampler + channel mapping from the decoder's format to the device's */
struct resampler {
	double step, pos;
	float last[2];
};

static unsigned long convert(struct resampler *r, const short *in, unsigned long n, unsigned in_ch,
                             short *out, unsigned out_ch, int same_rate)
{
	unsigned long m = 0;
	if (same_rate) {
		for (unsigned long i = 0; i < n; i++, m++)
			for (unsigned c = 0; c < out_ch; c++)
				out[m * out_ch + c] = in[i * in_ch + (c < in_ch ? c : 0)];
		return m;
	}
	/* x[-1] = r->last, x[0..n-1] = in; output at fractional positions r->pos */
	while (r->pos < (double)n - 1) {
		long i = (long)(r->pos < 0 ? -1 : r->pos);
		float f = (float)(r->pos - i);
		for (unsigned c = 0; c < out_ch; c++) {
			unsigned ic = c < in_ch ? c : 0;
			float a = i < 0 ? r->last[ic] : in[i * in_ch + ic];
			float b = in[(i + 1) * in_ch + ic];
			out[m * out_ch + c] = (short)(a + (b - a) * f);
		}
		m++;
		r->pos += r->step;
	}
	r->pos -= n;
	for (unsigned c = 0; c < in_ch && c < 2; c++)
		r->last[c] = in[(n - 1) * in_ch + c];
	return m;
}

static struct eq_state eq;
static time_t eq_mtime = -1;
static ino_t eq_ino;
static int eq_on;

static void eq_check(unsigned rate, unsigned channels, int force)
{
	struct stat sb;
	struct eq_settings cfg;
	char text[4096];
	FILE *f;
	size_t n;

	if (stat(eq_path, &sb) != 0) {
		eq_on = 0;
		eq_mtime = -1;
		return;
	}
	if (!force && sb.st_mtime == eq_mtime && sb.st_ino == eq_ino)
		return;
	eq_mtime = sb.st_mtime;
	eq_ino = sb.st_ino;
	if (!(f = fopen(eq_path, "r")))
		return;
	n = fread(text, 1, sizeof text - 1, f);
	fclose(f);
	text[n] = 0;
	memset(&cfg, 0, sizeof cfg);
	if (eq_parse(text, &cfg) == 0) {
		eq_configure(&eq, &cfg, rate, channels);
		eq_on = cfg.enabled;
		LOG("eq: %s, %d bands, preamp %.1f dB\n", eq_on ? "on" : "off", cfg.nbands, cfg.preamp_db);
	}
}

static void *player(void *arg)
{
	static short pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
	static short outbuf[MINIMP3_MAX_SAMPLES_PER_FRAME * 2 * 2];
	struct out o;
	struct resampler rs;
	int open_ = 0;
	long long last_save = now_ms(), last_eq = 0;
	char err[160];
	(void)arg;

	memset(&rs, 0, sizeof rs);
	for (;;) {
		int load, want;
		long long load_pos, seek;

		pthread_mutex_lock(&mu);
		while (!req.want_play && !req.load_show && req.seek < 0) {
			if (open_) { /* paused or stopped: hand the device back */
				if (!null_out)
					out_close(&o);
				open_ = 0;
			}
			if (s.f && !st.ended) {
				saved_put(s.show, st.pos);
				st.state = ST_PAUSED;
			}
			saved_write();
			pthread_cond_wait(&cv, &mu);
		}
		load = req.load_show;
		load_pos = req.load_pos;
		seek = req.seek;
		req.load_show = 0;
		req.seek = -1;
		want = req.want_play;
		pthread_mutex_unlock(&mu);

		if (load) {
			pthread_mutex_lock(&mu);
			if (s.f)
				saved_put(s.show, st.pos);
			st.state = ST_LOADING;
			pthread_mutex_unlock(&mu);
			if (stream_open(load, err, sizeof err) != 0) {
				pthread_mutex_lock(&mu);
				set_err(err);
				st.state = ST_STOPPED;
				st.show = 0;
				st.pos = st.dur = 0;
				req.want_play = 0;
				pthread_mutex_unlock(&mu);
				continue;
			}
			pthread_mutex_lock(&mu);
			if (load_pos < 0)
				load_pos = saved_get(load);
			if (load_pos > st.dur - 5000) /* finished last time: start over */
				load_pos = 0;
			st.show = load;
			st.ended = 0;
			set_err("");
			saved_put(load, load_pos);
			pthread_mutex_unlock(&mu);
			seek = load_pos;
			LOG("show %d: %u kbps %u Hz %u ch, %lld ms, from %lld ms\n",
			    load, s.kbps, s.rate, s.channels, st.dur, load_pos);
		}
		if (seek >= 0 && s.f) {
			if (seek > st.dur)
				seek = st.dur;
			stream_seek(seek);
			pthread_mutex_lock(&mu);
			st.pos = seek;
			st.ended = 0;
			pthread_mutex_unlock(&mu);
		}
		if (!s.f) {
			pthread_mutex_lock(&mu);
			req.want_play = 0;
			st.state = ST_STOPPED;
			pthread_mutex_unlock(&mu);
			continue;
		}
		if (!want) {
			pthread_mutex_lock(&mu);
			st.state = ST_PAUSED;
			pthread_mutex_unlock(&mu);
			continue;
		}

		if (!open_) {
			int rc = null_out ? null_open(&o, s.rate) : out_open(&o, s.rate, err, sizeof err);
			pthread_mutex_lock(&mu);
			if (rc != 0) {
				set_err(err);
				req.want_play = 0;
				st.state = ST_PAUSED;
				pthread_mutex_unlock(&mu);
				continue;
			}
			snprintf(st.out, sizeof st.out, "%s", o.desc);
			set_err("");
			pthread_mutex_unlock(&mu);
			LOG("output: %s\n", o.desc);
			open_ = 1;
			memset(&rs, 0, sizeof rs);
			rs.step = (double)s.rate / o.rate;
			eq_check(o.rate, o.channels, 1);
		}

		/* decode one frame */
		{
			mp3dec_frame_info_t info;
			int samples;
			unsigned long frames;

			if (s.have - s.off < 2048 && !s.eof)
				stream_fill();
			memset(&info, 0, sizeof info);
			samples = mp3dec_decode_frame(&s.dec, s.buf + s.off, (int)(s.have - s.off), pcm, &info);
			s.off += info.frame_bytes;
			if (!info.frame_bytes) {
				if (!s.eof) {
					stream_fill();
					continue;
				}
				pthread_mutex_lock(&mu); /* end of show */
				st.state = ST_STOPPED;
				st.ended = 1;
				st.pos = st.dur;
				req.want_play = 0;
				saved_put(s.show, 0);
				pthread_mutex_unlock(&mu);
				LOG("show %d finished\n", s.show);
				continue;
			}
			if (!samples)
				continue;
			s.src_frames += samples;
			frames = convert(&rs, pcm, samples, info.channels, outbuf, o.channels, s.rate == o.rate);
			if (now_ms() - last_eq > 1000) {
				eq_check(o.rate, o.channels, 0);
				last_eq = now_ms();
			}
			if (eq_on)
				eq_process_s16(&eq, outbuf, outbuf, frames);
			if (dump)
				fwrite(outbuf, 2 * o.channels, frames, dump);
			if (null_out && dump)
				;  /* dumping: run as fast as possible */
			else if (null_out)
				null_write(&o, frames);
			else if (out_write(&o, outbuf, frames) != 0) {
				pthread_mutex_lock(&mu);
				snprintf(err, sizeof err, "audio write failed: %s", strerror(errno));
				set_err(err);
				req.want_play = 0;
				pthread_mutex_unlock(&mu);
				continue;
			}
			pthread_mutex_lock(&mu);
			st.pos = s.base_ms + s.src_frames * 1000 / s.rate -
			         (null_out ? 0 : out_delay(&o) * 1000 / o.rate);
			if (st.pos < s.base_ms)
				st.pos = s.base_ms;
			st.state = ST_PLAYING;
			if (now_ms() - last_save > SAVE_EVERY_MS) {
				saved_put(s.show, st.pos);
				saved_write();
				last_save = now_ms();
			}
			pthread_mutex_unlock(&mu);
		}
	}
	return NULL;
}

/* ---------------------------------------------------------------- HTTP */

static int status_json(char *buf, size_t len)
{
	return snprintf(buf, len,
	                "{\"state\":\"%s\",\"show\":%d,\"pos\":%lld,\"dur\":%lld,\"ended\":%s,"
	                "\"err\":\"%s\",\"out\":\"%s\"}\n",
	                state_names[st.state], st.show, st.pos, st.dur, st.ended ? "true" : "false",
	                st.err, st.out);
}

static void reply(int fd, int code, const char *type, const char *body, size_t len)
{
	char head[256];
	int n = snprintf(head, sizeof head,
	                 "HTTP/1.0 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
	                 "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
	                 code, code == 200 ? "OK" : "Not Found", type, len);
	if (write(fd, head, n) < 0 || (len && write(fd, body, len) < 0))
		return;
}

static long long qnum(const char *query, const char *key, long long def)
{
	size_t kl = strlen(key);
	for (const char *p = query; p && *p; p = strchr(p, '&') ? strchr(p, '&') + 1 : NULL)
		if (!strncmp(p, key, kl) && p[kl] == '=')
			return atoll(p + kl + 1);
	return def;
}

static const char *ctype(const char *path)
{
	const char *dot = strrchr(path, '.');
	if (!dot) return "application/octet-stream";
	if (!strcmp(dot, ".json")) return "application/json";
	if (!strcmp(dot, ".jpg")) return "image/jpeg";
	if (!strcmp(dot, ".png")) return "image/png";
	if (!strcmp(dot, ".qml") || !strcmp(dot, ".txt")) return "text/plain";
	if (!strcmp(dot, ".mp3")) return "audio/mpeg";
	return "application/octet-stream";
}

static void serve_file(int fd, const char *path)
{
	char full[PATH_MAX], buf[16384];
	struct stat sb;
	char head[256];
	int f, n;
	ssize_t r;

	if (strstr(path, "..") || snprintf(full, sizeof full, "%s%s", root, path) >= (int)sizeof full ||
	    (f = open(full, O_RDONLY)) < 0) {
		reply(fd, 404, "text/plain", "not found\n", 10);
		return;
	}
	if (fstat(f, &sb) != 0 || !S_ISREG(sb.st_mode)) {
		close(f);
		reply(fd, 404, "text/plain", "not found\n", 10);
		return;
	}
	n = snprintf(head, sizeof head,
	             "HTTP/1.0 200 OK\r\nContent-Type: %s\r\nContent-Length: %lld\r\n"
	             "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
	             ctype(path), (long long)sb.st_size);
	if (write(fd, head, n) == n)
		while ((r = read(f, buf, sizeof buf)) > 0 && write(fd, buf, r) == r)
			;
	close(f);
}

static void url_decode(char *s)
{
	char *o = s;
	for (; *s; s++) {
		if (*s == '%' && s[1] && s[2]) {
			char hex[3] = { s[1], s[2], 0 };
			*o++ = (char)strtol(hex, NULL, 16);
			s += 2;
		} else {
			*o++ = *s == '+' ? ' ' : *s;
		}
	}
	*o = 0;
}

static void qml_log_append(const char *query)
{
	const char *m = query ? strstr(query, "m=") : NULL;
	char msg[1500];
	FILE *f;
	time_t now = time(NULL);
	if (!m)
		return;
	snprintf(msg, sizeof msg, "%s", m + 2);
	url_decode(msg);
	LOG("qml: %s\n", msg);
	if ((f = fopen(qml_log, "a"))) {
		fprintf(f, "%ld %s\r\n", (long)now, msg);
		fclose(f);
		sync();
	}
}

static void handle(int fd)
{
	char req_buf[2048], body[16384], path[1024];
	char *query, *sp;
	size_t got = 0;
	ssize_t n;
	int len, command = 1;
	struct timeval tv = { 2, 0 };

	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	while (got < sizeof req_buf - 1 && (n = read(fd, req_buf + got, sizeof req_buf - 1 - got)) > 0) {
		got += n;
		req_buf[got] = 0;
		if (strstr(req_buf, "\r\n\r\n") || strstr(req_buf, "\n\n"))
			break;
	}
	req_buf[got] = 0;
	if (strncmp(req_buf, "GET ", 4) || !(sp = strchr(req_buf + 4, ' '))) {
		reply(fd, 404, "text/plain", "bad request\n", 12);
		return;
	}
	*sp = 0;
	snprintf(path, sizeof path, "%s", req_buf + 4);
	if ((query = strchr(path, '?')))
		*query++ = 0;

	pthread_mutex_lock(&mu);
	if (strcmp(path, "/log"))
		last_seen = now_ms();
	if (!strcmp(path, "/play")) {
		int show = (int)qnum(query, "show", 0);
		if (show > 0) {
			req.load_show = show;
			req.load_pos = qnum(query, "pos", -1);
			req.want_play = 1;
			st.show = show;
			st.state = ST_LOADING;
		}
	} else if (!strcmp(path, "/pause")) {
		req.want_play = 0;
		if (st.state == ST_PLAYING)
			st.state = ST_PAUSED;
	} else if (!strcmp(path, "/resume")) {
		req.want_play = st.show != 0;
		if (st.ended)
			req.seek = 0;
	} else if (!strcmp(path, "/toggle")) {
		req.want_play = !req.want_play && st.show != 0;
		if (!req.want_play && st.state == ST_PLAYING)
			st.state = ST_PAUSED;
		if (req.want_play && st.ended)
			req.seek = 0;
	} else if (!strcmp(path, "/seek")) {
		req.seek = qnum(query, "pos", 0);
		if (req.seek < 0)
			req.seek = 0;
		st.pos = req.seek; /* show the new position right away */
	} else if (!strcmp(path, "/stop")) {
		req.want_play = 0;
		if (st.state == ST_PLAYING)
			st.state = ST_PAUSED;
	} else if (!strcmp(path, "/log")) {
		pthread_mutex_unlock(&mu);
		qml_log_append(query);
		reply(fd, 200, "text/plain", "ok\n", 3);
		return;
	} else if (!strcmp(path, "/recent")) {
		int o = snprintf(body, sizeof body, "[");
		for (int i = 0; i < nsaved && o < (int)sizeof body - 64; i++)
			o += snprintf(body + o, sizeof body - o, "%s{\"show\":%d,\"pos\":%lld}",
			              i ? "," : "", saved[i].show, saved[i].ms);
		snprintf(body + o, sizeof body - o, "]\n");
		pthread_mutex_unlock(&mu);
		reply(fd, 200, "application/json", body, strlen(body));
		return;
	} else if (strcmp(path, "/status")) {
		command = 0;
	}
	if (command) {
		pthread_cond_signal(&cv);
		len = status_json(body, sizeof body);
		pthread_mutex_unlock(&mu);
		reply(fd, 200, "application/json", body, len);
		return;
	}
	pthread_mutex_unlock(&mu);
	serve_file(fd, path);
}

static void *watchdog(void *arg)
{
	(void)arg;
	for (;;) {
		usleep(500000);
		pthread_mutex_lock(&mu);
		if (idle_pause_ms > 0 && req.want_play && now_ms() - last_seen > idle_pause_ms) {
			LOG("app gone for %d ms: pausing\n", idle_pause_ms);
			req.want_play = 0;
			if (st.state == ST_PLAYING)
				st.state = ST_PAUSED;
			pthread_cond_signal(&cv);
		}
		pthread_mutex_unlock(&mu);
	}
	return NULL;
}

static void *http_conn(void *arg)
{
	int fd = (int)(long)arg;
	handle(fd);
	close(fd);
	return NULL;
}

int main(int argc, char **argv)
{
	struct sockaddr_in a;
	pthread_t t;
	pthread_attr_t at;
	int srv, one = 1, do_probe = 0;

	for (int i = 1; i < argc; i++) {
		const char *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!strcmp(argv[i], "--root") && v) root = argv[++i];
		else if (!strcmp(argv[i], "--port") && v) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--pcm") && v) pcm_dev = argv[++i];
		else if (!strcmp(argv[i], "--state") && v) state_path = argv[++i];
		else if (!strcmp(argv[i], "--eq") && v) eq_path = argv[++i];
		else if (!strcmp(argv[i], "--qml-log") && v) qml_log = argv[++i];
		else if (!strcmp(argv[i], "--null")) null_out = 1;
		else if (!strcmp(argv[i], "--probe")) do_probe = 1;
		else if (!strcmp(argv[i], "--null-rate") && v) null_rate = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--idle-pause") && v) idle_pause_ms = atoi(argv[++i]) * 1000;
		else if (!strcmp(argv[i], "--dump") && v) {
			if (!(dump = fopen(argv[++i], "wb")))
				return 1;
			null_out = 1;
		}
		else {
			fprintf(stderr, "usage: wfplay --root DIR [--port N] [--pcm DEV] [--state FILE] "
			                "[--eq FILE] [--null] | --probe\n");
			return 2;
		}
	}
	if (do_probe)
		return probe();
#ifndef __linux__
	null_out = 1;
#endif
	signal(SIGPIPE, SIG_IGN);
	saved_load();

	srv = socket(AF_INET, SOCK_STREAM, 0);
	setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(srv, (struct sockaddr *)&a, sizeof a) != 0 || listen(srv, 16) != 0) {
		LOG("cannot listen on 127.0.0.1:%d: %s\n", port, strerror(errno));
		return 1;
	}
	LOG("wfplay: root %s, http://127.0.0.1:%d, output %s\n", root, port, null_out ? "null" : pcm_dev);

	pthread_attr_init(&at);
	pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
	pthread_attr_setstacksize(&at, 256 * 1024);
	if (pthread_create(&t, &at, player, NULL) != 0) {
		LOG("cannot start player thread\n");
		return 1;
	}
	if (pthread_create(&t, &at, watchdog, NULL) != 0)
		LOG("cannot start watchdog thread\n");
	for (;;) {
		int fd = accept(srv, NULL, NULL);
		if (fd < 0)
			continue;
		if (pthread_create(&t, &at, http_conn, (void *)(long)fd) != 0)
			close(fd);
	}
}
