/* Copyright (c) 2009, Ben Trask
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
	* Redistributions of source code must retain the above copyright
	  notice, this list of conditions and the following disclaimer.
	* Redistributions in binary form must reproduce the above copyright
	  notice, this list of conditions and the following disclaimer in the
	  documentation and/or other materials provided with the distribution.
	* The names of its contributors may be used to endorse or promote products
	  derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY BEN TRASK ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL BEN TRASK BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. */
#import "ECVCaptureController.h"
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOMessage.h>
#import <mach/mach_time.h>

// Views
#import "MPLWindow.h"
#import "MPLVideoView.h"

// Controllers
#import "ECVController.h"
#import "ECVConfigController.h"

// Other Sources
#import "ECVAudioDevice.h"
#import "ECVAudioPipe.h"
#import "ECVDebug.h"
#import "ECVSoundTrack.h"
#import "ECVQTAdditions.h"
#import "ECVVideoTrack.h"

NSString *const ECVVideoFormatKey = @"ECVVideoFormat";
NSString *const ECVDeinterlacingModeKey = @"ECVDeinterlacingMode";
NSString *const ECVBrightnessKey = @"ECVBrightness";
NSString *const ECVContrastKey = @"ECVContrast";
NSString *const ECVHueKey = @"ECVHue";
NSString *const ECVSaturationKey = @"ECVSaturation";

static NSString *const ECVAspectRatio2Key = @"ECVAspectRatio2";
static NSString *const ECVVsyncKey = @"ECVVsync";
static NSString *const ECVMagFilterKey = @"ECVMagFilter";
static NSString *const ECVShowDroppedFramesKey = @"ECVShowDroppedFrames";

enum {
	ECVNotPlaying,
	ECVStartPlaying,
	ECVPlaying,
	ECVStopPlaying
}; // _playLock
enum {
	ECVDrawLoopWait,
	ECVDrawLoopRun
}; // _drawLock

static void ECVDeviceRemoved(ECVCaptureController *controller, io_service_t service, uint32_t messageType, void *messageArgument)
{
	if(kIOMessageServiceIsTerminated == messageType) [controller performSelector:@selector(noteDeviceRemoved) withObject:nil afterDelay:0.0f inModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]]; // Make sure we don't do anything during a special run loop mode (eg. NSModalPanelRunLoopMode).
}
static void ECVDoNothing(void *refcon, IOReturn result, void *arg0) {}

@interface ECVFrameStorage : NSObject
{
	@public
	CVPixelBufferRef buffer;
	AbsoluteTime time;
}
@end
@implementation ECVFrameStorage
- (void)dealloc
{
	CVPixelBufferRelease(buffer);
	[super dealloc];
}
@end

@interface ECVCaptureController(Private)

- (void)_startNewImage:(ECVFrameStorage *)frame;
- (void)_audioDeviceDidReceiveInput:(NSValue *)bufferListValue;
- (void)_hideMenuBar;

@end

@implementation ECVCaptureController

#pragma mark +ECVCaptureController

+ (void)deviceAddedWithIterator:(io_iterator_t)iterator
{
	io_service_t device = IO_OBJECT_NULL;
	while((device = IOIteratorNext(iterator))) {
		NSError *error = nil;
		ECVCaptureController *const controller = [[self alloc] initWithDevice:device error:&error];
		if(controller) [controller showWindow:nil];
		else if(error) [[NSAlert alertWithError:error] runModal];
		IOObjectRelease(device);
	}
}

#pragma mark +NSObject

+ (void)initialize
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithUnsignedInteger:ECV4x3AspectRatio], ECVAspectRatio2Key,
		[NSNumber numberWithBool:NO], ECVVsyncKey,
		[NSNumber numberWithInteger:GL_LINEAR], ECVMagFilterKey,
		[NSNumber numberWithBool:NO], ECVShowDroppedFramesKey,
		[NSNumber numberWithUnsignedInteger:ECVNTSCFormat], ECVVideoFormatKey,
		[NSNumber numberWithInteger:ECVBlur], ECVDeinterlacingModeKey,
		[NSNumber numberWithDouble:0.5f], ECVBrightnessKey,
		[NSNumber numberWithDouble:0.5f], ECVContrastKey,
		[NSNumber numberWithDouble:0.5f], ECVHueKey,
		[NSNumber numberWithDouble:0.5f], ECVSaturationKey,
		nil]];
}

#pragma mark -ECVCaptureController

