#include "NowPlayingMeter.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>

_Static_assert(sizeof(MSLevels) == sizeof(uint64_t), "RMS and peak must fit one atomic word");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio metering requires lock-free 64-bit atomics");
struct MSMeter {
    _Atomic(uint64_t) levels;
    _Atomic(uint64_t) timestamp;
    double ticksPerSecond;
};
MSMeter *MSMeterCreate(void) {
    MSMeter *meter = calloc(1, sizeof(MSMeter));
    if (!meter) return NULL;
    atomic_init(&meter->levels, 0);
    atomic_init(&meter->timestamp, 0);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    meter->ticksPerSecond = 1e9 * timebase.denom / timebase.numer;
    return meter;
}
void MSMeterDestroy(MSMeter *meter) { free(meter); }
MSLevels MSMeterRead(MSMeter *meter) {
    // A stopped/stalled stream must not leave a frozen illuminated meter.
    uint64_t timestamp = atomic_load_explicit(&meter->timestamp, memory_order_relaxed);
    if (!timestamp || (mach_absolute_time() - timestamp) / meter->ticksPerSecond > 0.25)
        return (MSLevels){0, 0};
    uint64_t packed = atomic_load_explicit(&meter->levels, memory_order_relaxed);
    MSLevels levels;
    memcpy(&levels, &packed, sizeof(levels));
    return levels;
}
bool MSMeterHasReceivedAudio(MSMeter *meter) {
    return atomic_load_explicit(&meter->timestamp, memory_order_relaxed) != 0;
}
OSStatus MSMeterIOProc(AudioObjectID device, const AudioTimeStamp *now,
                      const AudioBufferList *input, const AudioTimeStamp *inputTime,
                      AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    MSMeter *meter = context;
    if (!meter || !input) return noErr;
    double squares = 0;
    float peak = 0;
    size_t count = 0;
    // The tap format is validated as native packed Float32 before starting IO.
    for (UInt32 b = 0; b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (!buffer->mData) continue;
        const float *samples = buffer->mData;
        size_t n = buffer->mDataByteSize / sizeof(float);
        for (size_t i = 0; i < n; ++i) {
            float sample = isfinite(samples[i]) ? samples[i] : 0;
            squares += (double)sample * sample;
            peak = fmaxf(peak, fabsf(sample));
        }
        count += n;
    }
    if (count) {
        MSLevels levels = { (float)sqrt(squares / count), peak };
        uint64_t packed;
        memcpy(&packed, &levels, sizeof(packed));
        atomic_store_explicit(&meter->levels, packed, memory_order_relaxed);
        atomic_store_explicit(&meter->timestamp, mach_absolute_time(), memory_order_relaxed);
    }
    return noErr;
}
