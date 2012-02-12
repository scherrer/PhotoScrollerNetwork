//
//  MyClass.m
//  Concurrent_NSOperation
//
//  Created by David Hoerl on 6/13/11.
//  Copyright 2011 David Hoerl. All rights reserved.
//

#import <mach/mach_time.h>

#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h> // kUTTypePNG

#import "ConcurrentOp.h"

#import "TiledImageBuilder.h"

#if ! __has_feature(objc_arc)
#error THIS CODE MUST BE COMPILED WITH ARC ENABLED!
#endif

// Defines for All
#define UPDATE_LEVELS 4

//#undef TURBO
//#define TURBOS
//#define CGIMAGESOURCE

#ifdef TURBOS
#include <turbojpeg.h>
#endif

#ifdef TURBO	
#include <jpeglib.h>
#include <setjmp.h>

#define SCAN_LINE_MAX			4	// docs imply this is the most you can get
#define INCREMENT_THRESHOLD		4096*8	// what's used for the file data source, so why not reuse it here (could make it a lot bigger if you wanted to

static void my_error_exit(j_common_ptr cinfo);

static void init_source(j_decompress_ptr cinfo);
static boolean fill_input_buffer(j_decompress_ptr cinfo);
static void skip_input_data(j_decompress_ptr cinfo, long num_bytes);
static boolean resync_to_restart(j_decompress_ptr cinfo, int desired);
static void term_source(j_decompress_ptr cinfo);

/*
 * Here's the routine that will replace the standard error_exit method:
 */
struct my_error_mgr {
  struct jpeg_error_mgr pub;		/* "public" fields */
  jmp_buf setjmp_buffer;			/* for return to caller */
};
typedef struct my_error_mgr * my_error_ptr;

typedef struct {
	struct jpeg_source_mgr				pub;
	struct jpeg_decompress_struct		cinfo;
	struct my_error_mgr					jerr;
	
	//__unsafe_unretained ConcurrentOp	*op;
	unsigned char						*data;
	size_t								data_length;
	size_t								consumed_data;		// where the next chunk of data should come from, offset into the NSData object
	size_t								writtenLines;
	boolean								start_of_stream;
	boolean								got_header;
	boolean								failed;
} co_jpeg_source_mgr;

#endif


static uint64_t DeltaMAT(uint64_t then, uint64_t now)
{
	uint64_t delta = now - then;

	/* Get the timebase info */
	mach_timebase_info_data_t info;
	mach_timebase_info(&info);

	/* Convert to nanoseconds */
	delta *= info.numer;
	delta /= info.denom;

	return delta / 1e6; // ms
}


@interface ConcurrentOp ()
@property (nonatomic, assign) BOOL executing, finished;
@property (nonatomic, assign) int loops;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSURLConnection *connection;

- (BOOL)setup;
- (void)timer:(NSTimer *)timer;
- (uint64_t)timeStamp;

@end

@interface ConcurrentOp (NSURLConnectionDelegate)

- (void)outputScanLines;

@end

@implementation ConcurrentOp
{
	void							*addr;
	NSUInteger						highWaterMark;
//	NSUInteger						markIncrement;
	uint64_t						timeStamp;
#ifdef TURBOS	
	tjhandle						decompressor;
#endif

#ifdef TURBO
	co_jpeg_source_mgr				src_mgr;
	unsigned char					*scanLines[SCAN_LINE_MAX];
#endif
}
@synthesize index;
@synthesize thread;
@synthesize executing, finished;
@synthesize loops;
@synthesize timer;
@synthesize connection;
@synthesize webData;
@synthesize url;
@synthesize imageBuilder;

- (BOOL)isConcurrent { return YES; }
- (BOOL)isExecuting { return executing; }
- (BOOL)isFinished { return finished; }

