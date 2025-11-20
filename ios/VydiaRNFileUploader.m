#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <Photos/Photos.h>

#import "VydiaRNFileUploader.h"

// Custom NSInputStream subclass that generates multipart/form-data on-the-fly
@interface MultipartInputStream : NSInputStream <NSStreamDelegate>
@property (nonatomic, strong) NSString *boundary;
@property (nonatomic, strong) NSDictionary *parameters;
@property (nonatomic, strong) NSString *fieldName;
@property (nonatomic, strong) NSString *filename;
@property (nonatomic, strong) NSString *mimetype;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSInputStream *fileInputStream;
@property (nonatomic, assign) NSStreamStatus streamStatus;
@property (nonatomic, strong) NSError *streamError;
@property (nonatomic, assign) NSInteger currentPhase; // 0: params, 1: file header, 2: file data, 3: closing
@property (nonatomic, strong) NSData *currentData;
@property (nonatomic, assign) NSUInteger currentDataOffset;
@property (nonatomic, assign) BOOL hasOpened;
@end

@implementation MultipartInputStream

@synthesize boundary = _boundary;
@synthesize parameters = _parameters;
@synthesize fieldName = _fieldName;
@synthesize filename = _filename;
@synthesize mimetype = _mimetype;
@synthesize fileURL = _fileURL;
@synthesize fileInputStream = _fileInputStream;
@synthesize streamStatus = _streamStatus;
@synthesize streamError = _streamError;
@synthesize currentPhase = _currentPhase;
@synthesize currentData = _currentData;
@synthesize currentDataOffset = _currentDataOffset;
@synthesize hasOpened = _hasOpened;

- (instancetype)initWithBoundary:(NSString *)boundary
                       parameters:(NSDictionary *)parameters
                        fieldName:(NSString *)fieldName
                         filename:(NSString *)filename
                         mimetype:(NSString *)mimetype
                          fileURL:(NSURL *)fileURL {
    self = [super init];
    if (self) {
        _boundary = boundary;
        _parameters = parameters ?: @{};
        _fieldName = fieldName;
        _filename = filename;
        _mimetype = mimetype;
        _fileURL = fileURL;
        _streamStatus = NSStreamStatusNotOpen;
        _currentPhase = 0;
        _currentDataOffset = 0;
        _hasOpened = NO;
    }
    return self;
}

- (void)open {
    if (_hasOpened) return;
    _hasOpened = YES;
    _streamStatus = NSStreamStatusOpen;
    
    // Open file input stream
    _fileInputStream = [NSInputStream inputStreamWithURL:_fileURL];
    if (_fileInputStream) {
        [_fileInputStream open];
    }
    
    // Prepare first phase (parameters)
    [self prepareNextPhase];
}

- (void)close {
    _streamStatus = NSStreamStatusClosed;
    [_fileInputStream close];
    _fileInputStream = nil;
    _currentData = nil;
}

- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)len {
    if (_streamStatus == NSStreamStatusError || _streamStatus == NSStreamStatusClosed) {
        return -1;
    }
    
    NSInteger totalBytesRead = 0;
    
    while (totalBytesRead < len && _streamStatus == NSStreamStatusOpen) {
        // If we've consumed current phase data, move to next phase
        if (!_currentData || _currentDataOffset >= _currentData.length) {
            if (![self prepareNextPhase]) {
                // Check if it's an error or just end of stream
                if (_streamStatus == NSStreamStatusError) {
                    return -1;
                }
                // No more data (end of stream)
                break;
            }
        }
        
        // Read from current data
        NSUInteger remainingInCurrent = _currentData.length - _currentDataOffset;
        NSUInteger bytesToRead = MIN(len - totalBytesRead, remainingInCurrent);
        
        if (bytesToRead > 0) {
            memcpy(buffer + totalBytesRead, _currentData.bytes + _currentDataOffset, bytesToRead);
            _currentDataOffset += bytesToRead;
            totalBytesRead += bytesToRead;
        }
    }
    
    return totalBytesRead > 0 ? totalBytesRead : 0;
}