- (id)initWithDevice:(io_service_t)device error:(out NSError **)outError
{
	if(outError) *outError = nil;
	if(!(self = [self initWithWindowNibName:@"ECVCapture"])) return nil;

	ECVIOReturn(IOServiceAddInterestNotification([[ECVController sharedController] notificationPort], device, kIOGeneralInterest, (IOServiceInterestCallback)ECVDeviceRemoved, self, &_deviceRemovedNotification), ECVRetryDefault);

	_device = device;
	IOObjectRetain(_device);

	io_name_t productName = "";
	ECVIOReturn(IORegistryEntryGetName(device, productName), ECVRetryDefault);
	_productName = [[NSString alloc] initWithUTF8String:productName];

	SInt32 ignored = 0;
	IOCFPlugInInterface **devicePlugInInterface = NULL;
	ECVIOReturn(IOCreatePlugInInterfaceForService(device, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &devicePlugInInterface, &ignored), ECVRetryDefault);

	ECVIOReturn((*devicePlugInInterface)->QueryInterface(devicePlugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID)&_deviceInterface), ECVRetryDefault);
	(*devicePlugInInterface)->Release(devicePlugInInterface);
	devicePlugInInterface = NULL;

	ECVIOReturn((*_deviceInterface)->USBDeviceOpen(_deviceInterface), ECVRetryDefault);
	ECVIOReturn((*_deviceInterface)->ResetDevice(_deviceInterface), ECVRetryDefault);

	IOUSBConfigurationDescriptorPtr configurationDescription = NULL;
	ECVIOReturn((*_deviceInterface)->GetConfigurationDescriptorPtr(_deviceInterface, 0, &configurationDescription), ECVRetryDefault);
	ECVIOReturn((*_deviceInterface)->SetConfiguration(_deviceInterface, configurationDescription->bConfigurationValue), ECVRetryDefault);

	IOUSBFindInterfaceRequest interfaceRequest = {
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare
	};
	io_iterator_t interfaceIterator = IO_OBJECT_NULL;
	ECVIOReturn((*_deviceInterface)->CreateInterfaceIterator(_deviceInterface, &interfaceRequest, &interfaceIterator), ECVRetryDefault);
	io_service_t const interface = IOIteratorNext(interfaceIterator);
	NSParameterAssert(interface);

	IOCFPlugInInterface **interfacePlugInInterface = NULL;
	ECVIOReturn(IOCreatePlugInInterfaceForService(interface, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &interfacePlugInInterface, &ignored), ECVRetryDefault);

	CFUUIDRef const refs[] = {
		kIOUSBInterfaceInterfaceID300,
		kIOUSBInterfaceInterfaceID245,
		kIOUSBInterfaceInterfaceID220,
		kIOUSBInterfaceInterfaceID197
	};
	NSUInteger i;
	for(i = 0; i < numberof(refs); i++) if(SUCCEEDED((*interfacePlugInInterface)->QueryInterface(interfacePlugInInterface, CFUUIDGetUUIDBytes(refs[i]), (LPVOID)&_interfaceInterface))) break;
	NSParameterAssert(_interfaceInterface);
	ECVIOReturn((*_interfaceInterface)->USBInterfaceOpenSeize(_interfaceInterface), ECVRetryDefault);

	ECVIOReturn((*_interfaceInterface)->GetFrameListTime(_interfaceInterface, &_frameTime), ECVRetryDefault);
	if(self.requiresHighSpeed && kUSBHighSpeedMicrosecondsInFrame != _frameTime) {
		if(outError) *outError = [NSError errorWithDomain:ECVGeneralErrorDomain code:0 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
			NSLocalizedString(@"This device requires a USB 2.0 High Speed port in order to operate.", nil), NSLocalizedDescriptionKey,
			NSLocalizedString(@"Make sure it is plugged into a port that supports high speed.", nil), NSLocalizedRecoverySuggestionErrorKey,
			[NSArray array], NSLocalizedRecoveryOptionsErrorKey,
			nil]];
		[self release];
		return nil;
	}

	ECVIOReturn((*_interfaceInterface)->CreateInterfaceAsyncEventSource(_interfaceInterface, NULL), ECVRetryDefault);
	_playLock = [[NSConditionLock alloc] initWithCondition:ECVNotPlaying];
	_drawLock = [[NSConditionLock alloc] initWithCondition:ECVDrawLoopWait];
	_draw = NO;
	_waitingBufferPointers = [[NSMutableArray alloc] init];

	return self;

ECVGenericError:
ECVNoDeviceError:
	[self release];
	return nil;
}
- (void)noteDeviceRemoved
{
	if([[self window] attachedSheet]) {
		_noteDeviceRemovedWhenSheetCloses = YES;
	} else {
		[[self window] close];
		[self release];
	}
}

#pragma mark -

- (IBAction)configureDevice:(id)sender
{
	[[[[ECVConfigController alloc] init] autorelease] beginSheetForCaptureController:self];
}

#pragma mark -

- (IBAction)play:(id)sender
{
	self.playing = YES;
}
- (IBAction)pause:(id)sender
{
	self.playing = NO;
}
- (IBAction)togglePlaying:(id)sender
{
	[_playLock lock];
	switch([_playLock condition]) {
		case ECVNotPlaying:
		case ECVStopPlaying:
			[_playLock unlockWithCondition:ECVStartPlaying];
			[NSThread detachNewThreadSelector:@selector(threaded_readIsochPipeAsync) toTarget:self withObject:nil];
			break;
		case ECVStartPlaying:
		case ECVPlaying:
			[_playLock unlockWithCondition:ECVStopPlaying];
			[_playLock lockWhenCondition:ECVNotPlaying];
			[_playLock unlock];
			break;
	}
}

#pragma mark -

