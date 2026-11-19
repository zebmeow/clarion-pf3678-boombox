/* Minimal preload probe: if this loads on the unit, zig-built libraries load at all. */
#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor)) static void hello(void)
{
	const char *path = getenv("BTAEQ_LOG");
	FILE *fp = path ? fopen(path, "a") : NULL;
	if (fp) {
		fputs("hello loaded\n", fp);
		fclose(fp);
	}
}
