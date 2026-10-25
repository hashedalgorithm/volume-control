// VolumeControlMicMix.c
//
// Minimal CoreAudio AudioServerPlugIn (HAL plugin): a single 2-channel,
// Float32 loopback device. VolumeControl.app is the only intended writer
// (it mixes the real mic + chosen apps' tapped audio and writes the result
// here); any call app (FaceTime, WhatsApp, Zoom, ...) that selects this
// device as its microphone is the reader. Because there is exactly one
// writer by design, the driver itself does no mixing -- it is a plain ring
// buffer, which keeps the real-time IO path simple and avoids the far
// riskier job of a general-purpose summing driver.
//
// Built directly from Apple's public <CoreAudio/AudioServerPlugIn.h> and
// <CoreAudio/AudioHardwareBase.h> contracts (see those headers for the
// authoritative behavior of every callback below).

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <stdatomic.h>

#pragma mark - Constants

static const AudioObjectID kPlugInObjectID = kAudioObjectPlugInObject;
static const AudioObjectID kDeviceObjectID  = 2;
static const AudioObjectID kInputStreamID   = 3;
static const AudioObjectID kOutputStreamID  = 4;

#define kDeviceUID        CFSTR("com.volumecontrol.micmix")
#define kDeviceModelUID   CFSTR("com.volumecontrol.micmix.model")
#define kDeviceName       CFSTR("Volume Control Mic Mix")
#define kManufacturerName CFSTR("Volume Control")

static const Float64 kSampleRate        = 48000.0;
static const UInt32  kChannelCount      = 2;
static const UInt32  kRingFrames        = 48000 * 2; // 2 s ring, generous vs. typical ~10-40ms IO buffers
static const UInt32  kZeroTimeStampPeriod = 48000;   // 1 s; must be >= 10923 per the header contract

#pragma mark - State

typedef struct {
    pthread_mutex_t lock;
    float *samples;              // interleaved, kChannelCount per frame
    _Atomic UInt64 writeSampleTime; // in frames, monotonically increasing
    _Atomic UInt64 readSampleTime;

    UInt32 startedClientCount;
    UInt64 anchorHostTime;
    Float64 anchorSampleTime;

    AudioServerPlugInHostRef host;
} DriverState;

static DriverState gState;

#pragma mark - Ring buffer helpers

static void RingWrite(const float *src, UInt32 frameCount, UInt64 atSampleTime)
{
    pthread_mutex_lock(&gState.lock);
    for (UInt32 frame = 0; frame < frameCount; frame++) {
        UInt64 slot = (atSampleTime + frame) % kRingFrames;
        memcpy(&gState.samples[slot * kChannelCount], &src[frame * kChannelCount], kChannelCount * sizeof(float));
    }
    pthread_mutex_unlock(&gState.lock);
    atomic_store(&gState.writeSampleTime, atSampleTime + frameCount);
}

static void RingRead(float *dst, UInt32 frameCount, UInt64 atSampleTime)
{
    pthread_mutex_lock(&gState.lock);
    UInt64 writeTime = atomic_load(&gState.writeSampleTime);
    for (UInt32 frame = 0; frame < frameCount; frame++) {
        UInt64 sampleTime = atSampleTime + frame;
        if (sampleTime < writeTime && (writeTime - sampleTime) <= kRingFrames) {
            UInt64 slot = sampleTime % kRingFrames;
            memcpy(&dst[frame * kChannelCount], &gState.samples[slot * kChannelCount], kChannelCount * sizeof(float));
        } else {
            memset(&dst[frame * kChannelCount], 0, kChannelCount * sizeof(float)); // underrun/no writer yet: silence
        }
    }
    pthread_mutex_unlock(&gState.lock);
    atomic_store(&gState.readSampleTime, atSampleTime + frameCount);
}

#pragma mark - IUnknown

static HRESULT Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG   Driver_AddRef(void *inDriver);
static ULONG   Driver_Release(void *inDriver);

#pragma mark - Basic / device operations

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction, void *inChangeInfo);
static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void *inChangeInfo);

#pragma mark - Property operations

static Boolean  Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                   pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                          pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                          Boolean *outIsSettable);
static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                           pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, const void *inData);