- (IBAction)startRecording:(id)sender
{
	NSParameterAssert(!_movie);
	NSParameterAssert(!_videoTrack);
	NSSavePanel *const savePanel = [NSSavePanel savePanel];
	[savePanel setAllowedFileTypes:[NSArray arrayWithObject:@"mov"]];
	[savePanel setCanCreateDirectories:YES];
	[savePanel setCanSelectHiddenExtension:YES];
	[savePanel setPrompt:NSLocalizedString(@"Record", nil)];
	if(NSFileHandlingPanelOKButton == [savePanel runModal]) {
		_movie = [[QTMovie alloc] initToWritableFile:[savePanel filename] error:NULL];
		_soundTrackStarted = NO;
		ECVAudioStream *const stream = [[[_audioInput streams] objectEnumerator] nextObject];
		NSParameterAssert(stream);
		_soundTrack = [[ECVSoundTrack soundTrackWithMovie:_movie volume:1.0f description:[stream basicDescription]] retain];
		_videoTrack = [[ECVVideoTrack videoTrackWithMovie:_movie size:[self outputSize]] retain];
		[[_soundTrack media] ECV_beginEdits];
		[[_videoTrack media] ECV_beginEdits];
	}
}
- (IBAction)stopRecording:(id)sender
{
	if(!_movie) return;
	[_soundTrack ECV_insertMediaAtTime:QTZeroTime];
	[_videoTrack ECV_insertMediaInRange:[[_videoTrack media] ECV_timeRange] intoTrackInRange:[[_soundTrack media] ECV_timeRange]];
	[[_soundTrack media] ECV_endEdits];
	[[_videoTrack media] ECV_endEdits];
	[_soundTrack release];
	[_videoTrack release];
	_soundTrack = nil;
	_videoTrack = nil;
	[_movie updateMovieFile];
	[_movie release];
	_movie = nil;
	CVPixelBufferRelease(_previousImageBuffer);
	_previousImageBuffer = NULL;
}

#pragma mark -

- (IBAction)toggleFullScreen:(id)sender
{
	self.fullScreen = !self.fullScreen;
}
- (IBAction)toggleFloatOnTop:(id)sender
{
	[[self window] setLevel:[[self window] level] == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel];
}
- (IBAction)changeScale:(id)sender
{
	[[self window] setContentSize:[self outputSizeWithScale:[sender tag]]];
}
- (IBAction)changeAspectRatio:(id)sender
{
	self.aspectRatio = [self sizeWithAspectRatio:[sender tag]];
	[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithUnsignedInteger:[sender tag]] forKey:ECVAspectRatio2Key];
}
- (IBAction)toggleVsync:(id)sender
{
	videoView.vsync = !videoView.vsync;
	[[NSUserDefaults standardUserDefaults] setBool:videoView.vsync forKey:ECVVsyncKey];
}
- (IBAction)toggleSmoothing:(id)sender
{
	switch(videoView.magFilter) {
		case GL_NEAREST: videoView.magFilter = GL_LINEAR; break;
		case GL_LINEAR: videoView.magFilter = GL_NEAREST; break;
	}
	[[NSUserDefaults standardUserDefaults] setInteger:videoView.magFilter forKey:ECVMagFilterKey];
}
- (IBAction)toggleShowDroppedFrames:(id)sender
{
	videoView.showDroppedFrames = !videoView.showDroppedFrames;
	[[NSUserDefaults standardUserDefaults] setBool:videoView.showDroppedFrames forKey:ECVShowDroppedFramesKey];
}

#pragma mark -

