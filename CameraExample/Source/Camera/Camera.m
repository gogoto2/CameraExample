//
//  Camera.m
//  CameraExample
//
//  Created by 김도범 on 2018. 5. 19..
//  Copyright © 2018년 DobumKim. All rights reserved.
//

#import "Camera.h"
#import "CaptureDelegate.h"
#import "AVCaptureDeviceDiscoverySession+Utilities.h"
#import <UIKit/UIKit.h>

@import Photos;

#define USE_INTERRUPTION_NOTIFICATION 0

@interface Camera ()<AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate>

@property(nonatomic, assign) BOOL sessionRunning;  // 캡쳐세션이 에러로 멈췄을때 다시 시작할지 판단하기위한 플래그
@property(nonatomic, strong)
    AVCaptureDeviceDiscoverySession *cameraDiscoverySession;     // 현재 카메라디바이스를 찾기위한 세션
@property(nonatomic, strong) AVCaptureSession *captureSession;   // 카메라 캡쳐세션
@property(nonatomic, strong) AVCaptureDevice *cameraDevice;      //
@property(nonatomic, strong) AVCaptureDeviceInput *videoInput;   // 비디오 영상 입력
@property(nonatomic, strong) AVCapturePhotoOutput *photoOutput;  // 사진,라이브포토 출력

// 사진,포토라이브러리 캡쳐 관리
@property(nonatomic) NSMutableDictionary<NSNumber *, CaptureDelegate *> *inProgressPhotoCaptureDelegates;
@property(nonatomic) NSInteger inProgressLivePhotoCapturesCount;

@property(nonatomic, copy) void (^videoRecordingComplete)(BOOL success);  // 비디오 촬영 완료 블럭
@property(nonatomic, strong) AVCaptureMovieFileOutput *movieFileOutput;   // 비디오 출력

@property(nonatomic, assign) UIBackgroundTaskIdentifier backgroundRecordingID;  // 백그라운드 태스크 관리

@end

@implementation Camera

#pragma mark - initialize

// 카메라 세션 작업 큐 싱글톤객체로 생성
+ (dispatch_queue_t)sessionQueue {
  static dispatch_queue_t sessionQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    if (!sessionQueue) sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
  });
  return sessionQueue;
}

// async하게 싱글톤객체생성
+ (void)configureCamera:(void (^)(Camera *camera, NSError *error))complete {
  [Camera congifureCameraWithMode:CameraModePhoto position:AVCaptureDevicePositionBack complete:complete];
}

// async하게 싱글톤객체생성
+ (void)congifureCameraWithMode:(CameraMode)mode
                       position:(AVCaptureDevicePosition)position
                       complete:(void (^)(Camera *camera, NSError *error))complete {
  if (!complete) return;
  static Camera *camera = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_async([Camera sessionQueue], ^{
      NSError *error;
      if (!camera) camera = [[Camera alloc] initWithMode:mode position:position error:&error];
      complete(camera, error);
    });
  });
}

// 객체생성
- (instancetype)init {
  return [self initWithMode:CameraModePhoto position:AVCaptureDevicePositionBack error:nil];
}