#pragma mark - IO operations

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                     void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    .QueryInterface = Driver_QueryInterface,
    .AddRef = Driver_AddRef,
    .Release = Driver_Release,
    .Initialize = Driver_Initialize,
    .CreateDevice = Driver_CreateDevice,
    .DestroyDevice = Driver_DestroyDevice,
    .AddDeviceClient = Driver_AddDeviceClient,
    .RemoveDeviceClient = Driver_RemoveDeviceClient,
    .PerformDeviceConfigurationChange = Driver_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange = Driver_AbortDeviceConfigurationChange,
    .HasProperty = Driver_HasProperty,
    .IsPropertySettable = Driver_IsPropertySettable,
    .GetPropertyDataSize = Driver_GetPropertyDataSize,
    .GetPropertyData = Driver_GetPropertyData,
    .SetPropertyData = Driver_SetPropertyData,
    .StartIO = Driver_StartIO,
    .StopIO = Driver_StopIO,
    .GetZeroTimeStamp = Driver_GetZeroTimeStamp,
    .WillDoIOOperation = Driver_WillDoIOOperation,
    .BeginIOOperation = Driver_BeginIOOperation,
    .DoIOOperation = Driver_DoIOOperation,
    .EndIOOperation = Driver_EndIOOperation,
};

static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

#pragma mark - IUnknown

static HRESULT Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    (void)inDriver;
    if (!outInterface) return E_INVALIDARG;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean matches = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!matches) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }
    Driver_AddRef(inDriver);
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG Driver_AddRef(void *inDriver) { (void)inDriver; return 1; }
static ULONG Driver_Release(void *inDriver) { (void)inDriver; return 1; }

#pragma mark - Basic / device operations

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gState.host = inHost;
    pthread_mutex_init(&gState.lock, NULL);
    gState.samples = (float *)calloc(kRingFrames * kChannelCount, sizeof(float));
    gState.anchorHostTime = mach_absolute_time();
    gState.anchorSampleTime = 0;
    return noErr;
}

static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError; // single static device; no dynamic creation
}

static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr; // we never request configuration changes
}

static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

#pragma mark - Property dispatch helpers

static Boolean AddressIsGlobal(const AudioObjectPropertyAddress *addr)
{
    return addr->mScope == kAudioObjectPropertyScopeGlobal;
}

#pragma mark - HasProperty

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                  pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    UInt32 size = 0;
    return Driver_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size) == noErr;
}

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                          pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                          Boolean *outIsSettable)
{
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    *outIsSettable = false; // nothing in this driver is settable by clients
    return noErr;
}

