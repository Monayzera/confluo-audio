#include "ConfluoDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    _Atomic uint32_t active;
    _Atomic uint32_t mode;
    _Atomic uint64_t rate_bits;
    _Atomic uint64_t epoch;
    _Atomic int64_t write_index;
    _Atomic uint32_t anchor_version;
    _Atomic uint32_t anchor_valid;
    _Atomic uint64_t anchor_host;
    _Atomic uint64_t anchor_frame_bits;
    _Atomic uint32_t gain_bits;
    _Atomic uint64_t fifo_target_bits;
    _Atomic uint32_t peak_bits;
    _Atomic uint32_t max_chunk;
    _Atomic uint64_t read_pos_bits;
    _Atomic uint32_t compensate_latency;
    _Atomic uint32_t reading;
    float *ring;
    uint64_t seen_epoch;
    double pos;
    bool playing;
    bool anchored;
    uint64_t cached_host;
    double cached_frame;
    float gain_current;
    double fifo_average;
} cf_source;

struct cf_mixer {
    uint32_t count;
    uint32_t capacity;
    uint32_t mask;
    double ticks_per_second;
    _Atomic uint32_t master_bits;
    _Atomic uint32_t master_peak_bits;
    _Atomic uint64_t output_rate_bits;
    _Atomic uint64_t output_latency_bits;
    float master_current;
    cf_source *sources;
};

