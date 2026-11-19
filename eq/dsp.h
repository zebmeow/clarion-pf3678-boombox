/* btaeq DSP core: biquad EQ chain + preamp + peak limiter for interleaved S16 audio.
 * Kept free of ALSA/libc-specific code so it can be unit-tested on any host. */
#ifndef BTAEQ_DSP_H
#define BTAEQ_DSP_H

#define EQ_MAX_FILTERS 12
#define EQ_MAX_CHANNELS 2

enum eq_type { EQ_PEAK, EQ_LOWSHELF, EQ_HIGHSHELF, EQ_LOWPASS, EQ_HIGHPASS };

struct eq_band {
	enum eq_type type;
	float freq;    /* Hz */
	float q;       /* peak: bandwidth Q; shelves: slope-ish Q (0.707 = gentle) */
	float gain_db; /* ignored by lowpass/highpass */
};

struct eq_settings {
	int enabled;
	float preamp_db;
	int limiter;
	int nbands;
	struct eq_band bands[EQ_MAX_FILTERS];
};

struct biquad {
	float b0, b1, b2, a1, a2;            /* normalised by a0 */
	float z1[EQ_MAX_CHANNELS], z2[EQ_MAX_CHANNELS];
};

struct eq_state {
	struct eq_settings cfg;
	unsigned rate, channels;
	struct biquad f[EQ_MAX_FILTERS];
	float preamp;   /* linear */
	float lim_gain; /* current limiter gain, 0..1 */
	float lim_release;
	int force_scalar; /* tests only: bypass the NEON stereo path */
};

/* Parse "key value..." lines; unknown lines are ignored. Returns 0 on success. */
int eq_parse(const char *text, struct eq_settings *out);

/* (Re)compute coefficients for cfg at rate/channels. Filter state is kept when the
 * band layout is unchanged so live edits do not click. */
void eq_configure(struct eq_state *st, const struct eq_settings *cfg, unsigned rate, unsigned channels);

/* Process frames of interleaved S16 from in to out (may alias). */
void eq_process_s16(struct eq_state *st, const short *in, short *out, unsigned long frames);

#endif