- (void)start
{
	if([self isCancelled]) {
		NSLog(@"OP: cancelled before I even started!");
		[self willChangeValueForKey:@"isFinished"];
		finished = YES;
		[self didChangeValueForKey:@"isFinished"];
		return;
	}

	NSLog(@"OP: start");
	@autoreleasepool
	{
		loops = 1;	// testing
		self.thread	= [NSThread currentThread];	// do this first, to enable future messaging
		self.timer	= [NSTimer scheduledTimerWithTimeInterval:60*60 target:self selector:@selector(timer:) userInfo:nil repeats:NO];
			// makes runloop functional
		
		[self willChangeValueForKey:@"isExecuting"];
		executing = YES;
		[self didChangeValueForKey:@"isExecuting"];
			
		BOOL allOK = [self setup];

		if(allOK) {
			while(![self isFinished]) {
				assert([NSThread currentThread] == thread);
				//NSLog(@"main: sitting in loop (loops=%d)", loops);
				BOOL ret = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
				assert(ret && "first assert"); // could remove this - its here to convince myself all is well
			}
			NSLog(@"OP: finished - %@", [self isCancelled] ? @"was canceled" : @"normal completion");
		} else {
			[self finish];

			NSLog(@"OP: finished - setup failed");
		}
		// Objects retaining us
		[timer invalidate], self.timer = nil;
		[connection cancel], self.connection = nil;
	}
}

- (BOOL)setup
{
	NSLog(@"OP: setup");

	NSURLRequest *request = [NSURLRequest requestWithURL:url];
	self.connection =  [[NSURLConnection alloc] initWithRequest:request delegate:self];

#ifdef TURBOS
	 decompressor = tjInitDecompress();
#endif

	[thread setName:@"ConcurrentOp"];
	NSLog(@"Thread ptr=%p stackSize=%u", thread, [thread stackSize]);
	return YES;
}

- (void)runConnection
{
	[connection performSelector:@selector(start) onThread:thread withObject:nil waitUntilDone:NO];
}

- (void)cancel
{
	[super cancel];
	
	[connection cancel];

	if([self isExecuting]) {
		[self performSelector:@selector(finish) onThread:thread withObject:nil waitUntilDone:NO];
	}
}

- (void)finish
{
	// This order per the Concurrency Guide - some authors switch the didChangeValueForKey order.
	[self willChangeValueForKey:@"isFinished"];
	[self willChangeValueForKey:@"isExecuting"];

	executing = NO;
	finished = YES;

	[self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

- (void)timer:(NSTimer *)timer
{
}

- (void)dealloc
{
	NSLog(@"OP: dealloc"); // didn't always see this message :-)

#ifdef TURBOS
	 if(decompressor) tjDestroy(decompressor);
#endif

#ifdef TURBO
	if(src_mgr.cinfo.src) jpeg_destroy_decompress(&src_mgr.cinfo);
#endif

	[timer invalidate], timer = nil;
	[connection cancel], connection = nil;
}

- (uint64_t)timeStamp
{
	return mach_absolute_time();
}

@end

@implementation ConcurrentOp (NSURLConnectionDelegate)

- (void)connection:(NSURLConnection *)conn didReceiveResponse:(NSURLResponse *)response
{	
	if([super isCancelled]) {
		[connection cancel];
		return;
	}

	NSUInteger responseLength = response.expectedContentLength == NSURLResponseUnknownLength ? 1024*1000 : response.expectedContentLength;

#ifndef NDEBUG
	NSLog(@"ConcurrentOp: response=%@ len=%lu", response, (unsigned long)responseLength);
#endif
	self.webData = [NSMutableData dataWithCapacity:responseLength];
	
#ifdef TURBO
	//markIncrement = (NSUInteger)responseLength/UPDATE_LEVELS;
	//highWaterMark = markIncrement;
	highWaterMark = INCREMENT_THRESHOLD;

	src_mgr.pub.next_input_byte		= NULL;
	src_mgr.pub.bytes_in_buffer		= 0;
	src_mgr.pub.init_source			= init_source;
	src_mgr.pub.fill_input_buffer	= fill_input_buffer;
	src_mgr.pub.skip_input_data		= skip_input_data;
	src_mgr.pub.resync_to_restart	= resync_to_restart;
	src_mgr.pub.term_source			= term_source;
	
	src_mgr.consumed_data			= 0;
	src_mgr.start_of_stream			= TRUE;
	src_mgr.failed					= FALSE;

	/* We set up the normal JPEG error routines, then override error_exit. */
	src_mgr.cinfo.err = jpeg_std_error(&src_mgr.jerr.pub);
	src_mgr.jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
NSLog(@"YIKES! SETJUMP");
		src_mgr.failed = YES;
		[self cancel];
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&src_mgr.cinfo);
		src_mgr.cinfo.src = &src_mgr.pub; // MUST be after the jpeg_create_decompress - ask me how I know this :-)
		//src_mgr.pub.bytes_in_buffer = 0; /* forces fill_input_buffer on first read */
		//src_mgr.pub.next_input_byte = NULL; /* until buffer loaded */
	}
#endif
}

