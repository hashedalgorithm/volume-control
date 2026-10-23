// Loads VolumeControlMicMix.driver exactly as coreaudiod would (CFPlugIn
// factory -> QueryInterface -> AudioServerPlugInDriverInterface), then
// exercises Initialize, a spread of HasProperty/GetPropertyData calls per
// object, and one full read/write IO cycle through the ring buffer -- all
// in a disposable process, with no system install required.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

static int gFailures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); gFailures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

static void checkProperty(AudioServerPlugInDriverInterface **iface, AudioObjectID obj,
                           AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, const char *label)
{
    AudioObjectPropertyAddress addr = { sel, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = (*iface)->GetPropertyDataSize(iface, obj, 0, &addr, 0, NULL, &size);
    char buf[256];
    snprintf(buf, sizeof(buf), "%s: GetPropertyDataSize", label);
    CHECK(status == noErr, buf);
    if (status != noErr) return;

    void *data = malloc(size);
    UInt32 used = 0;
    status = (*iface)->GetPropertyData(iface, obj, 0, &addr, 0, NULL, size, &used, data);
    snprintf(buf, sizeof(buf), "%s: GetPropertyData", label);
    CHECK(status == noErr, buf);
    free(data);
}

int main(void)
{
    CFURLRef bundleURL = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8 *)"VolumeControlMicMix.driver", (CFIndex)strlen("VolumeControlMicMix.driver"), true);
    CFBundleRef bundle = CFBundleCreate(NULL, bundleURL);
    CHECK(bundle != NULL, "CFBundleCreate");
    if (!bundle) return 1;

    CFUUIDRef factoryUUID = CFUUIDCreateFromString(NULL, CFSTR("E6485DA9-92C8-4C48-9926-16C9722BFF62"));
    void *rawFactory = CFBundleGetFunctionPointerForName(bundle, CFSTR("VolumeControlMicMixFactory"));
    CHECK(rawFactory != NULL, "found factory symbol");
    if (!rawFactory) return 1;

    typedef void *(*FactoryFn)(CFAllocatorRef, CFUUIDRef);
    FactoryFn factory = (FactoryFn)rawFactory;
    CFUUIDRef typeUUID = CFUUIDCreateFromString(NULL, CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
    AudioServerPlugInDriverInterface **iface = (AudioServerPlugInDriverInterface **)factory(NULL, typeUUID);
    CHECK(iface != NULL, "factory returned driver interface");
    if (!iface) return 1;

    OSStatus status = (*iface)->Initialize(iface, NULL);
    CHECK(status == noErr, "Initialize");

    const AudioObjectID kPlugIn = kAudioObjectPlugInObject;
    const AudioObjectID kDevice = 2;
    const AudioObjectID kInputStream = 3;
    const AudioObjectID kOutputStream = 4;

    checkProperty(iface, kPlugIn, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, "plugin.deviceList");
    checkProperty(iface, kDevice, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, "device.name");
    checkProperty(iface, kDevice, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, "device.uid");
    checkProperty(iface, kDevice, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, "device.streams.input");
    checkProperty(iface, kDevice, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, "device.streams.output");
    checkProperty(iface, kDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "device.sampleRate");
    checkProperty(iface, kDevice, kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal, "device.zeroTimeStampPeriod");
    checkProperty(iface, kInputStream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, "inputStream.format");
    checkProperty(iface, kOutputStream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, "outputStream.format");

    Float64 sampleTime = 0; UInt64 hostTime = 0, seed = 0;
    status = (*iface)->GetZeroTimeStamp(iface, kDevice, 1, &sampleTime, &hostTime, &seed);
    CHECK(status == noErr, "GetZeroTimeStamp");

    status = (*iface)->StartIO(iface, kDevice, 1);
    CHECK(status == noErr, "StartIO");

    // Write 480 frames (10ms @ 48kHz) of a known tone, then read them back.
    const UInt32 frames = 480;
    const UInt32 channels = 2;
    float *writeBuf = (float *)malloc(frames * channels * sizeof(float));
    for (UInt32 i = 0; i < frames * channels; i++) writeBuf[i] = 0.5f;

    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mOutputTime.mSampleTime = sampleTime;
    cycle.mInputTime.mSampleTime = sampleTime;

    status = (*iface)->DoIOOperation(iface, kDevice, kOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
                                      frames, &cycle, writeBuf, NULL);
    CHECK(status == noErr, "DoIOOperation WriteMix");

    float *readBuf = (float *)calloc(frames * channels, sizeof(float));
    status = (*iface)->DoIOOperation(iface, kDevice, kInputStream, 1, kAudioServerPlugInIOOperationReadInput,
                                      frames, &cycle, readBuf, NULL);
    CHECK(status == noErr, "DoIOOperation ReadInput");

    int roundTripOK = 1;
    for (UInt32 i = 0; i < frames * channels; i++) {
        if (readBuf[i] != 0.5f) { roundTripOK = 0; break; }
    }
    CHECK(roundTripOK, "round-trip samples match what was written");

    status = (*iface)->StopIO(iface, kDevice, 1);
    CHECK(status == noErr, "StopIO");

    free(writeBuf);
    free(readBuf);

    printf(gFailures == 0 ? "\nALL CHECKS PASSED\n" : "\n%d CHECK(S) FAILED\n", gFailures);
    return gFailures == 0 ? 0 : 1;
}