// 객체생성
- (instancetype)initWithMode:(CameraMode)mode position:(AVCaptureDevicePosition)position error:(NSError **)error {
  if (self = [super init]) {
    // 프로퍼티초기화
    _mode = mode;
    _position = position;
    _flash = AVCaptureFlashModeAuto;
    _focus = AVCaptureFocusModeContinuousAutoFocus;
    _exposure = AVCaptureExposureModeAutoExpose;
    _livePhotoEnable = NO;
    _depthDataDeliveryEnable = NO;
    _portraitEffectsMatteEnable = NO;

    // 카메라모드에 따라 프리셋설정
    AVCaptureSessionPreset preset = mode == CameraModePhoto ? AVCaptureSessionPresetPhoto : AVCaptureSessionPresetHigh;

    [self.captureSession beginConfiguration];    // 캡쳐 세션 설정시작
    self.captureSession.sessionPreset = preset;  // 프리셋적용

    if (![self configureCameraDevice:error]) {  // 카메라설정하여 실패시 캡쳐 세션 설정종료 및 nil포인트반환
      [self.captureSession commitConfiguration];
      return nil;
    }

    // 오디오입력 캡쳐세션에 연결
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:error];
    if ([self.captureSession canAddInput:audioInput]) {
      [self.captureSession addInput:audioInput];
    }

    // 사진출력 캡쳐세션에 연결
    if ([self.captureSession canAddOutput:self.photoOutput]) {
      [self.captureSession addOutput:self.photoOutput];

      self.photoOutput.livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureSupported;
      if (@available(iOS 11.0, *)) {
        self.photoOutput.depthDataDeliveryEnabled = self.photoOutput.depthDataDeliverySupported;
      }
      if (@available(iOS 12.0, *)) {
        self.photoOutput.portraitEffectsMatteDeliveryEnabled = self.photoOutput.portraitEffectsMatteDeliverySupported;
      }
    } else {
      [self.captureSession commitConfiguration];
      return nil;
    }

    // 백그라운드ID 초기화
    self.backgroundRecordingID = UIBackgroundTaskInvalid;

    // 캡쳐세션 설정 종료
    [self.captureSession commitConfiguration];

    // 사진챕쳐딜리게이트를 저장하는 dictionary 설정 및 초기화
    self.inProgressPhotoCaptureDelegates = [NSMutableDictionary dictionary];
    self.inProgressLivePhotoCapturesCount = 0;
  }
  return self;
}

#pragma mark - public functions

// 외부 카메라출력뷰에 세션을 전달하기위한 함수
- (AVCaptureSession *)session {
  return self.captureSession;
}

// 현재 카메라 포맷의 해상도를 전달하기위한 함수
- (CGSize)resolution {
  return CGSizeMake(self.currentFormat.highResolutionStillImageDimensions.width,
                    self.currentFormat.highResolutionStillImageDimensions.height);
}

// 캡쳐세션 시작
- (void)startCapture {
  [self.captureSession startRunning];
  self.sessionRunning = self.captureSession.isRunning;
}

// 캡쳐세션 중지
- (void)stopCapture {
  [self.captureSession stopRunning];
  self.sessionRunning = self.captureSession.isRunning;
}

// 사진/라이브포토 촬영
- (void)takePhotoWithDelegate:(id<CameraCaptureUIDelegate>)uiDelegate complete:(void (^)(void))complete {
  NSAssert(uiDelegate, @"uiDelegate can't be nil");
  dispatch_async([Camera sessionQueue], ^{
    // 현재 카메라화면의 오리엔테이션을 적용
    AVCaptureConnection *photoOutputConnection = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
    photoOutputConnection.videoOrientation = [uiDelegate captureOrientation];

    // 사진촬영 설정객체 생성 (여기서 라이브포토로 찍을지, 그냥 사진촬영할지 결정된다. also depthDataDelivery)
    AVCapturePhotoSettings *settings = [self configurePhotoSetting];

    // 라이브포토촬영시 촬영하는 데 시간이 걸리는데 연속해서 촬영할 경우 촬영프로세스를 여러개 동시에 돌리기 위해
    // 실질적인 촬영기능을 CaptureDelegate 클래스로 분리하여 여러개의 객체를 생성하여 촬영한다.
    CaptureDelegate *captureDelegate = [[CaptureDelegate alloc] initWithSettings:settings
        captureAnimation:[uiDelegate captureAnimation]
        livePhotoHandler:^(BOOL capturing) {
          // 라이브포토 카운드 관리
          if (capturing) {
            self.inProgressLivePhotoCapturesCount++;
          } else {
            self.inProgressLivePhotoCapturesCount--;
          }

          NSInteger inProgressLivePhotoCapturesCount = self.inProgressLivePhotoCapturesCount;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (inProgressLivePhotoCapturesCount > 0) {  // 라이브포토촬영이 진행중
              [uiDelegate capturingLivePhoto:YES];
            } else if (inProgressLivePhotoCapturesCount == 0) {  // 라이브포토촬영 완료
              [uiDelegate capturingLivePhoto:NO];
            } else {
              NSLog(@"Error: In progress live photo capture count is less than "
                    @"0");
            }
          });
        }
        complete:^(CaptureDelegate *delegate) {  // 촬영완료
          dispatch_async([Camera sessionQueue], ^{
            // 촬영을 완료한 CaptureDelegate는 더 이상 필요없기 때문에 inProgressPhotoCaptureDelegates dictionary에서
            // 제거한다.
            self.inProgressPhotoCaptureDelegates[@(delegate.requestedPhotoSettings.uniqueID)] = nil;
          });
        }];

    // 생성된 CaptureDelegate를 strong하게 가지고 있기위해 inProgressPhotoCaptureDelegates dictionary에 저장한다.
    self.inProgressPhotoCaptureDelegates[@(captureDelegate.requestedPhotoSettings.uniqueID)] = captureDelegate;

    // 캡쳐시작
    [self.photoOutput capturePhotoWithSettings:settings delegate:captureDelegate];
  });
}