- (void)connection:(NSURLConnection *)conn didReceiveData:(NSData *)data
{
//NSLog(@"current=%@ mine=%@", [NSThread currentThread], thread);

#ifndef NDEBUG
	//NSLog(@"WEB SERVICE: got Data len=%u cancelled=%d", [data length], [super isCancelled]);
#endif
	if([super isCancelled]) {
		[connection cancel];
		return;
	}
#ifndef TURBO
	[webData appendData:data];
#else
	unsigned char *oldDataPtr = (unsigned char *)[webData mutableBytes];
	[webData appendData:data];
	unsigned char *newDataPtr = (unsigned char *)[webData mutableBytes];
	if(oldDataPtr != newDataPtr) {
NSLog(@"CHANGED!");
		size_t diff = src_mgr.pub.next_input_byte - src_mgr.data;
		src_mgr.pub.next_input_byte = newDataPtr + diff;
	}
	src_mgr.data = newDataPtr;
	src_mgr.data_length = [webData length];

//NSLog(@"s1=%ld s2=%d", src_mgr.data_length, highWaterMark);

	if(src_mgr.data_length > highWaterMark && !src_mgr.failed) {
		highWaterMark += INCREMENT_THRESHOLD;	// update_levels added in so the final chunk is deferred to the end
		//NSLog(@"len=%u high=%u", [webData length], highWaterMark);

		if(!src_mgr.got_header) {
			/* Step 3: read file parameters with jpeg_read_header() */
			int jret = jpeg_read_header(&src_mgr.cinfo, FALSE);
			if(jret == JPEG_SUSPENDED || jret != JPEG_HEADER_OK) return;
//NSLog(@"GOT header");
			src_mgr.got_header = YES;
			src_mgr.start_of_stream = NO;

			assert(src_mgr.cinfo.num_components == 3);
			assert(src_mgr.cinfo.image_width > 0 && src_mgr.cinfo.image_height > 0);
//NSLog(@"WID=%d HEIGHT=%d", src_mgr.cinfo.image_width, src_mgr.cinfo.image_height);

			TiledImageBuilder *tb = [TiledImageBuilder new];
			addr = [tb mapMemoryForWidth:src_mgr.cinfo.image_width height:src_mgr.cinfo.image_height];
			self.imageBuilder = tb;

			unsigned char *scratch = [tb scratchSpace];
			size_t rowBytes = tb.image0BytesPerRow;
//NSLog(@"Scratch=%p rowBytes=%ld", scratch, rowBytes);
			for(int i=0; i<SCAN_LINE_MAX; ++i) {
				scanLines[i] = scratch;
				scratch += rowBytes;
			}
			(void)jpeg_start_decompress(&src_mgr.cinfo);
		}
		if(src_mgr.got_header && !src_mgr.failed) {
			[self outputScanLines];
		}
	}
#endif
}

#ifdef TURBO
- (void)outputScanLines
{
	//NSLog(@"START LINES: %ld width=%d", src_mgr.writtenLines, src_mgr.cinfo.output_width);
	while(src_mgr.cinfo.output_scanline <  src_mgr.cinfo.image_height) {
		int lines = jpeg_read_scanlines(&src_mgr.cinfo, scanLines, SCAN_LINE_MAX);
		if(lines <= 0) break;

#if 1
		unsigned char *outPtr = (unsigned char *)addr + src_mgr.writtenLines*imageBuilder.image0BytesPerRow;
		for(int idx=0; idx<lines; ++idx) {
			unsigned char *inPtr = scanLines[idx];
			unsigned char *lastOutPtr = outPtr;

			int width = src_mgr.cinfo.output_width;
			for(int col=0; col<width; ++col) {
				outPtr[0] = 0xFF;
				outPtr[1] = inPtr[2];
				outPtr[2] = inPtr[1];
				outPtr[3] = inPtr[0];

				outPtr += 4;
				inPtr += 3;
			}
			outPtr = lastOutPtr + imageBuilder.image0BytesPerRow;
		}
		src_mgr.writtenLines += lines;
#endif
	}
	//NSLog(@"END LINES: me=%ld jpeg=%ld", src_mgr.writtenLines, src_mgr.cinfo.output_scanline);
}
#endif

