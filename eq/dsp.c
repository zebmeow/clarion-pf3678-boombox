/* btaeq DSP core. Filters are the RBJ "Audio EQ Cookbook" biquads in transposed
 * direct form II; the limiter is a simple instant-attack peak limiter so boosted
 * bass cannot hard-clip the S16 output. */
#include "dsp.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMIT_CEIL 0.97f      /* about -0.26 dBFS */
#define LIMIT_RELEASE_MS 120.0f

static float db_to_lin(float db)
{
	return powf(10.0f, db / 20.0f);
}

static void biquad_design(struct biquad *f, const struct eq_band *b, unsigned rate)
{
	float freq = b->freq, q = b->q > 0.05f ? b->q : 0.05f;
	float nyq = rate * 0.49f;
	if (freq > nyq)
		freq = nyq;
	if (freq < 10.0f)
		freq = 10.0f;

	float A = powf(10.0f, b->gain_db / 40.0f);
	float w0 = 2.0f * (float)M_PI * freq / rate;
	float cw = cosf(w0), sw = sinf(w0);
	float alpha = sw / (2.0f * q);
	float b0, b1, b2, a0, a1, a2;

	switch (b->type) {
	case EQ_LOWSHELF: {
		float s = 2.0f * sqrtf(A) * alpha;
		b0 = A * ((A + 1) - (A - 1) * cw + s);
		b1 = 2 * A * ((A - 1) - (A + 1) * cw);
		b2 = A * ((A + 1) - (A - 1) * cw - s);
		a0 = (A + 1) + (A - 1) * cw + s;
		a1 = -2 * ((A - 1) + (A + 1) * cw);
		a2 = (A + 1) + (A - 1) * cw - s;
		break;
	}
	case EQ_HIGHSHELF: {
		float s = 2.0f * sqrtf(A) * alpha;
		b0 = A * ((A + 1) + (A - 1) * cw + s);
		b1 = -2 * A * ((A - 1) + (A + 1) * cw);
		b2 = A * ((A + 1) + (A - 1) * cw - s);
		a0 = (A + 1) - (A - 1) * cw + s;
		a1 = 2 * ((A - 1) - (A + 1) * cw);
		a2 = (A + 1) - (A - 1) * cw - s;
		break;
	}
	case EQ_LOWPASS:
		b0 = (1 - cw) / 2;
		b1 = 1 - cw;
		b2 = (1 - cw) / 2;
		a0 = 1 + alpha;
		a1 = -2 * cw;
		a2 = 1 - alpha;
		break;
	case EQ_HIGHPASS:
		b0 = (1 + cw) / 2;
		b1 = -(1 + cw);
		b2 = (1 + cw) / 2;
		a0 = 1 + alpha;
		a1 = -2 * cw;
		a2 = 1 - alpha;
		break;
	default: /* EQ_PEAK */
		b0 = 1 + alpha * A;
		b1 = -2 * cw;
		b2 = 1 - alpha * A;
		a0 = 1 + alpha / A;
		a1 = -2 * cw;
		a2 = 1 - alpha / A;
		break;
	}
	f->b0 = b0 / a0;
	f->b1 = b1 / a0;
	f->b2 = b2 / a0;
	f->a1 = a1 / a0;
	f->a2 = a2 / a0;
}

static int parse_type(const char *s, enum eq_type *t)
{
	static const struct { const char *name; enum eq_type type; } names[] = {
		{ "peak", EQ_PEAK }, { "lowshelf", EQ_LOWSHELF }, { "highshelf", EQ_HIGHSHELF },
		{ "lowpass", EQ_LOWPASS }, { "highpass", EQ_HIGHPASS },
	};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (strcmp(s, names[i].name) == 0) {
			*t = names[i].type;
			return 1;
		}
	}
	return 0;
}

int eq_parse(const char *text, struct eq_settings *out)
{
	memset(out, 0, sizeof(*out));
	out->enabled = 1;
	out->limiter = 1;

	const char *p = text;
	while (*p) {
		char line[160];
		size_t n = strcspn(p, "\n");
		size_t len = n < sizeof(line) - 1 ? n : sizeof(line) - 1;
		memcpy(line, p, len);
		line[len] = '\0';
		p += n + (p[n] == '\n');

		char *hash = strchr(line, '#');
		if (hash)
			*hash = '\0';

		char key[16];
		float a, b, c;
		enum eq_type type;
		if (sscanf(line, "%15s", key) != 1)
			continue;
		if (strcmp(key, "enabled") == 0 && sscanf(line, "%*s %f", &a) == 1)
			out->enabled = a != 0;
		else if (strcmp(key, "preamp") == 0 && sscanf(line, "%*s %f", &a) == 1)
			out->preamp_db = a;
		else if (strcmp(key, "limiter") == 0 && sscanf(line, "%*s %f", &a) == 1)
			out->limiter = a != 0;
		else if (parse_type(key, &type) && out->nbands < EQ_MAX_FILTERS) {
			c = 0;
			if (sscanf(line, "%*s %f %f %f", &a, &b, &c) >= 2 && a > 0 && b > 0) {
				struct eq_band *band = &out->bands[out->nbands++];
				band->type = type;
				band->freq = a;
				band->q = b;
				band->gain_db = c < -24 ? -24 : (c > 24 ? 24 : c);
			}
		}
	}
	if (out->preamp_db < -24)
		out->preamp_db = -24;
	if (out->preamp_db > 12)
		out->preamp_db = 12;
	return 0;
}

static int same_layout(const struct eq_settings *a, const struct eq_settings *b)
{
	if (a->nbands != b->nbands)
		return 0;
	for (int i = 0; i < a->nbands; i++)
		if (a->bands[i].type != b->bands[i].type)
			return 0;
	return 1;
}