// 비디오촬영 중 인지 확인
- (BOOL)isRecording {
  return self.movieFileOutput.isRecording;
}

// 비디오촬영 중 스냅샷이 가능한지 확인
- (BOOL)availableSnapShot {
  return (self.cameraDiscoverySession.uniqueDevicePositionsCount > 1);
}

// 비디오촬영 시작
- (void)startVideoRecording:(id<CameraCaptureUIDelegate>)uiDelegate complete:(void (^)(BOOL success))complete {
  NSAssert(uiDelegate, @"uiDelegate can't be nil");

  _videoRecordingComplete = complete;

  // 현재 카메라화면의 오리엔테이션을 가져온다.
  AVCaptureVideoOrientation videoPreviewLayerVideoOrientation = [uiDelegate captureOrientation];

  dispatch_async([Camera sessionQueue], ^{
    if (!self.movieFileOutput.isRecording) {                   // 촬영중이 아니라면 촬영시작
      if ([UIDevice currentDevice].isMultitaskingSupported) {  // 멀티태스킹지원시 백그라운드 설정
        self.backgroundRecordingID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
      }

      // 현재 비디오화면의 오리엔테이션 적용
      AVCaptureConnection *movieFileOutputConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
      movieFileOutputConnection.videoOrientation = videoPreviewLayerVideoOrientation;

      // HEVC 코덱이 지원된다면 사용
      if (@available(iOS 11.0, *)) {
        if ([self.movieFileOutput.availableVideoCodecTypes containsObject:AVVideoCodecTypeHEVC]) {
          [self.movieFileOutput setOutputSettings:@{
            AVVideoCodecKey : AVVideoCodecTypeHEVC
          }
                                    forConnection:movieFileOutputConnection];
        }
      }

      // 촬영하는 영상은 임의의 스트링으로 임시저장폴더에 저장한다.
      NSString *outputFileName = [NSUUID UUID].UUIDString;
      NSString *outputFilePath = [NSTemporaryDirectory()
          stringByAppendingPathComponent:[outputFileName stringByAppendingPathExtension:@"mov"]];

      // 비디오촬영 시작
      [self.movieFileOutput startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputFilePath]
                                        recordingDelegate:self];
    }
  });
}

// 비디오촬영 종료
- (void)stopVideoRecording {
  if (self.movieFileOutput.isRecording) {
    [self.movieFileOutput stopRecording];
  }
}

#pragma mark - AVCaptureFileOutputRecordingDelegate

// 비디오촬영이 시작되면 호출되는 함수
- (void)captureOutput:(AVCaptureFileOutput *)output
    didStartRecordingToOutputFileAtURL:(NSURL *)fileURL
                       fromConnections:(NSArray<AVCaptureConnection *> *)connections {
}