- (BOOL)prepareNextPhase {
    _currentDataOffset = 0;
    
    if (_currentPhase == 0) {
        // Write parameters
        NSMutableData *paramsData = [NSMutableData data];
        [_parameters enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            NSString *paramPart = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", _boundary, key, value];
            [paramsData appendData:[paramPart dataUsingEncoding:NSUTF8StringEncoding]];
        }];
        _currentData = paramsData;
        _currentPhase = 1;
        return YES;
    } else if (_currentPhase == 1) {
        // Write file header
        NSString *fileHeader = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", _boundary, _fieldName, _filename, _mimetype];
        _currentData = [fileHeader dataUsingEncoding:NSUTF8StringEncoding];
        _currentPhase = 2;
        return YES;
    } else if (_currentPhase == 2) {
        // Stream file data in chunks
        if (_fileInputStream && [_fileInputStream hasBytesAvailable]) {
            const NSUInteger chunkSize = 64 * 1024; // 64KB chunks
            uint8_t *buffer = (uint8_t *)malloc(chunkSize);
            if (buffer == NULL) {
                // Memory allocation failed - set error and return NO
                _streamStatus = NSStreamStatusError;
                NSMutableDictionary* details = [NSMutableDictionary dictionary];
                [details setValue:@"Failed to allocate memory for file streaming" forKey:NSLocalizedDescriptionKey];
                _streamError = [NSError errorWithDomain:@"MultipartInputStream" code:1 userInfo:details];
                return NO;
            }
            
            @try {
                NSInteger bytesRead = [_fileInputStream read:buffer maxLength:chunkSize];
                if (bytesRead > 0) {
                    // Copy the data to avoid buffer management issues
                    _currentData = [NSData dataWithBytes:buffer length:bytesRead];
                    free(buffer);
                    return YES;
                } else {
                    free(buffer);
                    // File stream ended, move to closing phase
                    _currentPhase = 3;
                }
            } @catch (NSException *exception) {
                free(buffer);
                _streamStatus = NSStreamStatusError;
                NSMutableDictionary* details = [NSMutableDictionary dictionary];
                [details setValue:[NSString stringWithFormat:@"Error reading file stream: %@", exception.reason] forKey:NSLocalizedDescriptionKey];
                _streamError = [NSError errorWithDomain:@"MultipartInputStream" code:2 userInfo:details];
                return NO;
            }
        } else {
            // File stream ended, move to closing phase
            _currentPhase = 3;
        }
    }
    
    if (_currentPhase == 3) {
        // Write closing boundary
        NSString *closing = [NSString stringWithFormat:@"\r\n--%@--\r\n", _boundary];
        _currentData = [closing dataUsingEncoding:NSUTF8StringEncoding];
        _currentPhase = 4; // Done after this
        return YES;
    }
    
    // All phases complete
    _streamStatus = NSStreamStatusAtEnd;
    return NO;
}

- (BOOL)hasBytesAvailable {
    if (_streamStatus == NSStreamStatusAtEnd || _streamStatus == NSStreamStatusClosed) {
        return NO;
    }
    if (_currentData && _currentDataOffset < _currentData.length) {
        return YES;
    }
    if (_currentPhase == 2 && _fileInputStream && [_fileInputStream hasBytesAvailable]) {
        return YES;
    }
    if (_currentPhase < 4) {
        return YES; // Still have phases to process
    }
    return NO;
}

- (NSStreamStatus)streamStatus {
    return _streamStatus;
}

- (NSError *)streamError {
    return _streamError;
}

@end

@implementation VydiaRNFileUploader

RCT_EXPORT_MODULE();

@synthesize bridge = _bridge;
static VydiaRNFileUploader* staticInstance = nil;
static NSString *BACKGROUND_SESSION_ID = @"ReactNativeBackgroundUpload";
NSMutableDictionary *_responsesData;
NSURLSession *_urlSession = nil;
void (^backgroundSessionCompletionHandler)(void) = nil;
BOOL limitNetwork = NO;

+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (dispatch_queue_t)methodQueue
 {
   return dispatch_get_main_queue();
 }

-(id) init {
    self = [super init];
    if (self) {
        staticInstance = self;
        _responsesData = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)_sendEventWithName:(NSString *)eventName body:(id)body {
    if (staticInstance == nil) return;
    [staticInstance sendEventWithName:eventName body:body];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"RNFileUploader-progress",
        @"RNFileUploader-error",
        @"RNFileUploader-cancelled",
        @"RNFileUploader-completed"
    ];
}

- (void)startObserving {
    // JS side is ready to receive events; create the background url session if necessary
    // iOS will then deliver the tasks completed while the app was dead (if any)
    NSString *appGroup = nil;
    double delayInSeconds = 5;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self urlSession:appGroup];
    });
}