static inline uint64_t double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline double bits_double(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static inline uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static inline double clampd(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}

static inline float hermite(float xm1, float x0, float x1, float x2, float t) {
    float c1 = 0.5f * (x1 - xm1);
    float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

static inline void store_peak_max(_Atomic uint32_t *slot, float value) {
    uint32_t current = atomic_load_explicit(slot, memory_order_relaxed);
    while (bits_float(current) < value) {
        if (atomic_compare_exchange_weak_explicit(slot, &current, float_bits(value), memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }
}

static inline float soft_limit(float x) {
    const float knee = 0.8f;
    float magnitude = fabsf(x);
    if (magnitude <= knee) {
        return x;
    }
    float shaped = knee + (1.0f - knee) * tanhf((magnitude - knee) / (1.0f - knee));
    return x < 0.0f ? -shaped : shaped;
}

cf_mixer *cf_mixer_create(uint32_t source_count, uint32_t capacity_frames, double host_ticks_per_second) {
    if (source_count == 0 || capacity_frames < 1024 || (capacity_frames & (capacity_frames - 1)) != 0 || host_ticks_per_second <= 0.0) {
        return NULL;
    }
    cf_mixer *mixer = calloc(1, sizeof(cf_mixer));
    if (mixer == NULL) {
        return NULL;
    }
    mixer->sources = calloc(source_count, sizeof(cf_source));
    if (mixer->sources == NULL) {
        free(mixer);
        return NULL;
    }
    mixer->count = source_count;
    mixer->capacity = capacity_frames;
    mixer->mask = capacity_frames - 1;
    mixer->ticks_per_second = host_ticks_per_second;
    atomic_store(&mixer->master_bits, float_bits(1.0f));
    mixer->master_current = 1.0f;
    for (uint32_t i = 0; i < source_count; i++) {
        cf_source *source = &mixer->sources[i];
        source->ring = calloc((size_t)capacity_frames * 2, sizeof(float));
        if (source->ring == NULL) {
            cf_mixer_destroy(mixer);
            return NULL;
        }
        atomic_store(&source->gain_bits, float_bits(1.0f));
        atomic_store(&source->fifo_target_bits, double_bits(0.03));
    }
    return mixer;
}

void cf_mixer_destroy(cf_mixer *mixer) {
    if (mixer == NULL) {
        return;
    }
    if (mixer->sources != NULL) {
        for (uint32_t i = 0; i < mixer->count; i++) {
            free(mixer->sources[i].ring);
        }
        free(mixer->sources);
    }
    free(mixer);
}

uint32_t cf_mixer_source_count(const cf_mixer *mixer) {
    return mixer == NULL ? 0 : mixer->count;
}

uint32_t cf_mixer_capacity(const cf_mixer *mixer) {
    return mixer == NULL ? 0 : mixer->capacity;
}

void cf_mixer_set_master_gain(cf_mixer *mixer, float gain) {
    if (mixer == NULL || !isfinite(gain)) {
        return;
    }
    atomic_store_explicit(&mixer->master_bits, float_bits(fmaxf(0.0f, gain)), memory_order_relaxed);
}

void cf_mixer_set_output(cf_mixer *mixer, double sample_rate, double latency_seconds) {
    if (mixer == NULL || !(sample_rate > 0.0) || !isfinite(latency_seconds)) {
        return;
    }
    atomic_store_explicit(&mixer->output_rate_bits, double_bits(sample_rate), memory_order_relaxed);
    atomic_store_explicit(&mixer->output_latency_bits, double_bits(fmax(0.0, latency_seconds)), memory_order_relaxed);
}

double cf_mixer_output_latency(const cf_mixer *mixer) {
    if (mixer == NULL) {
        return 0.0;
    }
    return bits_double(atomic_load_explicit(&((cf_mixer *)mixer)->output_latency_bits, memory_order_relaxed));
}

float cf_mixer_take_master_peak(cf_mixer *mixer) {
    if (mixer == NULL) {
        return 0.0f;
    }
    return bits_float(atomic_exchange_explicit(&mixer->master_peak_bits, 0, memory_order_relaxed));
}

static cf_source *source_at(const cf_mixer *mixer, uint32_t index) {
    if (mixer == NULL || index >= mixer->count) {
        return NULL;
    }
    return &mixer->sources[index];
}

static void invalidate_anchor(cf_source *source) {
    uint32_t version = atomic_load_explicit(&source->anchor_version, memory_order_relaxed);
    atomic_store_explicit(&source->anchor_version, version + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&source->anchor_valid, 0, memory_order_relaxed);
    atomic_store_explicit(&source->anchor_version, version + 2, memory_order_release);
}

void cf_source_begin(cf_mixer *mixer, uint32_t index, cf_mode mode, double sample_rate) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL || !(sample_rate > 0.0)) {
        return;
    }
    atomic_store_explicit(&source->mode, (uint32_t)mode, memory_order_relaxed);
    atomic_store_explicit(&source->rate_bits, double_bits(sample_rate), memory_order_relaxed);
    atomic_store_explicit(&source->write_index, 0, memory_order_relaxed);
    atomic_store_explicit(&source->peak_bits, 0, memory_order_relaxed);
    atomic_store_explicit(&source->max_chunk, 0, memory_order_relaxed);
    atomic_store_explicit(&source->compensate_latency, 1, memory_order_relaxed);
    invalidate_anchor(source);
    atomic_store_explicit(&source->active, 1, memory_order_release);
    atomic_fetch_add_explicit(&source->epoch, 1, memory_order_release);
}

void cf_source_flush(cf_mixer *mixer, uint32_t index) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL) {
        return;
    }
    atomic_store_explicit(&source->write_index, 0, memory_order_relaxed);
    invalidate_anchor(source);
    atomic_fetch_add_explicit(&source->epoch, 1, memory_order_release);
}

void cf_source_end(cf_mixer *mixer, uint32_t index) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL) {
        return;
    }
    atomic_store_explicit(&source->active, 0, memory_order_relaxed);
    atomic_store_explicit(&source->write_index, 0, memory_order_relaxed);
    invalidate_anchor(source);
    atomic_store_explicit(&source->peak_bits, 0, memory_order_relaxed);
    atomic_fetch_add_explicit(&source->epoch, 1, memory_order_release);
}

bool cf_source_is_active(const cf_mixer *mixer, uint32_t index) {
    cf_source *source = source_at(mixer, index);
    return source != NULL && atomic_load_explicit(&source->active, memory_order_relaxed) != 0;
}

int64_t cf_source_write_index(const cf_mixer *mixer, uint32_t index) {
    cf_source *source = source_at(mixer, index);
    return source == NULL ? 0 : atomic_load_explicit(&source->write_index, memory_order_acquire);
}