// 비디오촬영이 종료되면 호출되는 함수
- (void)captureOutput:(AVCaptureFileOutput *)output
    didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
                        fromConnections:(NSArray<AVCaptureConnection *> *)connections
                                  error:(nullable NSError *)error {
  // 백그라운드 태스크 종료
  UIBackgroundTaskIdentifier currentBackgroundRecordingID = self.backgroundRecordingID;
  self.backgroundRecordingID = UIBackgroundTaskInvalid;

  // 촬영종료 후 초기화과정 블록 (임시저장파일 삭제 및 백그라운드가 종료되지 않은 경우 백그라운드태스크 종료)
  dispatch_block_t cleanUp = ^{
    if ([[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path]) {
      [[NSFileManager defaultManager] removeItemAtPath:outputFileURL.path error:NULL];
    }

    if (currentBackgroundRecordingID != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:currentBackgroundRecordingID];
    }
  };

  BOOL success = YES;
  if (error) {  // 에러로 비디오촬영종료 성공여부 확인
    NSLog(@"Movie file finishing error: %@", error);
    success = [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
  }

  // 비디오촬영 성공여부 알림
  if (_videoRecordingComplete) {
    _videoRecordingComplete(success);
    _videoRecordingComplete = nil;
  }

  if (success) {  // 성공적으로 촬영이 종료되었다면 영상저장
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
      if (status == PHAuthorizationStatusAuthorized) {
        // Save the movie file to the photo library and cleanup.
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
          PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
          options.shouldMoveFile = YES;
          PHAssetCreationRequest *creationRequest = [PHAssetCreationRequest creationRequestForAsset];
          [creationRequest addResourceWithType:PHAssetResourceTypeVideo fileURL:outputFileURL options:options];
        }
            completionHandler:^(BOOL success, NSError *error) {
              if (!success) {
                NSLog(@"Could not save movie to photo library: %@", error);
              }
              cleanUp();
            }];
      } else {
        cleanUp();
      }
    }];
  } else {
    cleanUp();
  }
}

#pragma mark - camera options

// sync하게 카메라/비디오 모드 설정
- (void)setMode:(CameraMode)mode {
  if (_mode != mode) {
    _mode = mode;
    if (_mode == CameraModePhoto) {                             // 카메라모드일때
      [self.captureSession beginConfiguration];                 // 캡쳐세션 설정시작
      [self.captureSession removeOutput:self.movieFileOutput];  // 비디오출력 제거
      self.movieFileOutput = nil;

      self.captureSession.sessionPreset = AVCaptureSessionPresetPhoto;  // 사진 프리셋 설정

      if (self.photoOutput.livePhotoCaptureSupported) {  // 라이브포토가 되면 적용
        self.photoOutput.livePhotoCaptureEnabled = self.livePhotoEnable;
      } else {
        self.photoOutput.livePhotoCaptureEnabled = NO;
      }

      if (@available(iOS 11.0, *)) {  // depthDataDelivery가 되면 적용
        if (self.photoOutput.depthDataDeliverySupported) {
          self.photoOutput.depthDataDeliveryEnabled = self.depthDataDeliveryEnable;
        } else {
          self.photoOutput.depthDataDeliveryEnabled = NO;
        }
      }

      if (@available(iOS 12.0, *)) {
        if (self.photoOutput.portraitEffectsMatteDeliverySupported) {
          self.photoOutput.portraitEffectsMatteDeliveryEnabled = self.portraitEffectsMatteEnable;
        } else {
          self.photoOutput.portraitEffectsMatteDeliveryEnabled = NO;
        }
      }

      [self.captureSession commitConfiguration];  // 캡쳐세션 설정 종료
    } else if (_mode == CameraModeVideo) {        // 비디오모드일때
      AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];  // 비디오출력 생성
      if ([self.captureSession canAddOutput:movieFileOutput]) {  // 생성된 비디오출력을 캡쳐세션에 추가할 수 있으면
        [self.captureSession beginConfiguration];         // 캡쳐 세션 설정 시작
        [self.captureSession addOutput:movieFileOutput];  // 비디오출력 추가

        // 비디오안정화?기능이 지원되면 적용
        AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
        if (connection.isVideoStabilizationSupported) {
          connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
        }

        self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;  // 비디오 프리셋 설정
        [self.captureSession commitConfiguration];                       // 캡쳐세션 설정 종료
        self.movieFileOutput = movieFileOutput;                          // 현재 비디오출력 업데이트
      }
    }
  }
}

// async하게 카메라/비디오 모드 설정
- (void)setMode:(CameraMode)mode complete:(void (^)(void))complete {
  dispatch_async([Camera sessionQueue], ^{
    self.mode = mode;
    if (complete) complete();
  });
}

// sync하게 카메라 전/후면 설정
- (void)setPosition:(AVCaptureDevicePosition)position {
  if (_position != position) {
    _position = position;
    [self configureCameraDevice:nil];
  }
}

