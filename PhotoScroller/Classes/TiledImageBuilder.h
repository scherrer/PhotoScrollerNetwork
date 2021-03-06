
/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *
 * This file is part of PhotoScrollerNetwork -- An iOS project that smoothly and efficiently
 * renders large images in progressively smaller ones for display in a CATiledLayer backed view.
 * Images can either be local, or more interestingly, downloaded from the internet.
 * Images can be rendered by an iOS CGImageSource, libjpeg-turbo, or incrmentally by
 * libjpeg (the turbo version) - the latter gives the best speed.
 *
 * Parts taken with minor changes from Apple's PhotoScroller sample code, the
 * ConcurrentOp from my ConcurrentOperations github sample code, and TiledImageBuilder
 * was completely original source code developed by me.
 *
 * Copyright 2012 David Hoerl All Rights Reserved.
 *
 *
 * Redistribution and use in source and binary forms, with or without modification, are
 * permitted provided that the following conditions are met:
 *
 *    1. Redistributions of source code must retain the above copyright notice, this list of
 *       conditions and the following disclaimer.
 *
 *    2. Redistributions in binary form must reproduce the above copyright notice, this list
 *       of conditions and the following disclaimer in the documentation and/or other materials
 *       provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY David Hoerl ''AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL David Hoerl OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#import "Common.h"

@interface TiledImageBuilder : NSObject
@property (nonatomic, assign) NSUInteger zoomLevels;			// explose the init setting
@property (nonatomic, assign) uint64_t startTime;				// time stamp of when this operation started decoding
@property (nonatomic, assign) uint64_t finishTime;				// time stamp of when this operation finished  decoding
@property (nonatomic, assign) uint32_t milliSeconds;			// elapsed time
@property (nonatomic, assign, readonly) BOOL failed;			// global Error flags

- (id)initWithImage:(CGImageRef)image levels:(NSUInteger)levels;
- (id)initWithImagePath:(NSString *)path withDecode:(imageDecoder)decoder levels:(NSUInteger)levels;
- (id)initForNetworkDownloadWithDecoder:(imageDecoder)dec levels:(NSUInteger)levels;

- (CGSize)imageSize;

- (CGImageRef)newImageForScale:(CGFloat)scale row:(int)row col:(int)col;
- (UIImage *)tileForScale:(CGFloat)scale row:(int)row col:(int)col;

#ifdef LIBJPEG
- (void)jpegAdvance:(NSMutableData *)data;
#endif

- (void)appendToImageFile:(NSData *)data;
- (void)dataFinished;

@end