+ (void)setCompletionHandlerWithIdentifier: (NSString *)identifier completionHandler: (void (^)())completionHandler {
    if ([BACKGROUND_SESSION_ID isEqualToString:identifier]) {
        backgroundSessionCompletionHandler = completionHandler;
    }
}

/*
 Gets file information for the path specified.  Example valid path is: file:///var/mobile/Containers/Data/Application/3C8A0EFB-A316-45C0-A30A-761BF8CCF2F8/tmp/trim.A5F76017-14E9-4890-907E-36A045AF9436.MOV
 Returns an object such as: {mimeType: "video/quicktime", size: 2569900, exists: true, name: "trim.AF9A9225-FC37-416B-A25B-4EDB8275A625.MOV", extension: "MOV"}
 */
RCT_EXPORT_METHOD(getFileInfo:(NSString *)path resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    @try {
        // Escape non latin characters in filename
        NSString *escapedPath = [path stringByAddingPercentEncodingWithAllowedCharacters: NSCharacterSet.URLQueryAllowedCharacterSet];
       
        NSURL *fileUri = [NSURL URLWithString:escapedPath];
        NSString *pathWithoutProtocol = [fileUri path];
        NSString *name = [fileUri lastPathComponent];
        NSString *extension = [name pathExtension];
        bool exists = [[NSFileManager defaultManager] fileExistsAtPath:pathWithoutProtocol];
        NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObjectsAndKeys: name, @"name", nil];
        [params setObject:extension forKey:@"extension"];
        [params setObject:[NSNumber numberWithBool:exists] forKey:@"exists"];

        if (exists)
        {
            [params setObject:[self guessMIMETypeFromFileName:name] forKey:@"mimeType"];
            NSError* error;
            NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:pathWithoutProtocol error:&error];
            if (error == nil)
            {
                unsigned long long fileSize = [attributes fileSize];
                [params setObject:[NSNumber numberWithLong:fileSize] forKey:@"size"];
            }
        }
        resolve(params);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 Borrowed from http://stackoverflow.com/questions/2439020/wheres-the-iphone-mime-type-database
*/
- (NSString *)guessMIMETypeFromFileName: (NSString *)fileName {
    CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[fileName pathExtension], NULL);
    CFStringRef MIMEType = UTTypeCopyPreferredTagWithClass(UTI, kUTTagClassMIMEType);
    
    if (UTI) {
        CFRelease(UTI);
    }
  
    if (!MIMEType) {
        return @"application/octet-stream";
    }
    return (__bridge NSString *)(MIMEType);
}

/*
 Utility method to copy a PHAsset file into a local temp file, which can then be uploaded.
 */
- (void)copyAssetToFile: (NSString *)assetUrl completionHandler: (void(^)(NSString *__nullable tempFileUrl, NSError *__nullable error))completionHandler {
    NSURL *url = [NSURL URLWithString:assetUrl];
    PHAsset *asset = [PHAsset fetchAssetsWithALAssetURLs:@[url] options:nil].lastObject;
    if (!asset) {
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:@"Asset could not be fetched.  Are you missing permissions?" forKey:NSLocalizedDescriptionKey];
        completionHandler(nil,  [NSError errorWithDomain:@"RNUploader" code:5 userInfo:details]);
        return;
    }
    PHAssetResource *assetResource = [[PHAssetResource assetResourcesForAsset:asset] firstObject];
    NSString *pathToWrite = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSURL *pathUrl = [NSURL fileURLWithPath:pathToWrite];
    NSString *fileURI = pathUrl.absoluteString;

    PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new];
    options.networkAccessAllowed = YES;

    [[PHAssetResourceManager defaultManager] writeDataForAssetResource:assetResource toFile:pathUrl options:options completionHandler:^(NSError * _Nullable e) {
        if (e == nil) {
            completionHandler(fileURI, nil);
        }
        else {
            completionHandler(nil, e);
        }
    }];
}

/*
 * Starts a file upload.
 * Options are passed in as the first argument as a js hash:
 * {
 *   url: string.  url to post to.
 *   path: string.  path to the file on the device
 *   headers: hash of name/value header pairs
 * }
 *
 * Returns a promise with the string ID of the upload.
 */