- (NSSize)aspectRatio
{
	return videoView.aspectRatio;
}
- (void)setAspectRatio:(NSSize)ratio
{
	videoView.aspectRatio = ratio;
	[[self window] setContentAspectRatio:ratio];
	NSRect f = [[self window] contentRectForFrameRect:[[self window] frame]];
	CGFloat const r = ratio.height / ratio.width;
	f.size.height = NSWidth(f) * r;
	if(!self.fullScreen) [[self window] setFrame:[[self window] frameRectForContentRect:f] display:YES];
	[[self window] setMinSize:NSMakeSize(200.0f, 200.0f * r)];
}
@synthesize deinterlacingMode = _deinterlacingMode;
- (void)setDeinterlacingMode:(ECVDeinterlacingMode)mode
{
	_deinterlacingMode = mode;
	videoView.blurFramesTogether = ECVBlur == mode;
	[self noteVideoSettingDidChange];
	[[NSUserDefaults standardUserDefaults] setInteger:mode forKey:ECVDeinterlacingModeKey];
}
@synthesize fullScreen = _fullScreen;
- (void)setFullScreen:(BOOL)flag
{
	if(flag == _fullScreen) return;
	_fullScreen = flag;
	NSDisableScreenUpdates();
	NSUInteger styleMask = NSBorderlessWindowMask;
	NSRect frame = NSZeroRect;
	if(flag) {
		NSArray *const screens = [NSScreen screens];
		if([screens count]) frame = [[screens objectAtIndex:0] frame];
	} else {
		styleMask = NSTitledWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
		frame = (NSRect){{100, 100}, self.outputSize};
	}
	NSWindow *const w = [[[MPLWindow alloc] initWithContentRect:frame styleMask:styleMask backing:NSBackingStoreBuffered defer:YES] autorelease];
	NSView *const contentView = [[[[self window] contentView] retain] autorelease];
	[[self window] setContentView:nil];
	[w setContentView:contentView];
	[w setDelegate:self];
	[w setLevel:[[self window] level]];
	[w setContentAspectRatio:[[self window] contentAspectRatio]];
	[w setMinSize:[[self window] minSize]];
	[self setWindow:w];
	[self synchronizeWindowTitleWithDocumentName];
	[w makeKeyAndOrderFront:self];
	if(!flag) [w center];
	NSEnableScreenUpdates();
}
- (BOOL)isPlaying
{
	switch([_playLock condition]) {
		case ECVNotPlaying:
		case ECVStopPlaying:
			return NO;
		case ECVStartPlaying:
		case ECVPlaying:
			return YES;
	}
	return NO;
}
- (void)setPlaying:(BOOL)flag
{
	if(flag) {
		[_playLock lock];
		if(![self isPlaying]) {
			[_playLock unlockWithCondition:ECVStartPlaying];
			[NSThread detachNewThreadSelector:@selector(threaded_readIsochPipeAsync) toTarget:self withObject:nil];
		} else [_playLock unlock];
	} else {
		[self stopRecording:self];
		[_playLock lock];
		if([self isPlaying]) {
			[_playLock unlockWithCondition:ECVStopPlaying];
			[_playLock lockWhenCondition:ECVNotPlaying];
		}
		[_playLock unlock];
	}
}
@synthesize videoFormat = _videoFormat;
- (void)setVideoFormat:(ECVVideoFormat)format
{
	if(![self supportsVideoFormat:format]) {
		self.videoFormat = [self defaultVideoFormat];
		return;
	}
	if(format == _videoFormat) return;
	_videoFormat = format;
	[[NSUserDefaults standardUserDefaults] setInteger:format forKey:ECVVideoFormatKey];
	self.playing = NO;
}
- (BOOL)isNTSCFormat
{
	return ECVNTSCFormat == self.videoFormat;
}
- (void)setNTSCFormat:(BOOL)flag
{
	self.videoFormat = ECVNTSCFormat;
}
- (BOOL)isPALFormat
{
	return ECVPALFormat == self.videoFormat;
}
- (void)setPALFormat:(BOOL)flag
{
	self.videoFormat = ECVPALFormat;
}
- (NSSize)outputSize
{
	NSSize const ratio = videoView.aspectRatio;
	NSSize const s = self.captureSize;
	return NSMakeSize(s.width, s.width / ratio.width * ratio.height);
}
- (NSSize)outputSizeWithScale:(NSInteger)scale
{
	NSSize const s = self.outputSize;
	CGFloat const factor = powf(2, (CGFloat)scale);
	return NSMakeSize(s.width * factor, s.height * factor);
}
- (NSSize)sizeWithAspectRatio:(ECVAspectRatio)ratio
{
	switch(ratio) {
		case ECV1x1AspectRatio:   return NSMakeSize( 1.0f,  1.0f);
		case ECV4x3AspectRatio:   return NSMakeSize( 4.0f,  3.0f);
		case ECV16x10AspectRatio: return NSMakeSize(16.0f, 10.0f);
		case ECV16x9AspectRatio:  return NSMakeSize(16.0f,  9.0f);
	}
	return NSZeroSize;
}

#pragma mark -

- (BOOL)startAudio
{
	if(!_audioPipe) {
		ECVAudioDevice *const input = [ECVAudioDevice deviceWithIODevice:_device input:YES];
		ECVAudioDevice *const output = [ECVAudioDevice defaultOutputDevice];
		ECVAudioStream *const inputStream = [[[input streams] objectEnumerator] nextObject];
		ECVAudioStream *const outputStream = [[[output streams] objectEnumerator] nextObject];
		if(!inputStream || !outputStream) return NO;

		_audioPipe = [[ECVAudioPipe alloc] initWithInputDescription:[inputStream basicDescription] outputDescription:[outputStream basicDescription]];
		_audioInput = [input retain];
		_audioOutput = [output retain];
		_audioInput.delegate = self;
		_audioOutput.delegate = self;

	}
	[_audioPipe clearBuffer];
	if([_audioInput start] && [_audioOutput start]) return YES;
	[self stopAudio];
	return NO;
}
- (void)stopAudio
{
	[_audioOutput stop];
	[_audioInput stop];
}

#pragma mark -