// async하게 카메라 전/후면 설정
- (void)setPosition:(AVCaptureDevicePosition)position complete:(void (^)(void))complete {
  dispatch_async([Camera sessionQueue], ^{
    self.position = position;
    if (complete) complete();
  });
}

// flash 설정
- (void)setFlash:(AVCaptureFlashMode)flash {
  if (_flash != flash) {
    _flash = flash;
  }
}

// focus 설정
- (void)setFocus:(AVCaptureFocusMode)focus {
  if (_focus != focus) {
    _focus = focus;
  }
}

- (void)setExposure:(AVCaptureExposureMode)exposure {
  if (_exposure != exposure) {
    _exposure = exposure;
  }
}

- (void)setLivePhotoEnable:(BOOL)livePhotoEnable {
  if (_livePhotoEnable != livePhotoEnable) {
    // livePhoto 지원이 안되는데 활성화할 경우 예외처리
    if (!self.photoOutput.livePhotoCaptureSupported && livePhotoEnable) return;
    _livePhotoEnable = livePhotoEnable;
  }
}

- (void)setDepthDataDeliveryEnable:(BOOL)depthDataDeliveryEnable {
  if (@available(iOS 11.0, *)) {
    if (_depthDataDeliveryEnable != depthDataDeliveryEnable) {
      // depthDataDelivery 지원이 안되는데 활성화할 경우 예외처리
      if (!self.photoOutput.depthDataDeliverySupported && depthDataDeliveryEnable) return;
      _depthDataDeliveryEnable = depthDataDeliveryEnable;
    }
  } else {
    _depthDataDeliveryEnable = NO;
  }
}

- (void)setPortraitEffectsMatteEnable:(BOOL)portraitEffectsMatteEnable {
  if (@available(iOS 12.0, *)) {
    if (_portraitEffectsMatteEnable != portraitEffectsMatteEnable) {
      // portraitEffectsMatteEnable 지원이 안되는데 활성화할 경우 예외처리
      if ((!self.photoOutput.portraitEffectsMatteDeliverySupported || !self.depthDataDeliveryEnable) &&
          portraitEffectsMatteEnable)
        return;
      _portraitEffectsMatteEnable = portraitEffectsMatteEnable;
    }
  } else {
    _portraitEffectsMatteEnable = NO;
  }
}

- (void)setRawDataEnable:(BOOL)rawDataEnable {
  if (_rawDataEnable != rawDataEnable) {
    _rawDataEnable = rawDataEnable;
  }
}

- (void)setFocusExposurePoint:(CGPoint)point {
  [self focusWithMode:AVCaptureFocusModeAutoFocus
                exposeWithMode:AVCaptureExposureModeAutoExpose
                 atDevicePoint:point
      monitorSubjectAreaChange:YES];
}

- (void)focusWithMode:(AVCaptureFocusMode)focusMode
              exposeWithMode:(AVCaptureExposureMode)exposureMode
               atDevicePoint:(CGPoint)point
    monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange {
  dispatch_async([Camera sessionQueue], ^{
    AVCaptureDevice *device = self.videoInput.device;
    NSError *error = nil;
    if ([device lockForConfiguration:&error]) {
      /*
       Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
       Call set(Focus/Exposure)Mode() to apply the new point of interest.
       */
      if (device.isFocusPointOfInterestSupported && [device isFocusModeSupported:focusMode]) {
        device.focusPointOfInterest = point;
        device.focusMode = focusMode;
      }

      if (device.isExposurePointOfInterestSupported && [device isExposureModeSupported:exposureMode]) {
        device.exposurePointOfInterest = point;
        device.exposureMode = exposureMode;
      }

      device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange;
      [device unlockForConfiguration];
    } else {
      NSLog(@"Could not lock device for configuration: %@", error);
    }
  });
}

#pragma mark - private functions
- (AVCaptureDeviceFormat *)currentFormat {
  return self.cameraDevice.activeFormat;
}

- (AVCaptureDeviceDiscoverySession *)cameraDiscoverySession {
  if (!_cameraDiscoverySession) {
    NSArray<AVCaptureDeviceType> *deviceTypes;
    if (@available(iOS 11.1, *)) {
      deviceTypes = @[
        AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInDualCamera,
        AVCaptureDeviceTypeBuiltInTrueDepthCamera
      ];
    } else {
      deviceTypes = @[ AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInDualCamera ];
    }
    _cameraDiscoverySession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
  }
  return _cameraDiscoverySession;
}