void eq_configure(struct eq_state *st, const struct eq_settings *cfg, unsigned rate, unsigned channels)
{
	int keep = rate == st->rate && channels == st->channels && same_layout(cfg, &st->cfg);

	st->cfg = *cfg;
	st->rate = rate;
	st->channels = channels > EQ_MAX_CHANNELS ? EQ_MAX_CHANNELS : channels;
	st->preamp = db_to_lin(cfg->preamp_db);
	st->lim_release = 1.0f - expf(-1.0f / (LIMIT_RELEASE_MS * 0.001f * (rate ? rate : 44100)));
	if (!keep) {
		memset(st->f, 0, sizeof(st->f));
		st->lim_gain = 1.0f;
	}
	for (int i = 0; i < cfg->nbands; i++)
		biquad_design(&st->f[i], &cfg->bands[i], rate ? rate : 44100);
}

static short to_s16(float v)
{
	v *= 32768.0f;
	v += v >= 0.0f ? 0.5f : -0.5f; /* round half away from zero without a libm call */
	return v > 32767.0f ? 32767 : (v < -32768.0f ? -32768 : (short)v);
}

static float limiter_gain(struct eq_state *st, float peak)
{
	/* instant attack, exponential release; the same gain is applied to all channels
	 * so the stereo image does not shift */
	if (!st->cfg.limiter)
		return 1.0f;
	float want = peak > LIMIT_CEIL ? LIMIT_CEIL / peak : 1.0f;
	if (want < st->lim_gain)
		st->lim_gain = want;
	else
		st->lim_gain += (want - st->lim_gain) * st->lim_release;
	return st->lim_gain;
}

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>

/* Stereo fast path: L and R share one 2-lane NEON vector, so every band runs both
 * channels at once. The Cortex-A8's VFP unit is not pipelined, so this matters there. */
static void process_stereo_neon(struct eq_state *st, const short *in, short *out, unsigned long frames)
{
	const int nb = st->cfg.nbands;
	const float32x2_t scale_in = vdup_n_f32(st->preamp / 32768.0f);
	float32x2_t b0[EQ_MAX_FILTERS], b1[EQ_MAX_FILTERS], b2[EQ_MAX_FILTERS];
	float32x2_t a1[EQ_MAX_FILTERS], a2[EQ_MAX_FILTERS], z1[EQ_MAX_FILTERS], z2[EQ_MAX_FILTERS];

	for (int k = 0; k < nb; k++) {
		const struct biquad *f = &st->f[k];
		b0[k] = vdup_n_f32(f->b0);
		b1[k] = vdup_n_f32(f->b1);
		b2[k] = vdup_n_f32(f->b2);
		a1[k] = vdup_n_f32(f->a1);
		a2[k] = vdup_n_f32(f->a2);
		/* lane-wise moves instead of vld1/vst1: zig 0.16's LLVM crashes on those
		 * for armv7 softfp ("Do not know how to split this operator's operand") */
		float32x2_t t1 = { f->z1[0], f->z1[1] }, t2 = { f->z2[0], f->z2[1] };
		z1[k] = t1;
		z2[k] = t2;
	}

	for (unsigned long i = 0; i < frames; i++) {
		float32x2_t v = { (float)in[2 * i], (float)in[2 * i + 1] };
		v = vmul_f32(v, scale_in);
		for (int k = 0; k < nb; k++) {
			float32x2_t y = vmla_f32(z1[k], b0[k], v);
			z1[k] = vmls_f32(vmla_f32(z2[k], b1[k], v), a1[k], y);
			z2[k] = vmls_f32(vmul_f32(b2[k], v), a2[k], y);
			v = y;
		}
		float l = vget_lane_f32(v, 0), r = vget_lane_f32(v, 1);
		float peak = fabsf(l) > fabsf(r) ? fabsf(l) : fabsf(r);
		float g = limiter_gain(st, peak);
		out[2 * i] = to_s16(l * g);
		out[2 * i + 1] = to_s16(r * g);
	}

	for (int k = 0; k < nb; k++) {
		st->f[k].z1[0] = vget_lane_f32(z1[k], 0);
		st->f[k].z1[1] = vget_lane_f32(z1[k], 1);
		st->f[k].z2[0] = vget_lane_f32(z2[k], 0);
		st->f[k].z2[1] = vget_lane_f32(z2[k], 1);
	}
}
#endif

void eq_process_s16(struct eq_state *st, const short *in, short *out, unsigned long frames)
{
	const unsigned ch = st->channels;
	const int nb = st->cfg.nbands;
	const float scale_in = st->preamp / 32768.0f;
	float x[EQ_MAX_CHANNELS];

	if (!st->cfg.enabled || ch == 0) {
		if (out != in)
			memmove(out, in, frames * (ch ? ch : 1) * sizeof(short));
		return;
	}

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
	if (ch == 2 && !st->force_scalar) {
		process_stereo_neon(st, in, out, frames);
		return;
	}
#endif

	for (unsigned long i = 0; i < frames; i++) {
		float peak = 0.0f;
		for (unsigned c = 0; c < ch; c++) {
			float v = in[i * ch + c] * scale_in;
			for (int k = 0; k < nb; k++) {
				struct biquad *f = &st->f[k];
				float y = f->b0 * v + f->z1[c];
				/* same evaluation order as the NEON path so both round identically */
				f->z1[c] = (f->z2[c] + f->b1 * v) - f->a1 * y;
				f->z2[c] = f->b2 * v - f->a2 * y;
				v = y;
			}
			x[c] = v;
			float a = fabsf(v);
			if (a > peak)
				peak = a;
		}

		float g = limiter_gain(st, peak);
		for (unsigned c = 0; c < ch; c++)
			out[i * ch + c] = to_s16(x[c] * g);
	}
}