- (void)threaded_readIsochPipeAsync
{
	UInt8 *fullFrameData = NULL;
	IOUSBLowLatencyIsocFrame *fullFrameList = NULL;

	NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
	[_playLock lock];
	if([_playLock condition] != ECVStartPlaying) {
		[_playLock unlock];
		[pool release];
		return;
	}
	[NSThread setThreadPriority:1.0f];
	if(![self threaded_play]) goto bail;
	if(![self startAudio]) {
		usleep(500000); // Make sure the device has time to initialize.
		if(![self startAudio]) goto bail;
	}
	[_playLock unlockWithCondition:ECVPlaying];

	NSUInteger const simultaneousTransfers = self.simultaneousTransfers;
	NSUInteger const microframesPerTransfer = self.microframesPerTransfer;
	UInt8 const pipe = self.isochReadingPipe;
	SEL const scanSelector = @selector(threaded_readFrame:bytes:);
	IMP const scanner = [self methodForSelector:scanSelector];
	NSUInteger i;

	UInt16 frameRequestSize = 0;
	UInt8 ignored1 = 0, ignored2 = 0, ignored3 = 0 , ignored4 = 0;
	ECVIOReturn((*_interfaceInterface)->GetPipeProperties(_interfaceInterface, pipe, &ignored1, &ignored2, &ignored3, &frameRequestSize, &ignored4), ECVRetryDefault);
	NSParameterAssert(frameRequestSize);

	ECVIOReturn((*_interfaceInterface)->LowLatencyCreateBuffer(_interfaceInterface, (void **)&fullFrameData, frameRequestSize * microframesPerTransfer * simultaneousTransfers, kUSBLowLatencyReadBuffer), ECVRetryDefault);
	ECVIOReturn((*_interfaceInterface)->LowLatencyCreateBuffer(_interfaceInterface, (void **)&fullFrameList, sizeof(IOUSBLowLatencyIsocFrame) * microframesPerTransfer * simultaneousTransfers, kUSBLowLatencyFrameListBuffer), ECVRetryDefault);
	for(i = 0; i < microframesPerTransfer * simultaneousTransfers; i++) {
		fullFrameList[i].frStatus = kIOReturnInvalid; // Ignore them to start out.
		fullFrameList[i].frReqCount = frameRequestSize;
	}

	UInt64 currentFrame = 0;
	AbsoluteTime ignored;
	ECVIOReturn((*_interfaceInterface)->GetBusFrameNumber(_interfaceInterface, &currentFrame, &ignored), ECVRetryDefault);
	currentFrame += 10;

	_ignoringFirstFrame = YES;
	_pendingImageLength = 0;
	[_drawLock lockWhenCondition:ECVDrawLoopWait];
	_draw = YES;
	[_drawLock unlock];
	[NSApplication detachDrawingThread:@selector(threaded_drawWaitingBuffers) toTarget:self withObject:nil];

	while([_playLock condition] == ECVPlaying) {
		NSAutoreleasePool *const innerPool = [[NSAutoreleasePool alloc] init];
		if(![self threaded_watchdog]) {
			[innerPool release];
			break;
		}
		NSUInteger transfer = 0;
		for(; transfer < simultaneousTransfers; transfer++ ) {
			UInt8 *const frameData = fullFrameData + frameRequestSize * microframesPerTransfer * transfer;
			IOUSBLowLatencyIsocFrame *const frameList = fullFrameList + microframesPerTransfer * transfer;
			for(i = 0; i < microframesPerTransfer; i++) {
				if(kUSBLowLatencyIsochTransferKey == frameList[i].frStatus && i) {
					Nanoseconds const nextUpdateTime = UInt64ToUnsignedWide(UnsignedWideToUInt64(AbsoluteToNanoseconds(frameList[i - 1].frTimeStamp)) + 1e6); // LowLatencyReadIsochPipeAsync() only updates every millisecond at most.
					mach_wait_until(UnsignedWideToUInt64(NanosecondsToAbsolute(nextUpdateTime)));
				}
				while(kUSBLowLatencyIsochTransferKey == frameList[i].frStatus) usleep(100); // In case we haven't slept long enough already.
				scanner(self, scanSelector, frameList + i, frameData + i * frameRequestSize);
				frameList[i].frStatus = kUSBLowLatencyIsochTransferKey;
			}
			ECVIOReturn((*_interfaceInterface)->LowLatencyReadIsochPipeAsync(_interfaceInterface, pipe, frameData, currentFrame, microframesPerTransfer, 1, frameList, ECVDoNothing, NULL), 0);
			currentFrame += microframesPerTransfer / (kUSBFullSpeedMicrosecondsInFrame / _frameTime);
		}
		[innerPool drain];
	}

	[self threaded_pause];
ECVGenericError:
ECVNoDeviceError:
	[self stopAudio];
	if(fullFrameData) (*_interfaceInterface)->LowLatencyDestroyBuffer(_interfaceInterface, fullFrameData);
	if(fullFrameList) (*_interfaceInterface)->LowLatencyDestroyBuffer(_interfaceInterface, fullFrameList);
	[_drawLock lock];
	_draw = NO;
	[_drawLock unlockWithCondition:ECVDrawLoopRun];
	[_playLock lock];
	CVPixelBufferRelease(_pendingImageBuffer);
	_pendingImageBuffer = NULL;
bail:
	NSParameterAssert([_playLock condition] != ECVNotPlaying);
	[_playLock unlockWithCondition:ECVNotPlaying];
	[pool drain];
}
- (void)threaded_readImageBytes:(UInt8 const *)bytes length:(size_t)length
{
	if(!_pendingImageBuffer || !bytes || !length) return;
	size_t const maxLength = CVPixelBufferGetDataSize(_pendingImageBuffer);
	size_t const theoreticalRowLength = self.captureSize.width * 2; // YUYV is effectively 2Bpp.
	size_t const actualRowLength = CVPixelBufferGetBytesPerRow(_pendingImageBuffer);
	size_t const rowPadding = actualRowLength - theoreticalRowLength;
	BOOL const skipLines = ECVFullFrame != _fieldType && ECVLineDouble != _deinterlacingMode && ECVBlur != _deinterlacingMode;

	size_t used = 0;
	size_t rowOffset = _pendingImageLength % actualRowLength;
	CVPixelBufferLockBaseAddress(_pendingImageBuffer, 0);
	while(used < length) {
		size_t const remainingRowLength = theoreticalRowLength - rowOffset;
		size_t const unused = length - used;
		BOOL isFinishingRow = unused >= remainingRowLength;
		size_t const rowFillLength = MIN(maxLength - _pendingImageLength, MIN(remainingRowLength, unused));
		memcpy(CVPixelBufferGetBaseAddress(_pendingImageBuffer) + _pendingImageLength, bytes + used, rowFillLength);
		_pendingImageLength += rowFillLength;
		if(_pendingImageLength >= maxLength) break;
		if(isFinishingRow) {
			_pendingImageLength += rowPadding;
			if(skipLines) _pendingImageLength += actualRowLength;
		}
		used += rowFillLength;
		rowOffset = 0;
	}
	CVPixelBufferUnlockBaseAddress(_pendingImageBuffer, 0);
}
- (void)threaded_startNewImageWithFieldType:(ECVFieldType)fieldType absoluteTime:(AbsoluteTime)time
{
	if(_ignoringFirstFrame) {
		_ignoringFirstFrame = NO;
		return; // The first frame is typically corrupted, it doesn't really matter but it just looks bad.
	}

	CVPixelBufferRef const currentImageBuffer = _pendingImageBuffer;
	if(currentImageBuffer) {
		[_drawLock lock];
		BOOL const dropFrames = [_waitingBufferPointers count] >= 2;
		if(dropFrames) [self clearWaitingBuffers];
		[videoView droppedFrame:dropFrames];
		[_waitingBufferPointers insertObject:[NSValue valueWithPointer:CVBufferRetain(currentImageBuffer)] atIndex:0];
		[_drawLock unlockWithCondition:ECVDrawLoopRun];
	}

	CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _imageBufferPool, &_pendingImageBuffer);
	CVPixelBufferLockBaseAddress(_pendingImageBuffer, 0);
	BOOL clearNewBuffer = !currentImageBuffer;
	if(currentImageBuffer) {
		switch(_deinterlacingMode) {
			case ECVWeave:
				CVPixelBufferLockBaseAddress(currentImageBuffer, 0);
				memcpy(CVPixelBufferGetBaseAddress(_pendingImageBuffer), CVPixelBufferGetBaseAddress(currentImageBuffer), CVPixelBufferGetDataSize(_pendingImageBuffer));
				CVPixelBufferUnlockBaseAddress(currentImageBuffer, 0);
				break;
			case ECVAlternate:
				clearNewBuffer = YES;
				break;
		}
	}
	if(clearNewBuffer) {
		UInt32 const val = 0x10801080;
		memset_pattern4(CVPixelBufferGetBaseAddress(_pendingImageBuffer), &val, CVPixelBufferGetDataSize(_pendingImageBuffer));
	}
	CVPixelBufferUnlockBaseAddress(_pendingImageBuffer, 0);

	_pendingImageLength = ECVLowField == fieldType && ECVLineDouble != _deinterlacingMode && ECVBlur != _deinterlacingMode ? CVPixelBufferGetBytesPerRow(_pendingImageBuffer) : 0;
	_fieldType = fieldType;

	ECVFrameStorage *const frame = [[[ECVFrameStorage alloc] init] autorelease];
	frame->buffer = currentImageBuffer;
	frame->time = time;
	[self performSelectorOnMainThread:@selector(_startNewImage:) withObject:frame waitUntilDone:NO];
}
- (void)threaded_drawWaitingBuffers
{
	while(YES) {
		NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];

		[_drawLock lockWhenCondition:ECVDrawLoopRun];
		if(!_draw) {
			[self clearWaitingBuffers];
			[_drawLock unlockWithCondition:ECVDrawLoopWait];
			[pool release];
			break;
		}
		CVPixelBufferRef const buffer = [[_waitingBufferPointers lastObject] pointerValue];
		[_waitingBufferPointers removeLastObject];
		[_drawLock unlockWithCondition:[_waitingBufferPointers count] ? ECVDrawLoopRun : ECVDrawLoopWait];

		videoView.imageBuffer = buffer;
		CVBufferRelease(buffer);
		[pool drain];
	}
}
- (void)clearWaitingBuffers
{
	for(NSValue *const value in _waitingBufferPointers) CVBufferRelease([value pointerValue]);
	[_waitingBufferPointers removeAllObjects];
}