static void ring_fill(const cf_mixer *mixer, cf_source *source, int64_t start, int64_t count, const float *data) {
    int64_t done = 0;
    while (done < count) {
        uint32_t offset = (uint32_t)((start + done) & mixer->mask);
        int64_t chunk = (int64_t)mixer->capacity - offset;
        if (chunk > count - done) {
            chunk = count - done;
        }
        float *destination = source->ring + (size_t)offset * 2;
        if (data == NULL) {
            memset(destination, 0, (size_t)chunk * 2 * sizeof(float));
        } else {
            memcpy(destination, data + (size_t)done * 2, (size_t)chunk * 2 * sizeof(float));
        }
        done += chunk;
    }
}

bool cf_source_write(cf_mixer *mixer, uint32_t index, int64_t frame_index, const float *interleaved_stereo, uint32_t frames) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL || interleaved_stereo == NULL || frames == 0) {
        return source != NULL;
    }
    if (frames > mixer->capacity / 2) {
        return false;
    }
    int64_t capacity = (int64_t)mixer->capacity;
    int64_t written = atomic_load_explicit(&source->write_index, memory_order_relaxed);
    int64_t start = frame_index;
    int64_t count = frames;
    const float *data = interleaved_stereo;
    if (start < 0) {
        int64_t skip = -start;
        if (skip >= count) {
            return true;
        }
        data += skip * 2;
        count -= skip;
        start = 0;
    }
    int64_t oldest = written - capacity + 1;
    if (start + count <= oldest) {
        return true;
    }
    if (start < oldest) {
        int64_t skip = oldest - start;
        data += skip * 2;
        count -= skip;
        start = oldest;
    }
    if (start > written) {
        if (start - written > capacity / 2) {
            return false;
        }
        ring_fill(mixer, source, written, start - written, NULL);
    }
    ring_fill(mixer, source, start, count, data);
    int64_t end = start + count;
    if (end > written) {
        atomic_store_explicit(&source->write_index, end, memory_order_release);
    }
    return true;
}

void cf_source_append(cf_mixer *mixer, uint32_t index, const float *interleaved_stereo, uint32_t frames) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL) {
        return;
    }
    int64_t written = atomic_load_explicit(&source->write_index, memory_order_relaxed);
    if (frames > atomic_load_explicit(&source->max_chunk, memory_order_relaxed)) {
        atomic_store_explicit(&source->max_chunk, frames, memory_order_relaxed);
    }
    while (frames > 0) {
        uint32_t chunk = frames > mixer->capacity / 2 ? mixer->capacity / 2 : frames;
        cf_source_write(mixer, index, written, interleaved_stereo, chunk);
        written += chunk;
        interleaved_stereo += (size_t)chunk * 2;
        frames -= chunk;
    }
}

void cf_source_set_anchor(cf_mixer *mixer, uint32_t index, uint64_t host_time, double frame_index) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL || !isfinite(frame_index)) {
        return;
    }
    uint32_t version = atomic_load_explicit(&source->anchor_version, memory_order_relaxed);
    atomic_store_explicit(&source->anchor_version, version + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&source->anchor_host, host_time, memory_order_relaxed);
    atomic_store_explicit(&source->anchor_frame_bits, double_bits(frame_index), memory_order_relaxed);
    atomic_store_explicit(&source->anchor_valid, 1, memory_order_relaxed);
    atomic_store_explicit(&source->anchor_version, version + 2, memory_order_release);
}

void cf_source_set_fifo_target(cf_mixer *mixer, uint32_t index, double seconds) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL || !(seconds > 0.0)) {
        return;
    }
    atomic_store_explicit(&source->fifo_target_bits, double_bits(seconds), memory_order_relaxed);
}

void cf_source_set_latency_compensation(cf_mixer *mixer, uint32_t index, bool enabled) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL) {
        return;
    }
    atomic_store_explicit(&source->compensate_latency, enabled ? 1u : 0u, memory_order_relaxed);
}

void cf_source_set_gain(cf_mixer *mixer, uint32_t index, float gain) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL || !isfinite(gain)) {
        return;
    }
    atomic_store_explicit(&source->gain_bits, float_bits(fmaxf(0.0f, gain)), memory_order_relaxed);
}

float cf_source_take_peak(cf_mixer *mixer, uint32_t index) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL) {
        return 0.0f;
    }
    return bits_float(atomic_exchange_explicit(&source->peak_bits, 0, memory_order_relaxed));
}