- (AVCaptureSession *)captureSession {
  if (!_captureSession) {
    _captureSession = [[AVCaptureSession alloc] init];
  }
  return _captureSession;
}

- (AVCapturePhotoOutput *)photoOutput {
  if (!_photoOutput) {
    _photoOutput = [[AVCapturePhotoOutput alloc] init];
    _photoOutput.highResolutionCaptureEnabled = YES;
  }
  return _photoOutput;
}

- (BOOL)configureCameraDevice:(NSError **)error {
  AVCaptureDeviceType deviceType;
  if (_position == AVCaptureDevicePositionFront) {
    if (@available(iOS 11.1, *)) {
      deviceType = AVCaptureDeviceTypeBuiltInTrueDepthCamera;
    } else {
      deviceType = AVCaptureDeviceTypeBuiltInWideAngleCamera;
    }
  } else {
    deviceType = AVCaptureDeviceTypeBuiltInWideAngleCamera;  // AVCaptureDeviceTypeBuiltInDualCamera;
  }

  AVCaptureDevice *newCameraDevice = nil;
  NSArray<AVCaptureDevice *> *devices = self.cameraDiscoverySession.devices;

  for (AVCaptureDevice *device in devices) {
    if (device.position == _position && [device.deviceType isEqualToString:deviceType]) {
      newCameraDevice = device;
      break;
    }
  }

  if (!newCameraDevice) {
    for (AVCaptureDevice *device in devices) {
      if (device.position == _position) {
        newCameraDevice = device;
        break;
      }
    }
  }

  if (newCameraDevice) {
    AVCaptureDeviceInput *newVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:newCameraDevice error:error];
    if (newVideoInput) {
      [self.captureSession beginConfiguration];

      if (self.videoInput) {
        [self.captureSession removeInput:self.videoInput];
      }

      if ([self.captureSession canAddInput:newVideoInput]) {
        [self.captureSession addInput:newVideoInput];
        self.videoInput = newVideoInput;
        self.cameraDevice = newCameraDevice;
      } else if (self.videoInput) {
        [self.captureSession addInput:self.videoInput];
      } else {
        [self.captureSession commitConfiguration];
        return NO;
      }

      AVCaptureConnection *movieFileOutputConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
      if (movieFileOutputConnection.isVideoStabilizationSupported) {
        movieFileOutputConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
      }

      self.photoOutput.livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureSupported;
      if (@available(iOS 11.0, *)) {
        self.photoOutput.depthDataDeliveryEnabled = self.photoOutput.depthDataDeliverySupported;
      }
      if (@available(iOS 12.0, *)) {
        self.photoOutput.portraitEffectsMatteDeliveryEnabled = self.photoOutput.portraitEffectsMatteDeliverySupported;
      }

      [self.captureSession commitConfiguration];
    } else {
      return NO;
    }
  } else {
    return NO;
  }
  return YES;
}

