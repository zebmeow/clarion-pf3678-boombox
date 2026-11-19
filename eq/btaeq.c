/* btaeq: LD_PRELOAD hook that runs PhoneBTA's Bluetooth audio through the EQ in dsp.c.
 *
 * PhoneBTA decodes A2DP itself and plays it with snd_pcm_writei() on plughw:0,0.
 * We watch the hw_params calls to learn each PCM's format/rate/channels and filter
 * S16 interleaved writes. Anything unexpected (other formats, failed lookups, missing
 * config) passes audio through untouched.
 *
 * Settings live in BTAEQ_CONF (default /var/local/btaeq.conf) and are re-read when the
 * file's mtime or inode changes, checked every ~250 ms of audio. */
#define _GNU_SOURCE
#include "dsp.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>

/* Minimal ALSA declarations, so we do not need ALSA headers to build. */
typedef struct _snd_pcm snd_pcm_t;
typedef struct _snd_pcm_hw_params snd_pcm_hw_params_t;
typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;
#define SND_PCM_FORMAT_S16_LE 2

#define DEFAULT_CONF "/var/local/btaeq.conf"
#define MAX_PCMS 4
#define CHECK_INTERVAL_MS 250
#define CHUNK_FRAMES 1024

struct pcm_info {
	snd_pcm_t *pcm;
	int format;
	unsigned rate, channels;
	struct eq_state eq;
	int configured;
	unsigned long frames_since_check;
};

static struct pcm_info pcms[MAX_PCMS];
static struct eq_settings settings;
static time_t conf_mtime = -1;
static ino_t conf_ino; /* writers replace the file by rename, so a new inode = new settings */
static int have_settings;
static int debug;
static FILE *logfp; /* BTAEQ_LOG=/path; PhoneBTA's own stdout/stderr go to /dev/null */

/* with BTAEQ_LOG set: report how much of real time the filtering takes */
static double dsp_seconds;
static unsigned long dsp_frames;

static double now(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec * 1e-6;
}

static int (*real_set_format)(snd_pcm_t *, snd_pcm_hw_params_t *, int);
static int (*real_set_channels)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned);
static int (*real_set_rate_near)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned *, int *);
static snd_pcm_sframes_t (*real_writei)(snd_pcm_t *, const void *, snd_pcm_uframes_t);
static int (*real_close)(snd_pcm_t *);

#define LOG(...) do { if (debug) { fprintf(logfp, "[btaeq] " __VA_ARGS__); fflush(logfp); } } while (0)

static void *real(const char *name, const char *version)
{
	void *fn = dlvsym(RTLD_NEXT, name, version);
	if (!fn)
		fn = dlsym(RTLD_NEXT, name);
	return fn;
}

__attribute__((constructor)) static void btaeq_init(void)
{
	const char *log = getenv("BTAEQ_LOG");
	if (log && (logfp = fopen(log, "a")) != NULL)
		debug = 1;
	real_set_format = real("snd_pcm_hw_params_set_format", "ALSA_0.9");
	real_set_channels = real("snd_pcm_hw_params_set_channels", "ALSA_0.9");
	real_set_rate_near = real("snd_pcm_hw_params_set_rate_near", "ALSA_0.9.0rc4");
	real_writei = real("snd_pcm_writei", "ALSA_0.9");
	real_close = real("snd_pcm_close", "ALSA_0.9");
	LOG("loaded (writei=%p)\n", (void *)real_writei);
}

static struct pcm_info *lookup(snd_pcm_t *pcm, int create)
{
	struct pcm_info *free_slot = NULL;
	for (int i = 0; i < MAX_PCMS; i++) {
		if (pcms[i].pcm == pcm)
			return &pcms[i];
		if (!pcms[i].pcm && !free_slot)
			free_slot = &pcms[i];
	}
	if (create && free_slot) {
		memset(free_slot, 0, sizeof(*free_slot));
		free_slot->pcm = pcm;
		free_slot->format = -1;
		return free_slot;
	}
	return NULL;
}

