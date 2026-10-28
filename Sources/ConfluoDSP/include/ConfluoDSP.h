#ifndef CONFLUO_DSP_H
#define CONFLUO_DSP_H

#include <stdbool.h>
#include <stdint.h>

typedef struct cf_mixer cf_mixer;

typedef enum {
    CF_MODE_TIMED = 0,
    CF_MODE_FIFO = 1
} cf_mode;

cf_mixer *cf_mixer_create(uint32_t source_count, uint32_t capacity_frames, double host_ticks_per_second);
void cf_mixer_destroy(cf_mixer *mixer);
uint32_t cf_mixer_source_count(const cf_mixer *mixer);
uint32_t cf_mixer_capacity(const cf_mixer *mixer);

void cf_mixer_set_master_gain(cf_mixer *mixer, float gain);
void cf_mixer_set_output(cf_mixer *mixer, double sample_rate, double latency_seconds);
float cf_mixer_take_master_peak(cf_mixer *mixer);

void cf_source_begin(cf_mixer *mixer, uint32_t source, cf_mode mode, double sample_rate);
void cf_source_flush(cf_mixer *mixer, uint32_t source);
void cf_source_end(cf_mixer *mixer, uint32_t source);
bool cf_source_is_active(const cf_mixer *mixer, uint32_t source);
int64_t cf_source_write_index(const cf_mixer *mixer, uint32_t source);
bool cf_source_write(cf_mixer *mixer, uint32_t source, int64_t index, const float *interleaved_stereo, uint32_t frames);
void cf_source_append(cf_mixer *mixer, uint32_t source, const float *interleaved_stereo, uint32_t frames);
void cf_source_set_anchor(cf_mixer *mixer, uint32_t source, uint64_t host_time, double frame_index);
void cf_source_set_fifo_target(cf_mixer *mixer, uint32_t source, double seconds);
void cf_source_set_gain(cf_mixer *mixer, uint32_t source, float gain);
float cf_source_take_peak(cf_mixer *mixer, uint32_t source);

void cf_mixer_render(cf_mixer *mixer, float *left, float *right, uint32_t frames, uint64_t host_time);

#endif