- (AVCapturePhotoSettings *)configurePhotoSetting {
  // AVCapturePhotoSettings 생성
  AVCapturePhotoSettings *setting;

  if (@available(iOS 11.0, *)) {
    if (self.rawDataEnable && self.photoOutput.availableRawPhotoPixelFormatTypes.count > 0) {
//      NSLog(@"dbtest raw types : %@",self.photoOutput.availableRawPhotoFileTypes);
//      setting = [AVCapturePhotoSettings photoSettingsWithRawPixelFormatType:kCVPixelFormatType_420YpCbCr8PlanarFullRange
//                                                            processedFormat:@{AVVideoCodecKey : AVVideoCodecTypeHEVC}];
      setting.autoStillImageStabilizationEnabled = NO;
    } else if ([self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeHEVC]) {
      setting = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey : AVVideoCodecTypeHEVC}];
    } else {
      setting = [AVCapturePhotoSettings photoSettings];
    }
  } else {
    setting = [AVCapturePhotoSettings photoSettings];
  }

  // flash 모드적용
  if (self.cameraDevice.isFlashAvailable) {
    [[self.photoOutput supportedFlashModes] enumerateObjectsUsingBlock:^(NSNumber *mode, NSUInteger idx, BOOL *stop) {
      if (mode.integerValue == self.flash) {
        setting.flashMode = self.flash;
        *stop = YES;
      }
    }];
  }

  setting.highResolutionPhotoEnabled = YES;  // 해상도 최대로 사용?

  if (setting.availablePreviewPhotoPixelFormatTypes.count > 0) {  // 이건 뭐하는 건지 모르겠다. 예제에 있길래 넣은 코드
    setting.previewPhotoFormat =
        @{(NSString *)kCVPixelBufferPixelFormatTypeKey : setting.availablePreviewPhotoPixelFormatTypes.firstObject};
  }

  // 라이브포토설정, 라이브포토를 임시저장해놓을 경로설정
  if (self.livePhotoEnable && self.photoOutput.livePhotoCaptureSupported) {
    NSString *livePhotoMovieFileName = [NSUUID UUID].UUIDString;
    NSString *livePhotoMovieFilePath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[livePhotoMovieFileName stringByAppendingPathExtension:@"mov"]];
    setting.livePhotoMovieFileURL = [NSURL fileURLWithPath:livePhotoMovieFilePath];
  }

  // depth data 설정
  if (@available(iOS 11.0, *)) {
    if (self.depthDataDeliveryEnable && self.photoOutput.depthDataDeliverySupported) {
      setting.depthDataDeliveryEnabled = YES;
    } else {
      setting.depthDataDeliveryEnabled = NO;
    }
  }

  // portraitEffectsMatte 설정
  if (@available(iOS 12.0, *)) {
    if (self.portraitEffectsMatteEnable && self.photoOutput.portraitEffectsMatteDeliverySupported) {
      setting.portraitEffectsMatteDeliveryEnabled = YES;
    } else {
      setting.portraitEffectsMatteDeliveryEnabled = NO;
    }
  }

  return setting;
}

#pragma mark KVO and Notifications

- (void)addObservers {
  // 카메라화면에 많은 변화가 생기면 호출되는 노티피케이션 등록
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(subjectAreaDidChange:)
                                               name:AVCaptureDeviceSubjectAreaDidChangeNotification
                                             object:self.videoInput.device];

  // 캡쳐세션에 에러발생 시 호출되는 노티피케이션 등록
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(sessionRuntimeError:)
                                               name:AVCaptureSessionRuntimeErrorNotification
                                             object:self.captureSession];

#if USE_INTERRUPTION_NOTIFICATION
  // 캡쳐세션에 인터럽트가 걸리면 호출되는 노티피케이션 등록
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(captureSessionWasInterrupted:)
                                               name:AVCaptureSessionWasInterruptedNotification
                                             object:self.captureSession];
  
  // 캡쳐세션 인터럽트가 끝나면 호출되는 노티피케이션 등록
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(captureSessionInterruptionEnded:)
                                               name:AVCaptureSessionInterruptionEndedNotification
                                             object:self.captureSession];
#endif
}

- (void)removeObservers {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)sessionRuntimeError:(NSNotification *)notification { // 캡쳐세션 에러발생 시
  NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
  NSLog(@"Capture session runtime error: %@", error);
  
  if (error.code == AVErrorMediaServicesWereReset) { // 미디어서비스가 리셋된경우
    dispatch_async([Camera sessionQueue], ^{
      if (self.sessionRunning) { // 기존 캡쳐세션이 작동하기 있었으면 다시 시작
        [self.captureSession startRunning];
        self.sessionRunning = self.captureSession.isRunning;
      }
    });
  }
}

- (void)subjectAreaDidChange:(NSNotification *)notification { // 카메라화면에 많은 변화가 있으면 다시 포커스와 밝기를 맞춘다.
  [self focusWithMode:self.focus
       exposeWithMode:self.exposure
        atDevicePoint:CGPointMake(0.5, 0.5)
monitorSubjectAreaChange:NO];
}

#if USE_INTERRUPTION_NOTIFICATION
- (void)captureSessionWasInterrupted:(NSNotification *)notification {
  
}

- (void)captureSessionInterruptionEnded:(NSNotification *)notification {
  
}
#endif

@end