RCT_EXPORT_METHOD(startUpload:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    NSString *uploadUrl = options[@"url"];
    __block NSString *fileURI = options[@"path"];
    NSString *method = options[@"method"] ?: @"POST";
    NSString *uploadType = options[@"type"] ?: @"raw";
    NSString *fieldName = options[@"field"];
    NSString *customUploadId = options[@"customUploadId"];
    NSString *appGroup = options[@"appGroup"];
    NSDictionary *headers = options[@"headers"];
    NSDictionary *parameters = options[@"parameters"];

    @try {
        NSURL *requestUrl = [NSURL URLWithString: uploadUrl];
        if (requestUrl == nil) {
            return reject(@"RN Uploader", @"URL not compliant with RFC 2396", nil);
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestUrl];
        [request setHTTPMethod: method];

        [headers enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull val, BOOL * _Nonnull stop) {
            if ([val respondsToSelector:@selector(stringValue)]) {
                val = [val stringValue];
            }
            if ([val isKindOfClass:[NSString class]]) {
                [request setValue:val forHTTPHeaderField:key];
            }
        }];


        // asset library files have to be copied over to a temp file.  they can't be uploaded directly
        if ([fileURI hasPrefix:@"assets-library"]) {
            dispatch_group_t group = dispatch_group_create();
            dispatch_group_enter(group);
            [self copyAssetToFile:fileURI completionHandler:^(NSString * _Nullable tempFileUrl, NSError * _Nullable error) {
                if (error) {
                    dispatch_group_leave(group);
                    reject(@"RN Uploader", @"Asset could not be copied to temp file.", nil);
                    return;
                }
                fileURI = tempFileUrl;
                dispatch_group_leave(group);
            }];
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        }

        NSString *uploadId = customUploadId ? customUploadId : [[NSUUID UUID] UUIDString];
        NSURLSessionUploadTask *uploadTask;

        if ([uploadType isEqualToString:@"multipart"]) {
            NSString *uuidStr = [[NSUUID UUID] UUIDString];
            [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", uuidStr] forHTTPHeaderField:@"Content-Type"];

            // Resolve file URL
            NSString *escapedPath = [fileURI stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            NSURL *fileUrl = [NSURL URLWithString:escapedPath];
            NSString *filePath = [fileUrl path];
            
            // Verify file exists
            if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                return reject(@"RN Uploader", @"File does not exist", nil);
            }
            
            // Get filename and mimetype
            NSString *filename = [fileURI lastPathComponent];
            NSString *mimetype = [self guessMIMETypeFromFileName:fileURI];
            
            // Create multipart file using streaming approach (writes directly to file as data is generated)
            NSURL *multipartDataFileUrl = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", [self getTmpDirectory], uploadId]];
            
            // Move file writing to background queue to avoid blocking main thread and reduce memory pressure
            dispatch_queue_t backgroundQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
            dispatch_async(backgroundQueue, ^{
                @try {
                    // Use custom stream to write multipart data directly to file
                    MultipartInputStream *multipartStream = [[MultipartInputStream alloc] initWithBoundary:uuidStr
                                                                                                parameters:parameters
                                                                                                 fieldName:fieldName
                                                                                                  filename:filename
                                                                                                  mimetype:mimetype
                                                                                                   fileURL:fileUrl];
                    
                    [multipartStream open];
                    
                    // Ensure output directory exists
                    NSString *outputDir = [[multipartDataFileUrl path] stringByDeletingLastPathComponent];
                    NSFileManager *fileManager = [NSFileManager defaultManager];
                    NSError *dirError = nil;
                    if (![fileManager fileExistsAtPath:outputDir]) {
                        [fileManager createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:&dirError];
                        if (dirError != nil) {
                            [multipartStream close];
                            dispatch_async(dispatch_get_main_queue(), ^{
                                reject(@"RN Uploader", @"Failed to create output directory", nil);
                            });
                            return;
                        }
                    }
                    
                    // Create output file and write stream data to it
                    [fileManager createFileAtPath:[multipartDataFileUrl path] contents:nil attributes:nil];
                    NSError *fileHandleError = nil;
                    NSFileHandle *outputHandle = [NSFileHandle fileHandleForWritingToURL:multipartDataFileUrl error:&fileHandleError];
                    
                    if (outputHandle == nil || fileHandleError != nil) {
                        [multipartStream close];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            reject(@"RN Uploader", @"Failed to create output file", nil);
                        });
                        return;
                    }
                    
                    // Stream data from multipart stream to file
                    const NSUInteger bufferSize = 64 * 1024; // 64KB buffer
                    uint8_t *buffer = (uint8_t *)malloc(bufferSize);
                    if (buffer == NULL) {
                        [multipartStream close];
                        [outputHandle closeFile];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            reject(@"RN Uploader", @"Failed to allocate buffer", nil);
                        });
                        return;
                    }
                    
                    BOOL streamError = NO;
                    NSError *streamErrorObj = nil;
                    @try {
                        while ([multipartStream hasBytesAvailable]) {
                            @autoreleasepool {
                                NSInteger bytesRead = [multipartStream read:buffer maxLength:bufferSize];
                                if (bytesRead < 0) {
                                    // Error reading from stream
                                    streamError = YES;
                                    streamErrorObj = [multipartStream streamError];
                                    break;
                                }
                                if (bytesRead == 0) {
                                    // End of stream
                                    break;
                                }
                                
                                // Create NSData and write immediately to minimize memory usage
                                NSData *chunkData = [NSData dataWithBytes:buffer length:bytesRead];
                                [outputHandle writeData:chunkData];
                                chunkData = nil; // Explicitly release reference
                            }
                        }
                        
                        // Check for stream errors after loop
                        if ([multipartStream streamStatus] == NSStreamStatusError) {
                            streamError = YES;
                            streamErrorObj = [multipartStream streamError];
                        }
                    } @finally {
                        free(buffer);
                        [multipartStream close];
                        [outputHandle closeFile];
                    }
                    
                    // Handle stream errors
                    if (streamError) {
                        NSString *errorMessage = streamErrorObj ? streamErrorObj.localizedDescription : @"Error reading from file stream";
                        dispatch_async(dispatch_get_main_queue(), ^{
                            reject(@"RN Uploader", errorMessage, nil);
                        });
                        return;
                    }
                    
                    // Create upload task and resume on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            NSURLSessionUploadTask *uploadTask = [[self urlSession: appGroup] uploadTaskWithRequest:request fromFile:multipartDataFileUrl];
                            uploadTask.taskDescription = uploadId;
                            [uploadTask resume];
                            resolve(uploadTask.taskDescription);
                        } @catch (NSException *exception) {
                            reject(@"RN Uploader", exception.name, nil);
                        }
                    });
                } @catch (NSException *exception) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        reject(@"RN Uploader", exception.name, nil);
                    });
                }
            });
            
            // Return early since we're handling resolve/reject in the async block
            return;
        } else {
            if (parameters.count > 0) {
                reject(@"RN Uploader", @"Parameters supported only in multipart type", nil);
                return;
            }

            uploadTask = [[self urlSession: appGroup] uploadTaskWithRequest:request fromFile:[NSURL URLWithString: fileURI]];
        }

        uploadTask.taskDescription = uploadId;

        [uploadTask resume];
        resolve(uploadTask.taskDescription);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 * Cancels file upload
 * Accepts upload ID as a first argument, this upload will be cancelled
 * Event "cancelled" will be fired when upload is cancelled.
 */