#pragma mark -

- (BOOL)setAlternateInterface:(UInt8)alternateSetting
{
	IOReturn const error = (*_interfaceInterface)->SetAlternateInterface(_interfaceInterface, alternateSetting);
	switch(error) {
		case kIOReturnSuccess: return YES;
		case kIOReturnNoDevice:
		case kIOReturnNotResponding: return NO;
	}
	ECVIOReturn(error, 0);
ECVGenericError:
ECVNoDeviceError:
	return NO;
}
- (BOOL)controlRequestWithType:(UInt8)type request:(UInt8)request value:(UInt16)value index:(UInt16)index length:(UInt16)length data:(void *)data
{
	IOUSBDevRequest r = { type, request, value, index, length, data, 0 };
	IOReturn const error = (*_interfaceInterface)->ControlRequest(_interfaceInterface, 0, &r);
	switch(error) {
		case kIOReturnSuccess: return YES;
		case kIOUSBPipeStalled: ECVIOReturn((*_interfaceInterface)->ClearPipeStall(_interfaceInterface, 0), ECVRetryDefault); return YES;
		case kIOReturnNotResponding: return NO;
	}
	ECVIOReturn(error, 0);
ECVGenericError:
ECVNoDeviceError:
	return NO;
}
- (BOOL)writeValue:(UInt16)value atIndex:(UInt16)index
{
	return [self controlRequestWithType:USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice) request:kUSBRqClearFeature value:value index:index length:0 data:NULL];
}
- (BOOL)readValue:(out SInt32 *)outValue atIndex:(UInt16)index
{
	SInt32 v = 0;
	BOOL const r = [self controlRequestWithType:USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice) request:kUSBRqGetStatus value:0 index:index length:sizeof(v) data:&v];
	if(outValue) *outValue = CFSwapInt32LittleToHost(v);
	return r;
}
- (BOOL)setFeatureAtIndex:(UInt16)index
{
	return [self controlRequestWithType:USBmakebmRequestType(kUSBOut, kUSBStandard, kUSBDevice) request:kUSBRqSetFeature value:0 index:index length:0 data:NULL];
}