/* Re-read the config if it changed. Returns 1 when settings changed. */
static int reload_settings(void)
{
	const char *path = getenv("BTAEQ_CONF");
	struct stat sb;
	if (!path)
		path = DEFAULT_CONF;
	if (stat(path, &sb) != 0) {
		if (have_settings || conf_mtime != -1) {
			have_settings = 0;
			conf_mtime = -1;
			return 1;
		}
		return 0;
	}
	if (sb.st_mtime == conf_mtime && sb.st_ino == conf_ino && have_settings)
		return 0;

	FILE *fp = fopen(path, "r");
	if (!fp)
		return 0;
	char text[4096];
	size_t n = fread(text, 1, sizeof(text) - 1, fp);
	fclose(fp);
	text[n] = '\0';

	eq_parse(text, &settings);
	conf_mtime = sb.st_mtime;
	conf_ino = sb.st_ino;
	have_settings = 1;
	LOG("config loaded: enabled=%d preamp=%.1f bands=%d\n", settings.enabled,
	    settings.preamp_db, settings.nbands);
	return 1;
}

int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int format)
{
	int ret = real_set_format(pcm, params, format);
	struct pcm_info *p = lookup(pcm, 1);
	if (p && ret == 0) {
		p->format = format;
		p->configured = 0;
	}
	return ret;
}

int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned val)
{
	int ret = real_set_channels(pcm, params, val);
	struct pcm_info *p = lookup(pcm, 1);
	if (p && ret == 0) {
		p->channels = val;
		p->configured = 0;
	}
	return ret;
}

int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned *val, int *dir)
{
	int ret = real_set_rate_near(pcm, params, val, dir);
	struct pcm_info *p = lookup(pcm, 1);
	if (p && ret == 0 && val) {
		p->rate = *val;
		p->configured = 0;
	}
	return ret;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t size)
{
	struct pcm_info *p = lookup(pcm, 0);
	if (!p || p->format != SND_PCM_FORMAT_S16_LE || p->channels < 1 ||
	    p->channels > EQ_MAX_CHANNELS || p->rate == 0)
		return real_writei(pcm, buffer, size);

	int changed = 0;
	if (!p->configured || p->frames_since_check >= p->rate * CHECK_INTERVAL_MS / 1000) {
		changed = reload_settings();
		p->frames_since_check = 0;
	}
	if (!have_settings || !settings.enabled)
		return real_writei(pcm, buffer, size);
	if (!p->configured || changed) {
		eq_configure(&p->eq, &settings, p->rate, p->channels);
		p->configured = 1;
		LOG("pcm %p: %u Hz, %u ch\n", (void *)pcm, p->rate, p->channels);
	}
	p->frames_since_check += size;

	/* filter into a stack buffer chunk by chunk; the caller's buffer is const */
	short tmp[CHUNK_FRAMES * EQ_MAX_CHANNELS];
	const short *src = buffer;
	snd_pcm_uframes_t done = 0;
	while (done < size) {
		snd_pcm_uframes_t n = size - done < CHUNK_FRAMES ? size - done : CHUNK_FRAMES;
		double t0 = debug ? now() : 0;
		eq_process_s16(&p->eq, src + done * p->channels, tmp, n);
		if (debug) {
			dsp_seconds += now() - t0;
			dsp_frames += n;
			if (dsp_frames >= p->rate * 10UL) {
				LOG("EQ load: %.1f%% of real time (%d bands)\n",
				    100.0 * dsp_seconds / ((double)dsp_frames / p->rate), settings.nbands);
				dsp_seconds = 0;
				dsp_frames = 0;
			}
		}
		snd_pcm_sframes_t w = real_writei(pcm, tmp, n);
		if (w < 0)
			return done ? (snd_pcm_sframes_t)done : w;
		done += w;
		if ((snd_pcm_uframes_t)w < n)
			break; /* short write (non-blocking or signal): report what was taken */
	}
	return done;
}

int snd_pcm_close(snd_pcm_t *pcm)
{
	struct pcm_info *p = lookup(pcm, 0);
	if (p)
		p->pcm = NULL;
	return real_close(pcm);
}