RCT_EXPORT_METHOD(cancelUpload: (NSString *)cancelUploadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    [_urlSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionTask *uploadTask in uploadTasks) {
            if ([uploadTask.taskDescription isEqualToString:cancelUploadId]){
                // == checks if references are equal, while isEqualToString checks the string value
                [uploadTask cancel];
            }
        }
    }];
    resolve([NSNumber numberWithBool:YES]);
}

RCT_EXPORT_METHOD(canSuspendIfBackground) {
    if (backgroundSessionCompletionHandler) {
        backgroundSessionCompletionHandler();
        backgroundSessionCompletionHandler = nil;
    }
}

RCT_EXPORT_METHOD(shouldLimitNetwork: (BOOL) limit) {
    limitNetwork = limit;
}

RCT_EXPORT_METHOD(getAllUploads:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    NSString *appGroup = nil;
    [[self urlSession: appGroup] getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        NSMutableArray *uploads = [NSMutableArray new];
        for (NSURLSessionUploadTask *uploadTask in uploadTasks) {
            NSString *state;
            switch (uploadTask.state) {
            case NSURLSessionTaskStateRunning:
                state = @"running";
                break;
            case NSURLSessionTaskStateSuspended:
                state = @"pending";
                break;
            case NSURLSessionTaskStateCanceling:
                state = @"cancelled";
                break;
            case NSURLSessionTaskStateCompleted:
                state = @"completed";
                break;
            }
            
            NSDictionary *upload = @{
                @"id" : uploadTask.taskDescription,
                @"state" : state
            };
            [uploads addObject:upload];
        }
        resolve(uploads);
    }];
}

