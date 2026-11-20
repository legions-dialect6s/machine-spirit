#ifndef MS_NOW_PLAYING_METER_H
#define MS_NOW_PLAYING_METER_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

// This header is the target's Swift bridging header. The IOProc does no Swift
// runtime work, allocation, locks, logging, or storage of audio samples.
typedef struct MSMeter MSMeter;
typedef struct { float rms; float peak; } MSLevels;
MSMeter * _Nullable MSMeterCreate(void);
void MSMeterDestroy(MSMeter * _Nonnull meter);
MSLevels MSMeterRead(MSMeter * _Nonnull meter);
bool MSMeterHasReceivedAudio(MSMeter * _Nonnull meter);
OSStatus MSMeterIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                      const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                      AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
