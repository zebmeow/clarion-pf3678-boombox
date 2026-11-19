/* Host-side tests for the btaeq DSP core: cc -O2 -o test_dsp test_dsp.c dsp.c -lm */
#include "dsp.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 44100
#define N (RATE / 2)

static int failures;

static void check(int ok, const char *what)
{
	printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok)
		failures++;
}

/* Gain in dB measured by running a stereo sine at freq through the EQ. */
static double measure_db(const char *conf, double freq, double amp, int *clipped)
{
	static short in[N * 2], out[N * 2];
	struct eq_settings s;
	struct eq_state st;
	memset(&st, 0, sizeof(st));
	eq_parse(conf, &s);
	eq_configure(&st, &s, RATE, 2);
	for (int i = 0; i < N; i++)
		in[2 * i] = in[2 * i + 1] = (short)lrint(amp * 32767 * sin(2 * M_PI * freq * i / RATE));
	eq_process_s16(&st, in, out, N);

	double ein = 0, eout = 0;
	int clip = 0;
	for (int i = N / 2; i < N; i++) { /* skip the filter settling time */
		ein += (double)in[2 * i] * in[2 * i];
		eout += (double)out[2 * i] * out[2 * i];
		if (out[2 * i] == 32767 || out[2 * i] == -32768)
			clip++;
	}
	if (clipped)
		*clipped = clip;
	return 10 * log10(eout / ein);
}

int main(void)
{
	/* flat chain must be bit-transparent apart from rounding */
	{
		static short in[4096], out[4096];
		struct eq_settings s;
		struct eq_state st;
		memset(&st, 0, sizeof(st));
		eq_parse("preamp 0\nlimiter 0\npeak 1000 1 0\nlowshelf 100 0.7 0\n", &s);
		eq_configure(&st, &s, RATE, 2);
		for (int i = 0; i < 4096; i++)
			in[i] = (short)(rand() % 40000 - 20000);
		eq_process_s16(&st, in, out, 2048);
		int maxdiff = 0;
		for (int i = 0; i < 4096; i++)
			if (abs(out[i] - in[i]) > maxdiff)
				maxdiff = abs(out[i] - in[i]);
		printf("      flat chain max sample difference: %d\n", maxdiff);
		check(maxdiff <= 1, "flat EQ is transparent (<=1 LSB)");
	}

	const char *conf = "limiter 0\npeak 1000 1.0 6\n";
	double g1k = measure_db(conf, 1000, 0.25, NULL), g100 = measure_db(conf, 100, 0.25, NULL);
	printf("      peak +6 dB @1k: %.2f dB at 1 kHz, %.2f dB at 100 Hz\n", g1k, g100);
	check(fabs(g1k - 6) < 0.3 && fabs(g100) < 0.5, "peaking filter boosts only around its centre");

	conf = "limiter 0\nlowshelf 120 0.707 6\n";
	double l40 = measure_db(conf, 40, 0.25, NULL), l5k = measure_db(conf, 5000, 0.25, NULL);
	printf("      low shelf +6: %.2f dB at 40 Hz, %.2f dB at 5 kHz\n", l40, l5k);
	check(fabs(l40 - 6) < 0.6 && fabs(l5k) < 0.3, "low shelf lifts lows, leaves highs");

	conf = "limiter 0\nhighpass 50 0.707\n";
	double h20 = measure_db(conf, 20, 0.25, NULL), h1k = measure_db(conf, 1000, 0.25, NULL);
	printf("      high-pass 50 Hz: %.2f dB at 20 Hz, %.2f dB at 1 kHz\n", h20, h1k);
	check(h20 < -14 && fabs(h1k) < 0.2, "high-pass protects speakers from deep bass");

	int clipped;
	conf = "preamp 0\nlimiter 0\nlowshelf 120 0.707 12\n";
	measure_db(conf, 60, 0.9, &clipped);
	printf("      +12 dB bass on a loud 60 Hz tone without limiter: %d clipped samples\n", clipped);
	conf = "preamp 0\nlimiter 1\nlowshelf 120 0.707 12\n";
	measure_db(conf, 60, 0.9, &clipped);
	check(clipped == 0, "limiter prevents clipping on heavy boost");

	/* the NEON stereo path must match the scalar path, also when fed in small chunks */
	{
		const char *cfg = "preamp -3\nhighpass 45 0.707\nlowshelf 100 0.7 6\npeak 250 1.2 -2\n"
				  "peak 1000 1 1.5\npeak 3500 2 -3\nhighshelf 9000 0.7 3\n";
		static short in[N * 2], a[N * 2], b[N * 2];
		struct eq_settings s;
		struct eq_state sa, sb;
		memset(&sa, 0, sizeof(sa));
		memset(&sb, 0, sizeof(sb));
		sb.force_scalar = 1;
		eq_parse(cfg, &s);
		eq_configure(&sa, &s, RATE, 2);
		eq_configure(&sb, &s, RATE, 2);
		for (int i = 0; i < N * 2; i++)
			in[i] = (short)((rand() % 52000) - 26000);
		for (int off = 0; off < N; off += 333) {
			int n = N - off < 333 ? N - off : 333;
			eq_process_s16(&sa, in + off * 2, a + off * 2, n);
			eq_process_s16(&sb, in + off * 2, b + off * 2, n);
		}
		int maxdiff = 0;
		for (int i = 0; i < N * 2; i++)
			if (abs(a[i] - b[i]) > maxdiff)
				maxdiff = abs(a[i] - b[i]);
		printf("      NEON vs scalar max sample difference: %d\n", maxdiff);
		check(maxdiff <= 2, "NEON stereo path matches scalar path across chunked calls");
	}

	struct eq_settings s;
	eq_parse("enabled 0\npreamp -99\npeak 0 1 3\nbogus line\npeak 1000 1 99\n", &s);
	check(s.enabled == 0 && s.preamp_db == -24 && s.nbands == 1 && s.bands[0].gain_db == 24,
	      "parser clamps values and skips invalid lines");

	printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASSED", failures, failures == 1 ? "" : "s");
	return failures != 0;
}
