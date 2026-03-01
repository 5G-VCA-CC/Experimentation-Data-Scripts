#define _GNU_SOURCE
#include <time.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>

static inline uint64_t now_ns(clockid_t clk) {
  struct timespec ts;
  clock_gettime(clk, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline void sleep_abs_ns(clockid_t clk, uint64_t t_ns) {
  struct timespec ts;
  ts.tv_sec  = (time_t)(t_ns / 1000000000ull);
  ts.tv_nsec = (long)(t_ns % 1000000000ull);
  while (clock_nanosleep(clk, TIMER_ABSTIME, &ts, NULL) == EINTR) {}
}

int main(int argc, char** argv) {
  // default: monotonic_raw if possible
  clockid_t clk = CLOCK_MONOTONIC;
#ifdef CLOCK_MONOTONIC_RAW
  clk = CLOCK_MONOTONIC_RAW;
#endif

  if (argc == 1) {
    printf("%llu\n", (unsigned long long)now_ns(clk));
    return 0;
  }

  if (argc == 3 && strcmp(argv[1], "sleepabs") == 0) {
    uint64_t t = strtoull(argv[2], NULL, 10);
    sleep_abs_ns(clk, t);
    return 0;
  }

  fprintf(stderr, "usage:\n  %s            # print now_ns\n  %s sleepabs <t_ns>\n", argv[0], argv[0]);
  return 2;
}