#pragma mark -

- (void)noteVideoSettingDidChange
{
	NSParameterAssert(!self.isPlaying);
	CVPixelBufferPoolRelease(_imageBufferPool);
	CVPixelBufferRelease(_pendingImageBuffer);
	_pendingImageBuffer = NULL;
	_pendingImageLength = 0;
	NSSize s = self.captureSize;
	if(ECVLineDouble == _deinterlacingMode || ECVBlur == _deinterlacingMode) s.height /= 2.0f;
	(void)CVPixelBufferPoolCreate(kCFAllocatorDefault, (CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:
			[NSNumber numberWithUnsignedInt:2], kCVPixelBufferPoolMinimumBufferCountKey,
			[NSNumber numberWithDouble:0], kCVPixelBufferPoolMaximumBufferAgeKey,
		nil], (CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:
			[NSNumber numberWithInt:k2vuyPixelFormat], kCVPixelBufferPixelFormatTypeKey,
			[NSNumber numberWithUnsignedInteger:roundf(s.width)], kCVPixelBufferWidthKey,
			[NSNumber numberWithUnsignedInteger:roundf(s.height)], kCVPixelBufferHeightKey,
			[NSNumber numberWithBool:YES], kCVPixelBufferOpenGLCompatibilityKey,
		nil], &_imageBufferPool);
}

#pragma mark -ECVCaptureController(Private)

- (void)_startNewImage:(ECVFrameStorage *)frame
{
	if(!_videoTrack || !_soundTrackStarted) return;
	if(ECVBlur == _deinterlacingMode && _previousImageBuffer && frame->buffer) {
		// We do the blurring in OpenGL, which doesn't help when we're recording. Another option might to be record the OpenGL output, but that has its own problems.
		CVPixelBufferLockBaseAddress(_previousImageBuffer, 0);
		CVPixelBufferLockBaseAddress(frame->buffer, 0);
		size_t const length = CVPixelBufferGetDataSize(frame->buffer);
		UInt8 *const baseBytes = CVPixelBufferGetBaseAddress(_previousImageBuffer);
		UInt8 *const newBytes = CVPixelBufferGetBaseAddress(frame->buffer);
		size_t i;
		for(i = 0; i < length; i++) baseBytes[i] = newBytes[i] / 2 + baseBytes[i] / 2; // A more knowledgeable person might be able to optimize this a lot more.
		CVPixelBufferUnlockBaseAddress(frame->buffer, 0);
		CVPixelBufferUnlockBaseAddress(_previousImageBuffer, 0);
	}
	[_videoTrack addFrameWithPixelBuffer:_previousImageBuffer codecType:kJPEGCodecType quality:0.5f time:(NSTimeInterval)UnsignedWideToUInt64(AbsoluteToNanoseconds(frame->time)) * 1e-9];
	CVPixelBufferRelease(_previousImageBuffer);
	_previousImageBuffer = CVPixelBufferRetain(frame->buffer);
}
- (void)_audioDeviceDidReceiveInput:(NSValue *)bufferListValue
{
	AudioBufferList *const bufferList = [bufferListValue pointerValue];
	[_soundTrack addSamples:bufferList];
	free(bufferList);
}
- (void)_hideMenuBar
{
	SetSystemUIMode(kUIModeAllSuppressed, kNilOptions);
}

#pragma mark -NSWindowController

- (void)windowDidLoad
{
	NSWindow *const w = [self window];
	[w setFrame:[w frameRectForContentRect:(NSRect){NSZeroPoint, self.captureSize}] display:NO];
	self.aspectRatio = [self sizeWithAspectRatio:[[[NSUserDefaults standardUserDefaults] objectForKey:ECVAspectRatio2Key] unsignedIntegerValue]];

	self.videoFormat = [[NSUserDefaults standardUserDefaults] integerForKey:ECVVideoFormatKey];
	self.deinterlacingMode = [[NSUserDefaults standardUserDefaults] integerForKey:ECVDeinterlacingModeKey];
	videoView.vsync = [[NSUserDefaults standardUserDefaults] boolForKey:ECVVsyncKey];
	videoView.showDroppedFrames = [[NSUserDefaults standardUserDefaults] boolForKey:ECVShowDroppedFramesKey];
	videoView.magFilter = [[NSUserDefaults standardUserDefaults] integerForKey:ECVMagFilterKey];

	[w center];
	[self noteVideoSettingDidChange];
	[super windowDidLoad];
}
- (void)synchronizeWindowTitleWithDocumentName
{
	[[self window] setTitle:_productName];
}

#pragma mark -NSObject