- (NSURL *)createBodyWithBoundaryStreaming:(NSString *)boundary
            path:(NSString *)path
            parameters:(NSDictionary *)parameters
            fieldName:(NSString *)fieldName
            outputFileURL:(NSURL *)outputFileURL {

    // Escape non latin characters in filename
    NSString *escapedPath = [path stringByAddingPercentEncodingWithAllowedCharacters: NSCharacterSet.URLQueryAllowedCharacterSet];

    // resolve path
    NSURL *fileUri = [NSURL URLWithString: escapedPath];
    
    NSError* error = nil;
    
    // Check if source file exists
    NSString *filePath = [fileUri path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSLog(@"Failed to read file: file does not exist at path %@", filePath);
        return nil;
    }
    
    // Ensure output directory exists
    NSString *outputDir = [[outputFileURL path] stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:outputDir]) {
        [fileManager createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error != nil) {
            NSLog(@"Failed to create output directory: %@", error);
            return nil;
        }
    }
    
    // Use NSInputStream for efficient streaming of large files
    NSInputStream *inputStream = [NSInputStream inputStreamWithURL:fileUri];
    if (inputStream == nil) {
        NSLog(@"Failed to create input stream for file: %@", filePath);
        return nil;
    }
    [inputStream open];
    
    // Create output file handle for writing multipart body
    [fileManager createFileAtPath:[outputFileURL path] contents:nil attributes:nil];
    NSFileHandle *outputFileHandle = [NSFileHandle fileHandleForWritingToURL:outputFileURL error:&error];
    if (outputFileHandle == nil) {
        NSLog(@"Failed to create output file for writing: %@", error);
        [inputStream close];
        return nil;
    }

    NSString *filename  = [path lastPathComponent];
    NSString *mimetype  = [self guessMIMETypeFromFileName:path];

    // Write parameters first
    [parameters enumerateKeysAndObjectsUsingBlock:^(NSString *parameterKey, NSString *parameterValue, BOOL *stop) {
        NSString *paramHeader = [NSString stringWithFormat:@"--%@\r\n", boundary];
        NSString *paramDisposition = [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", parameterKey];
        NSString *paramValue = [NSString stringWithFormat:@"%@\r\n", parameterValue];
        
        [outputFileHandle writeData:[paramHeader dataUsingEncoding:NSUTF8StringEncoding]];
        [outputFileHandle writeData:[paramDisposition dataUsingEncoding:NSUTF8StringEncoding]];
        [outputFileHandle writeData:[paramValue dataUsingEncoding:NSUTF8StringEncoding]];
    }];

    // Write file header
    NSString *fileHeader = [NSString stringWithFormat:@"--%@\r\n", boundary];
    NSString *fileDisposition = [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fieldName, filename];
    NSString *fileContentType = [NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimetype];
    
    [outputFileHandle writeData:[fileHeader dataUsingEncoding:NSUTF8StringEncoding]];
    [outputFileHandle writeData:[fileDisposition dataUsingEncoding:NSUTF8StringEncoding]];
    [outputFileHandle writeData:[fileContentType dataUsingEncoding:NSUTF8StringEncoding]];

    // Stream file data in chunks using NSInputStream to avoid loading entire file into memory
    // Use a conservative chunk size (256KB) to minimize memory usage
    const NSUInteger bufferSize = 256 * 1024; // 256KB buffer
    uint8_t *buffer = (uint8_t *)malloc(bufferSize);
    if (buffer == NULL) {
        NSLog(@"Failed to allocate buffer for file streaming");
        [inputStream close];
        [outputFileHandle closeFile];
        return nil;
    }
    
    @try {
        NSStreamStatus streamStatus = [inputStream streamStatus];
        while (streamStatus == NSStreamStatusOpen || streamStatus == NSStreamStatusReading) {
            @autoreleasepool {
                NSInteger bytesRead = [inputStream read:buffer maxLength:bufferSize];
                if (bytesRead < 0) {
                    // Error reading from stream
                    NSStreamStatus errorStatus = [inputStream streamStatus];
                    if (errorStatus == NSStreamStatusError) {
                        NSError *streamError = [inputStream streamError];
                        NSLog(@"Error reading from input stream: %@", streamError);
                    }
                    break;
                }
                if (bytesRead == 0) {
                    // End of stream
                    break;
                }
                
                // Copy the data to avoid issues with buffer reuse
                NSData *chunk = [NSData dataWithBytes:buffer length:bytesRead];
                [outputFileHandle writeData:chunk];
                
                // Check stream status for next iteration
                streamStatus = [inputStream streamStatus];
            }
        }
    } @finally {
        free(buffer);
        [inputStream close];
    }

    // Write closing boundary
    [outputFileHandle writeData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *closingBoundary = [NSString stringWithFormat:@"--%@--\r\n", boundary];
    [outputFileHandle writeData:[closingBoundary dataUsingEncoding:NSUTF8StringEncoding]];

    // Close file handle
    [outputFileHandle closeFile];

    return outputFileURL;
}

- (NSURLSession *)urlSession: (NSString *) groupId {
    if (_urlSession == nil) {
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BACKGROUND_SESSION_ID];
        if (groupId != nil && ![groupId isEqualToString:@""]) {
            sessionConfiguration.sharedContainerIdentifier = groupId;
        }
        if (limitNetwork) {
            sessionConfiguration.allowsCellularAccess = NO;
        }
        _urlSession = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
    }

    return _urlSession;
}