- (void)connection:(NSURLConnection *)conn didFailWithError:(NSError *)error
{
#ifndef NDEBUG
	NSLog(@"ConcurrentOp: error: %@", [error description]);
#endif
	self.webData = nil;

    [connection cancel];

	[self finish];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)conn
{
	timeStamp = [self timeStamp];

	if([super isCancelled]) {
		[connection cancel];
		return;
	}
#ifndef NDEBUG
	NSLog(@"ConcurrentOp FINISHED LOADING WITH Received Bytes: %u", [webData length]);
#endif

#ifdef TURBO
	[self outputScanLines];
	jpeg_finish_decompress(&src_mgr.cinfo);
	assert(jpeg_input_complete(&src_mgr.cinfo));
	assert(src_mgr.writtenLines == src_mgr.cinfo.output_height);
#endif

#ifdef TURBOS
NSLog(@"TURBOS");
{
	unsigned char *jpegBuf = (unsigned char *)[webData mutableBytes]; // const ???
	unsigned long jpegSize = [webData length];
	int width, height, jpegSubsamp;
	int ret = tjDecompressHeader2(decompressor,
		jpegBuf,
		jpegSize,
		&width,
		&height,
		&jpegSubsamp 
		);
	assert(ret == 0);
	
	TiledImageBuilder *tb = [TiledImageBuilder new];
	addr = [tb mapMemoryForWidth:width height:height];
	self.imageBuilder = tb;
	
NSLog(@"HEADER w%d bpr%ld h%d", width, imageBuilder.image0BytesPerRow, height);	
	ret = tjDecompress2(decompressor,
		jpegBuf,
		jpegSize,
		addr,
		width,
		imageBuilder.image0BytesPerRow,
		height,
		TJPF_ABGR,
		TJFLAG_NOREALLOC
		);	
	assert(ret == 0);
	
}
#endif

#ifdef CGIMAGESOURCE
	CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)webData, NULL);
	if(imageSource) {
		CGImageRef image = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
		size_t width = CGImageGetWidth(image);
		size_t height = CGImageGetHeight(image);
		
		if(width && height) {
			TiledImageBuilder *tb = [TiledImageBuilder new];
			self.imageBuilder = tb;
			addr = [tb mapMemoryForWidth:width height:height];
			[tb drawImage:image]; // releases image
			CFRelease(imageSource);
		}
	}
#endif

	uint64_t diff = DeltaMAT(timeStamp, [self timeStamp]);

NSLog(@"FINISH: %llu milliseconds", diff);
	[self finish];
}

@end

#ifdef TURBO
static void my_error_exit(j_common_ptr cinfo)
{
  /* cinfo->err really points to a my_error_mgr struct, so coerce pointer */
  my_error_ptr myerr = (my_error_ptr) cinfo->err;

  /* Always display the message. */
  /* We could postpone this until after returning, if we chose. */
  (*cinfo->err->output_message) (cinfo);

  /* Return control to the setjmp point */
  longjmp(myerr->setjmp_buffer, 1);
}

static void init_source(j_decompress_ptr cinfo)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;
	src->start_of_stream = TRUE;
}

static boolean fill_input_buffer(j_decompress_ptr cinfo)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

	size_t unreadLen = src->data_length - src->consumed_data;
//NSLog(@"unreadLen=%ld", unreadLen);
	if((long)unreadLen <= 0) {
		return FALSE;
	}
	
	src->pub.next_input_byte = src->data + src->consumed_data;
	src->consumed_data = src->data_length;

	src->pub.bytes_in_buffer = unreadLen;
	src->start_of_stream = FALSE;
//NSLog(@"returning %ld bytes consumed=%ld this_offset=%ld", unreadLen, src->consumed_data, src->this_offset);

	return TRUE;
}

static void skip_input_data(j_decompress_ptr cinfo, long num_bytes)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

//NSLog(@"SKIPPER: %ld", num_bytes);

	if (num_bytes > 0) {
//NSLog(@"HAVE: %ld skip=%ld", src->pub.bytes_in_buffer, num_bytes);
		if(num_bytes <= src->pub.bytes_in_buffer) {
			src->pub.next_input_byte += (size_t)num_bytes;
			src->pub.bytes_in_buffer -= (size_t)num_bytes;
		} else {
			src->pub.bytes_in_buffer	= 0;
			src->consumed_data			+= num_bytes - src->pub.bytes_in_buffer;
		}
	}
}

static boolean resync_to_restart(j_decompress_ptr cinfo, int desired)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

NSLog(@"YIKES: resync_to_restart!!!");

	src->failed = TRUE;
	return FALSE;
}

static void term_source(j_decompress_ptr cinfo)
{
}

#endif