- (void)dealloc
{
	if(_deviceInterface) (*_deviceInterface)->USBDeviceClose(_deviceInterface);
	if(_deviceInterface) (*_deviceInterface)->Release(_deviceInterface);
	if(_interfaceInterface) (*_interfaceInterface)->Release(_interfaceInterface);
	_audioInput.delegate = nil;
	_audioOutput.delegate = nil;
	[self clearWaitingBuffers];

	IOObjectRelease(_device);
	[_productName release];
	IOObjectRelease(_deviceRemovedNotification);
	CVPixelBufferPoolRelease(_imageBufferPool);
	CVPixelBufferRelease(_pendingImageBuffer);
	[_playLock release];
	[_drawLock release];
	[_waitingBufferPointers release];
	[_audioInput release];
	[_audioOutput release];
	[_audioPipe release];
	[_movie release];
	[_soundTrack release];
	[_videoTrack release];
	CVPixelBufferRelease(_previousImageBuffer);
	[super dealloc];
}

#pragma mark -NSObject(ECVAudioDeviceDelegate)

- (void)audioDevice:(ECVAudioDevice *)sender didReceiveInput:(AudioBufferList const *)bufferList atTime:(AudioTimeStamp const *)time
{
	NSParameterAssert(sender = _audioInput);
	[_audioPipe receiveInput:bufferList atTime:time];
	if(_soundTrack) {
		_soundTrackStarted = YES;
		[self performSelectorOnMainThread:@selector(_audioDeviceDidReceiveInput:) withObject:[NSValue valueWithPointer:ECVAudioBufferListCopy(bufferList)] waitUntilDone:NO];
	}
}
- (void)audioDevice:(ECVAudioDevice *)sender didRequestOutput:(inout AudioBufferList *)bufferList forTime:(AudioTimeStamp const *)time
{
	NSParameterAssert(sender == _audioOutput);
	[_audioPipe requestOutput:bufferList forTime:time];
}

#pragma mark -NSObject(NSMenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem *)anItem
{
	SEL const action = [anItem action];
	if(@selector(toggleFullScreen:) == action) [anItem setTitle:self.fullScreen ? NSLocalizedString(@"Exit Full Screen", nil) : NSLocalizedString(@"Enter Full Screen", nil)];
	if(@selector(togglePlaying:) == action) [anItem setTitle:[self isPlaying] ? NSLocalizedString(@"Pause", nil) : NSLocalizedString(@"Play", nil)];
	if(@selector(changeAspectRatio:) == action) {
		NSSize const s1 = [self sizeWithAspectRatio:[anItem tag]];
		NSSize const s2 = videoView.aspectRatio;
		[anItem setState:s1.width / s1.height == s2.width / s2.height];
	}
	if(@selector(changeScale:) == action) [anItem setState:!!NSEqualSizes([[self window] contentRectForFrameRect:[[self window] frame]].size, [self outputSizeWithScale:[anItem tag]])];
	if(@selector(toggleFloatOnTop:) == action) [anItem setTitle:[[self window] level] == NSFloatingWindowLevel ? NSLocalizedString(@"Turn Floating Off", nil) : NSLocalizedString(@"Turn Floating On", nil)];
	if(@selector(toggleVsync:) == action) [anItem setTitle:videoView.vsync ? NSLocalizedString(@"Turn V-Sync Off", nil) : NSLocalizedString(@"Turn V-Sync On", nil)];
	if(@selector(toggleSmoothing:) == action) [anItem setTitle:GL_LINEAR == videoView.magFilter ? NSLocalizedString(@"Turn Smoothing Off", nil) : NSLocalizedString(@"Turn Smoothing On", nil)];
	if(@selector(toggleShowDroppedFrames:) == action) [anItem setTitle:videoView.showDroppedFrames ? NSLocalizedString(@"Hide Dropped Frames", nil) : NSLocalizedString(@"Show Dropped Frames", nil)];

	if(self.fullScreen) {
		if(@selector(changeScale:) == action) return NO;
	}
	if(_movie) {
		if(@selector(startRecording:) == action) return NO;
	} else {
		if(@selector(stopRecording:) == action) return NO;
	}
	if(!self.isPlaying) {
		if(@selector(startRecording:) == action) return NO;
	}
	return [self respondsToSelector:action];
}

#pragma mark -NSObject(NSWindowNotifications)

- (void)windowDidBecomeKey:(NSNotification *)aNotif
{
	if(self.fullScreen) [self performSelector:@selector(_hideMenuBar) withObject:nil afterDelay:0.0f inModes:[NSArray arrayWithObject:(NSString *)kCFRunLoopCommonModes]];
}
- (void)windowDidResignKey:(NSNotification *)aNotif
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hideMenuBar) object:nil];
	SetSystemUIMode(kUIModeNormal, kNilOptions);
}

- (void)windowDidEndSheet:(NSNotification *)aNotif
{
	if(_noteDeviceRemovedWhenSheetCloses) [self noteDeviceRemoved];
}

#pragma mark -NSObject(MPLVideoViewDelegate)

- (BOOL)videoView:(MPLVideoView *)sender handleKeyDown:(NSEvent *)anEvent
{
	if([@" " isEqualToString:[anEvent charactersIgnoringModifiers]]) {
		[self togglePlaying:self];
		return YES;
	}
	return NO;
}

@end