- (NSString *)getTmpDirectory {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *namespace = @"react-native-upload";
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingString:namespace];
    
    [manager createDirectoryAtPath: tmpPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    return tmpPath;
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:task.taskDescription, @"id", nil];
    NSURLSessionDataTask *uploadTask = (NSURLSessionDataTask *)task;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)uploadTask.response;
    if (response != nil)
    {
        [data setObject:[NSNumber numberWithInteger:response.statusCode] forKey:@"responseCode"];
    }
    //Add data that was collected earlier by the didReceiveData method
    NSMutableData *responseData = _responsesData[@(task.taskIdentifier)];
    if (responseData) {
        [_responsesData removeObjectForKey:@(task.taskIdentifier)];
        NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        [data setObject:response forKey:@"responseBody"];
    } else {
        [data setObject:[NSNull null] forKey:@"responseBody"];
    }

    if (error == nil)
    {
        [self _sendEventWithName:@"RNFileUploader-completed" body:data];
    }
    else
    {
        [data setObject:error.localizedDescription forKey:@"error"];
        if (error.code == NSURLErrorCancelled) {
            [self _sendEventWithName:@"RNFileUploader-cancelled" body:data];
        } else {
            [self _sendEventWithName:@"RNFileUploader-error" body:data];
        }
    }

    NSURL *multipartDataFileUrl = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", [self getTmpDirectory], task.taskDescription]];
    [[NSFileManager defaultManager] removeItemAtURL:multipartDataFileUrl error:nil];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    float progress = -1;
    if (totalBytesExpectedToSend > 0) //see documentation.  For unknown size it's -1 (NSURLSessionTransferSizeUnknown)
    {
        progress = 100.0 * (float)totalBytesSent / (float)totalBytesExpectedToSend;
    }
    [self _sendEventWithName:@"RNFileUploader-progress" body:@{ @"id": task.taskDescription, @"progress": [NSNumber numberWithFloat:progress] }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data.length) {
        return;
    }
    //Hold returned data so it can be picked up by the didCompleteWithError method later
    NSMutableData *responseData = _responsesData[@(dataTask.taskIdentifier)];
    if (!responseData) {
        responseData = [NSMutableData dataWithData:data];
        _responsesData[@(dataTask.taskIdentifier)] = responseData;
    } else {
        [responseData appendData:data];
    }
}

#pragma mark - NSURLSessionDelegate

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (backgroundSessionCompletionHandler) {
        NSLog(@"RNBU Did Finish Events For Background URLSession (has backgroundSessionCompletionHandler)");
        // This long delay is set as a security if the JS side does not call :canSuspendIfBackground: promptly
        double delayInSeconds = 45.0;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            if (backgroundSessionCompletionHandler) {
                backgroundSessionCompletionHandler();
                NSLog(@"RNBU did call backgroundSessionCompletionHandler (timeout)");
                backgroundSessionCompletionHandler = nil;
            }
        });
    } else {
        NSLog(@"RNBU Did Finish Events For Background URLSession (no backgroundSessionCompletionHandler)");
    }
}

@end