#pragma mark - GetPropertyDataSize / GetPropertyData

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                           pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    if (inObjectID == kPlugInObjectID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:      *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:           *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:           *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyManufacturer:    *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:    *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyDeviceList:      *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyBoxList:         *outDataSize = 0; return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kDeviceObjectID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:            *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:                *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:                *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:                 *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyManufacturer:          *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = AddressIsGlobal(inAddress) ? sizeof(AudioObjectID) * 2 : sizeof(AudioObjectID);
                return noErr;
            case kAudioDevicePropertyDeviceUID:            *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyModelUID:              *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType:          *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyRelatedDevices:         *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyClockDomain:            *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsAlive:          *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsRunning:        *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:       *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:                *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyStreams:
                *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                                inAddress->mScope == kAudioObjectPropertyScopeOutput) ? sizeof(AudioObjectID)
                                                                                      : sizeof(AudioObjectID) * 2;
                return noErr;
            case kAudioObjectPropertyControlList:            *outDataSize = 0; return noErr;
            case kAudioDevicePropertySafetyOffset:            *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate:       *outDataSize = sizeof(Float64); return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return noErr;
            case kAudioDevicePropertyIsHidden:                *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod:     *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyIcon:                    *outDataSize = sizeof(CFURLRef); return kAudioHardwareUnknownPropertyError;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kInputStreamID || inObjectID == kOutputStreamID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:  *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:       *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:       *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyOwnedObjects:*outDataSize = 0; return noErr;
            case kAudioStreamPropertyIsActive:    *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyDirection:   *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyTerminalType:*outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyStartingChannel: *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyLatency:     *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static void FillStreamFormat(AudioStreamBasicDescription *fmt)
{
    fmt->mSampleRate = kSampleRate;
    fmt->mFormatID = kAudioFormatLinearPCM;
    fmt->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt->mBytesPerPacket = kChannelCount * sizeof(float);
    fmt->mFramesPerPacket = 1;
    fmt->mBytesPerFrame = kChannelCount * sizeof(float);
    fmt->mChannelsPerFrame = kChannelCount;
    fmt->mBitsPerChannel = 32;
    fmt->mReserved = 0;
}

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize;

    if (inObjectID == kPlugInObjectID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyManufacturer:
                *(CFStringRef *)outData = kManufacturerName; CFRetain(kManufacturerName);
                *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *(AudioObjectID *)outData = kDeviceObjectID; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                CFStringRef uid = *(CFStringRef *)inQualifierData;
                *(AudioObjectID *)outData = (uid && CFEqual(uid, kDeviceUID)) ? kDeviceObjectID : kAudioObjectUnknown;
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kDeviceObjectID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kPlugInObjectID; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:
                *(CFStringRef *)outData = kDeviceName; CFRetain(kDeviceName); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyManufacturer:
                *(CFStringRef *)outData = kManufacturerName; CFRetain(kManufacturerName);
                *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID *ids = (AudioObjectID *)outData;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    ids[0] = kInputStreamID; *outDataSize = sizeof(AudioObjectID);
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    ids[0] = kOutputStreamID; *outDataSize = sizeof(AudioObjectID);
                } else {
                    ids[0] = kInputStreamID; ids[1] = kOutputStreamID; *outDataSize = sizeof(AudioObjectID) * 2;
                }
                return noErr;
            }
            case kAudioDevicePropertyDeviceUID:
                *(CFStringRef *)outData = kDeviceUID; CFRetain(kDeviceUID); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyModelUID:
                *(CFStringRef *)outData = kDeviceModelUID; CFRetain(kDeviceModelUID); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType:
                *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyRelatedDevices:
                *(AudioObjectID *)outData = kDeviceObjectID; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyClockDomain:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsAlive:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsRunning:
                *(UInt32 *)outData = gState.startedClientCount > 0 ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
            // Must be 1, not just technically settable via a direct HAL write: this is
            // the flag System Settings' Sound pane, a call app's own mic picker, and
            // most other device-list UIs check before even listing a device as a
            // selectable input choice -- at 0 (the previous value here, with the
            // intent of never having macOS auto-pick it) every one of those UIs
            // correctly hid it entirely, which also hid it from being manually picked,
            // not just from auto-selection. macOS doesn't auto-promote a virtual device
            // to default just because this is 1 -- real third-party virtual mice (e.g.
            // BlackHole) ship with it set this way and aren't auto-selected either.
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyStreams: {
                AudioObjectID *ids = (AudioObjectID *)outData;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    ids[0] = kInputStreamID; *outDataSize = sizeof(AudioObjectID);
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    ids[0] = kOutputStreamID; *outDataSize = sizeof(AudioObjectID);
                } else {
                    ids[0] = kInputStreamID; ids[1] = kOutputStreamID; *outDataSize = sizeof(AudioObjectID) * 2;
                }
                return noErr;
            }
            case kAudioDevicePropertyNominalSampleRate:
                *(Float64 *)outData = kSampleRate; *outDataSize = sizeof(Float64); return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange *r = (AudioValueRange *)outData;
                r->mMinimum = kSampleRate; r->mMaximum = kSampleRate;
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            }
            case kAudioDevicePropertyIsHidden:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *(UInt32 *)outData = kZeroTimeStampPeriod; *outDataSize = sizeof(UInt32); return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kInputStreamID || inObjectID == kOutputStreamID) {
        Boolean isInput = (inObjectID == kInputStreamID);
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kDeviceObjectID; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioStreamPropertyIsActive:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyDirection:
                *(UInt32 *)outData = isInput ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyTerminalType:
                *(UInt32 *)outData = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyStartingChannel:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyLatency:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                FillStreamFormat((AudioStreamBasicDescription *)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription *d = (AudioStreamRangedDescription *)outData;
                FillStreamFormat(&d->mFormat);
                d->mSampleRateRange.mMinimum = kSampleRate;
                d->mSampleRateRange.mMaximum = kSampleRate;
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, const void *inData)
{
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    return kAudioHardwareUnsupportedOperationError; // nothing settable
}

#pragma mark - IO operations

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    gState.startedClientCount++;
    return noErr;
}

static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (gState.startedClientCount > 0) gState.startedClientCount--;
    return noErr;
}

static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);

    UInt64 now = mach_absolute_time();
    UInt64 elapsedNanos = (now - gState.anchorHostTime) * timebase.numer / timebase.denom;
    Float64 elapsedSeconds = (Float64)elapsedNanos / 1e9;
    Float64 elapsedSamples = elapsedSeconds * kSampleRate;

    UInt64 wholePeriods = (UInt64)elapsedSamples / kZeroTimeStampPeriod;
    Float64 sampleTime = (Float64)(wholePeriods * kZeroTimeStampPeriod);
    UInt64 hostTimeForSampleTime = gState.anchorHostTime +
        (UInt64)((sampleTime / kSampleRate) * 1e9 * timebase.denom / timebase.numer);

    *outSampleTime = sampleTime;
    *outHostTime = hostTimeForSampleTime;
    *outSeed = 1;
    return noErr;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput ||
                       inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                     void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)ioSecondaryBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kInputStreamID) {
        UInt64 sampleTime = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        RingRead((float *)ioMainBuffer, inIOBufferFrameSize, sampleTime);
        return noErr;
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kOutputStreamID) {
        UInt64 sampleTime = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        RingWrite((const float *)ioMainBuffer, inIOBufferFrameSize, sampleTime);
        return noErr;
    }

    return noErr;
}

static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

#pragma mark - Factory

void *VolumeControlMicMixFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID);

void *VolumeControlMicMixFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}