double cf_source_buffered_seconds(const cf_mixer *mixer, uint32_t index) {
    cf_source *source = source_at(mixer, index);
    if (source == NULL || atomic_load_explicit(&source->active, memory_order_relaxed) == 0 || atomic_load_explicit(&source->reading, memory_order_relaxed) == 0) {
        return -1.0;
    }
    double rate = bits_double(atomic_load_explicit(&source->rate_bits, memory_order_relaxed));
    if (!(rate > 0.0)) {
        return -1.0;
    }
    double position = bits_double(atomic_load_explicit(&source->read_pos_bits, memory_order_relaxed));
    double written = (double)atomic_load_explicit(&source->write_index, memory_order_acquire);
    double buffered = (written - position) / rate;
    return buffered < 0.0 ? 0.0 : buffered;
}

static void refresh_anchor(cf_source *source) {
    uint32_t first = atomic_load_explicit(&source->anchor_version, memory_order_acquire);
    if (first & 1u) {
        return;
    }
    uint32_t valid = atomic_load_explicit(&source->anchor_valid, memory_order_relaxed);
    uint64_t host = atomic_load_explicit(&source->anchor_host, memory_order_relaxed);
    uint64_t frame = atomic_load_explicit(&source->anchor_frame_bits, memory_order_relaxed);
    atomic_thread_fence(memory_order_acquire);
    uint32_t second = atomic_load_explicit(&source->anchor_version, memory_order_relaxed);
    if (first != second) {
        return;
    }
    if (valid == 0) {
        source->anchored = false;
        return;
    }
    source->anchored = true;
    source->cached_host = host;
    source->cached_frame = bits_double(frame);
}

static void render_source(cf_mixer *mixer, cf_source *source, float *left, float *right, uint32_t frames, double output_rate, uint64_t host_time, double latency) {
    if (atomic_load_explicit(&source->active, memory_order_acquire) == 0) {
        source->playing = false;
        source->gain_current = 0.0f;
        atomic_store_explicit(&source->reading, 0, memory_order_relaxed);
        return;
    }
    uint64_t epoch = atomic_load_explicit(&source->epoch, memory_order_acquire);
    if (epoch != source->seen_epoch) {
        source->seen_epoch = epoch;
        source->playing = false;
        source->anchored = false;
        source->pos = 0.0;
        source->gain_current = 0.0f;
    }
    if (!isfinite(source->pos)) {
        source->pos = 0.0;
        source->playing = false;
    }
    double rate = bits_double(atomic_load_explicit(&source->rate_bits, memory_order_relaxed));
    if (!(rate > 0.0)) {
        return;
    }
    int64_t written = atomic_load_explicit(&source->write_index, memory_order_acquire);
    uint32_t mode = atomic_load_explicit(&source->mode, memory_order_relaxed);
    double base = rate / output_rate;
    double step = base;
    bool fade_out = false;
    double resync_position = 0.0;

    if (mode == CF_MODE_TIMED) {
        refresh_anchor(source);
        if (!source->anchored) {
            source->playing = false;
            source->gain_current = 0.0f;
            atomic_store_explicit(&source->reading, 0, memory_order_relaxed);
            return;
        }
        double compensation = atomic_load_explicit(&source->compensate_latency, memory_order_relaxed) ? latency : 0.0;
        double elapsed = (double)(int64_t)(host_time - source->cached_host) / mixer->ticks_per_second + compensation;
        double desired = source->cached_frame + elapsed * rate;
        if (!source->playing) {
            source->pos = desired;
            source->playing = true;
            source->gain_current = 0.0f;
        } else if (fabs(source->pos - desired) > 0.1 * rate) {
            fade_out = true;
            resync_position = desired + (double)frames * base;
        } else {
            double error = (source->pos - desired) / rate;
            step = base * (1.0 - clampd(error * 0.1, -0.002, 0.005));
        }
    } else {
        double configured = bits_double(atomic_load_explicit(&source->fifo_target_bits, memory_order_relaxed)) * rate;
        double chunk = (double)atomic_load_explicit(&source->max_chunk, memory_order_relaxed);
        double minimum = 1.25 * ((double)frames * base + chunk) + 64.0;
        double target = configured > minimum ? configured : minimum;
        double fill = (double)written - source->pos;
        if (!source->playing) {
            if (fill < target + 4.0) {
                atomic_store_explicit(&source->reading, 0, memory_order_relaxed);
                return;
            }
            source->playing = true;
            source->gain_current = 0.0f;
            source->fifo_average = fill;
        }
        if (fill > target + 0.25 * rate) {
            source->pos = (double)written - target;
            fill = target;
            source->fifo_average = target;
            source->gain_current = 0.0f;
        }
        source->fifo_average += (fill - source->fifo_average) * 0.05;
        double error = (source->fifo_average - target) / rate;
        step = base * (1.0 + clampd(error * 0.5, -0.005, 0.005));
    }

    float target_gain = fade_out ? 0.0f : bits_float(atomic_load_explicit(&source->gain_bits, memory_order_relaxed));
    float gain = source->gain_current;
    float gain_step = (target_gain - gain) / (float)frames;
    int64_t oldest = written - (int64_t)mixer->capacity + 4;
    double pos = source->pos;
    float peak = 0.0f;
    const float *ring = source->ring;
    uint32_t mask = mixer->mask;

    for (uint32_t i = 0; i < frames; i++) {
        gain += gain_step;
        double floor_pos = floor(pos);
        int64_t integer = (int64_t)floor_pos;
        if (integer - 1 >= 0 && integer - 1 >= oldest && integer + 2 < written) {
            float t = (float)(pos - floor_pos);
            const float *a = ring + (size_t)((uint64_t)(integer - 1) & mask) * 2;
            const float *b = ring + (size_t)((uint64_t)integer & mask) * 2;
            const float *c = ring + (size_t)((uint64_t)(integer + 1) & mask) * 2;
            const float *d = ring + (size_t)((uint64_t)(integer + 2) & mask) * 2;
            float l = hermite(a[0], b[0], c[0], d[0], t) * gain;
            float r = hermite(a[1], b[1], c[1], d[1], t) * gain;
            if (!isfinite(l) || !isfinite(r)) {
                l = 0.0f;
                r = 0.0f;
            }
            left[i] += l;
            right[i] += r;
            float magnitude = fmaxf(fabsf(l), fabsf(r));
            if (magnitude > peak) {
                peak = magnitude;
            }
        } else if (mode == CF_MODE_FIFO && integer + 2 >= written) {
            source->playing = false;
            break;
        }
        pos += step;
    }
    source->pos = fade_out ? resync_position : pos;
    source->gain_current = (source->playing && !fade_out) ? target_gain : 0.0f;
    atomic_store_explicit(&source->read_pos_bits, double_bits(source->pos), memory_order_relaxed);
    atomic_store_explicit(&source->reading, source->playing ? 1u : 0u, memory_order_relaxed);
    store_peak_max(&source->peak_bits, peak);
}

void cf_mixer_render(cf_mixer *mixer, float *left, float *right, uint32_t frames, uint64_t host_time) {
    if (left == NULL || right == NULL || frames == 0) {
        return;
    }
    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));
    if (mixer == NULL) {
        return;
    }
    double output_rate = bits_double(atomic_load_explicit(&mixer->output_rate_bits, memory_order_relaxed));
    double output_latency_seconds = bits_double(atomic_load_explicit(&mixer->output_latency_bits, memory_order_relaxed));
    if (!(output_rate > 0.0)) {
        return;
    }
    for (uint32_t i = 0; i < mixer->count; i++) {
        render_source(mixer, &mixer->sources[i], left, right, frames, output_rate, host_time, output_latency_seconds);
    }
    float target = bits_float(atomic_load_explicit(&mixer->master_bits, memory_order_relaxed));
    float gain = mixer->master_current;
    float gain_step = (target - gain) / (float)frames;
    float peak = 0.0f;
    for (uint32_t i = 0; i < frames; i++) {
        gain += gain_step;
        float l = soft_limit(left[i] * gain);
        float r = soft_limit(right[i] * gain);
        left[i] = l;
        right[i] = r;
        float magnitude = fmaxf(fabsf(l), fabsf(r));
        if (magnitude > peak) {
            peak = magnitude;
        }
    }
    mixer->master_current = target;
    store_peak_max(&mixer->master_peak_bits, peak);
}
