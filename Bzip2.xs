/* Filename: Bzip2.xs
 * Author  : Paul Marquess, <pmqs@cpan.org>
 * Created : 5th October 2005
 * Version : 2.000
 *
 *   Copyright (c) 2005 Paul Marquess. All rights reserved.
 *   This program is free software; you can redistribute it and/or
 *   modify it under the same terms as Perl itself.
 *
 */


#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "bzlib.h" 

#define NEED_sv_2pv_nolen
#include "ppport.h" 

#if PERL_REVISION == 5 && (PERL_VERSION < 8 || (PERL_VERSION == 8 && PERL_SUBVERSION < 4 ))

#    ifdef SvPVbyte_force
#        undef SvPVbyte_force
#    endif

#    define SvPVbyte_force(sv,lp) SvPV_force(sv,lp)

#endif

#ifndef SvPVbyte_nolen
#    define SvPVbyte_nolen SvPV_nolen
#endif


#if PERL_REVISION == 5 && (PERL_VERSION >= 8 || (PERL_VERSION == 8 && PERL_SUBVERSION < 4 ))
#    define UTF8_AVAILABLE
#endif

typedef int                     DualType ;
typedef int                     int_undef ;

typedef unsigned long           uLong;
typedef unsigned int            uInt;

typedef struct di_stream {
    int      flags ;
#define FLAG_APPEND_OUTPUT      1
#define FLAG_CONSUME_INPUT      8
    bz_stream stream;
    uInt     bufsize; 
    int      last_error ;
    uLong    bytesInflated ;
    uLong    compressedBytes ;
    uLong    uncompressedBytes ;
    
} di_stream;

typedef di_stream * deflateStream ;
typedef di_stream * Compress__Raw__Bzip2 ;

typedef di_stream * inflateStream ;
typedef di_stream * Compress__Raw__Bunzip2 ;

#define COMPRESS_CLASS    "Compress::Raw::Bzip2"
#define UNCOMPRESS_CLASS  "Compress::Raw::Bunzip2"

#define BZERRNO "Compress::Raw::Bzip2::bzerrno"

#define ZMALLOC(to, typ) ((to = (typ *)safemalloc(sizeof(typ))), \
                                Zero(to,1,typ))


static const char * const my_z_errmsg[] = {
    "End of Stream",        /* BZ_STREAM_END        4       */
    "Finish OK",            /* BZ_FINISH_OK         3       */
    "Flush OK",             /* BZ_FLUSH_OK          2       */
    "Run OK",               /* BZ_RUN_OK            1       */
    "",                     /* BZ_OK                0       */
    "Sequence Error",       /* BZ_SEQUENCE_ERROR    (-1)    */
    "Param Error",          /* BZ_PARAM_ERROR       (-2)    */
    "Memory Error",         /* BZ_MEM_ERROR         (-3)    */
    "Data Error",           /* BZ_DATA_ERROR        (-4)    */
    "Magic Error",          /* BZ_DATA_ERROR_MAGIC  (-5)    */
    "IO Error",             /* BZ_IO_ERROR          (-6)    */
    "Unexpected EOF",       /* BZ_UNEXPECTED_EOF    (-7)    */
    "Output Buffer Full",   /* BZ_OUTBUFF_FULL      (-8)    */
    "Config Error",         /* BZ_CONFIG_ERROR      (-9)    */
    ""};

#define setDUALstatus(var, err)                                         \
                sv_setnv(var, (double)err) ;                            \
                sv_setpv(var, ((err) ? GetErrorString(err) : "")) ;     \
                SvNOK_on(var);

   
#if defined(__SYMBIAN32__)
# define NO_WRITEABLE_DATA
#endif

#define TRACE_DEFAULT 0

#ifdef NO_WRITEABLE_DATA
#  define trace TRACE_DEFAULT
#else
  static int trace = TRACE_DEFAULT ;
#endif

/* Dodge PerlIO hiding of these functions. */
#undef printf

#if 1
#define getInnerObject(x) (*av_fetch((AV*)SvRV(x), 0, FALSE))
#else
#define getInnerObject(x) ((SV*)SvRV(sv))
#endif

#ifdef BZ_NO_STDIO
void bz_internal_error(int errorcode)
{
    croak("bz_internal_error %d\n", errorcode);
}
#endif

static char *
#ifdef CAN_PROTOTYPE
GetErrorString(int error_no)
#else
GetErrorString(error_no)
int error_no ;
#endif
{
    dTHX;
    char * errstr ;
  
#if 0
    if (error_no == BZ_ERRNO) {
        errstr = Strerror(errno) ;
    }
    else
#endif
        errstr = (char*) my_z_errmsg[4 - error_no]; 

    return errstr ;
}

static void
#ifdef CAN_PROTOTYPE
DispHex(void * ptr, int length)
#else
DispHex(ptr, length)
    void * ptr;
    int length;
#endif
{
    char * p = (char*)ptr;
    int i;
    for (i = 0; i < length; ++i) {
        printf(" %02x", 0xFF & *(p+i));
    }
}


static void
#ifdef CAN_PROTOTYPE
DispStream(di_stream * s, char * message)
#else
DispStream(s, message)
    di_stream * s;
    char * message;
#endif
{

#if 0
    if (! trace)
        return ;
#endif

#define EnDis(f) (s->flags & f ? "Enabled" : "Disabled")

    printf("DispStream 0x%p", s) ;
    if (message)
        printf("- %s \n", message) ;
    printf("\n") ;

    if (!s)  {
        printf("    stream pointer is NULL\n");
    }
    else     {
        printf("    stream           0x%p\n", &(s->stream));
        printf("           opaque    0x%p\n", s->stream.opaque);
        printf("           next_in   0x%p", s->stream.next_in);
        if (s->stream.next_in){
            printf(" =>");
            DispHex(s->stream.next_in, 4);
        }
        printf("\n");

        printf("           next_out  0x%p", s->stream.next_out);
        if (s->stream.next_out){
            printf(" =>");
            DispHex(s->stream.next_out, 4);
        }
        printf("\n");

        printf("           avail_in  %lu\n",  (unsigned long)s->stream.avail_in);
        printf("           avail_out %lu\n",  (unsigned long)s->stream.avail_out);
        printf("    bufsize          %lu\n",  (unsigned long)s->bufsize);
        printf("    flags            0x%x\n", s->flags);
        printf("           APPEND    %s\n",   EnDis(FLAG_APPEND_OUTPUT));
        printf("           CONSUME   %s\n",   EnDis(FLAG_CONSUME_INPUT));

        printf("\n");

    }
}

static di_stream *
#ifdef CAN_PROTOTYPE
InitStream(void)
#else
InitStream()
#endif
{
    di_stream *s ;

    ZMALLOC(s, di_stream) ;

    return s ;
    
}

static void
#ifdef CAN_PROTOTYPE
PostInitStream(di_stream * s, int flags)
#else
PostInitStream(s, flags)
    di_stream *s ;
    int flags ;
#endif
{
    s->bufsize  = 1024 * 16 ;
    s->last_error = 0 ;
    s->flags    = flags ;
}


static SV* 
#ifdef CAN_PROTOTYPE
deRef(SV * sv, char * string)
#else
deRef(sv, string)
SV * sv ;
char * string;
#endif
{
    dTHX;
    SvGETMAGIC(sv);

    if (SvROK(sv)) {
        sv = SvRV(sv) ;
        SvGETMAGIC(sv);
        switch(SvTYPE(sv)) {
            case SVt_PVAV:
            case SVt_PVHV:
            case SVt_PVCV:
                croak("%s: buffer parameter is not a SCALAR reference", string);
        }
        if (SvROK(sv))
            croak("%s: buffer parameter is a reference to a reference", string) ;
    }

    if (!SvOK(sv)) { 
        sv = newSVpv("", 0);
    }

    return sv ;
}

static SV*
#ifdef CAN_PROTOTYPE
deRef_l(SV * sv, char * string)
#else
deRef_l(sv, string)
SV * sv ;
char * string ;
#endif
{
    dTHX;
    bool wipe = 0 ;
    
    SvGETMAGIC(sv);
    wipe = ! SvOK(sv) ;

    if (SvROK(sv)) {
        sv = SvRV(sv) ;
        SvGETMAGIC(sv);
        wipe = ! SvOK(sv) ;

        switch(SvTYPE(sv)) {
            case SVt_PVAV:
            case SVt_PVHV:
            case SVt_PVCV:
                croak("%s: buffer parameter is not a SCALAR reference", string);
        }
        if (SvROK(sv))
            croak("%s: buffer parameter is a reference to a reference", string) ;
    }

    if (SvREADONLY(sv) && PL_curcop != &PL_compiling)
        croak("%s: buffer parameter is read-only", string);

    SvUPGRADE(sv, SVt_PV);

    if (wipe)
        SvCUR_set(sv, 0);
    
    SvOOK_off(sv);
    SvPOK_only(sv);

    return sv ;
}


#include "constants.h"

MODULE = Compress::Raw::Bzip2 PACKAGE = Compress::Raw::Bzip2        PREFIX = Zip_

REQUIRE:	1.924
PROTOTYPES:	DISABLE

INCLUDE: constants.xs

BOOT:
    /* Check this version of bzip2 is == 1 */
    if (BZ2_bzlibVersion()[0] != '1')
	croak(COMPRESS_CLASS " needs bzip2 version 1.x, you have %s\n", BZ2_bzlibVersion()) ;
	
    {
        /* Create the $gzerror scalar */
        SV * gzerror_sv = perl_get_sv(BZERRNO, GV_ADDMULTI) ;
        sv_setiv(gzerror_sv, 0) ;
        sv_setpv(gzerror_sv, "") ;
        SvIOK_on(gzerror_sv) ;
    }



MODULE = Compress::Raw::Bzip2 PACKAGE = Compress::Raw::Bzip2

#define bzlibversion() BZ2_bzlibVersion()
const char *
bzlibversion()

void
_new(appendOut=1, blockSize100k=1, workfactor=0, verbosity=0)
    int appendOut
    int	blockSize100k
    int workfactor
    int verbosity
  PPCODE:
  {
    int err ;
    deflateStream s ;
#if 0
    if (trace)
        warn("in _deflateInit(level=%d, method=%d, windowBits=%d, memLevel=%d, strategy=%d, bufsize=%ld\n",
	level, method, windowBits, memLevel, strategy, bufsize) ;
#endif
    if ((s = InitStream() )) {

        err = BZ2_bzCompressInit ( &(s->stream), 
                                     blockSize100k, 
                                     verbosity,
                                     workfactor );

        if (err != BZ_OK) {
            Safefree(s) ;
            s = NULL ;
	}
	else {
            int flags = 0 ;
            if (appendOut)
                flags |= FLAG_APPEND_OUTPUT;
            PostInitStream(s, appendOut ? FLAG_APPEND_OUTPUT :0) ;
        
        }
    }
    else
        err = BZ_MEM_ERROR ;

    XPUSHs(sv_2mortal(newSViv(PTR2IV(s)))) ;
    if (GIMME == G_ARRAY) {
        SV * sv = sv_2mortal(newSViv(err)) ;
	setDUALstatus(sv, err);
        XPUSHs(sv) ;
    }
  }

MODULE = Compress::Raw::Bunzip2 PACKAGE = Compress::Raw::Bunzip2

void
_new(appendOut=1 , consume=1, small=0, verbosity=0)
    int appendOut
    int consume
    int small
    int verbosity
  PPCODE:
  {
    int err = BZ_OK ;
    inflateStream s ;
#if 0
    if (trace)
        warn("in _inflateInit(windowBits=%d, bufsize=%lu, dictionary=%lu\n",
                windowBits, bufsize, (unsigned long)SvCUR(dictionary)) ;
#endif
    if ((s = InitStream() )) {

        err = BZ2_bzDecompressInit (&(s->stream), verbosity, small);
        if (err != BZ_OK) {
            Safefree(s) ;
            s = NULL ;
	}
	if (s) {
            int flags = 0;
            if (appendOut)
                flags |= FLAG_APPEND_OUTPUT;
            if (consume)
                flags |= FLAG_CONSUME_INPUT;
	    PostInitStream(s, flags) ;
        }
    }
    else
	err = BZ_MEM_ERROR ;

    XPUSHs(sv_2mortal(newSViv(PTR2IV(s)))) ;
    if (GIMME == G_ARRAY) {
        SV * sv = sv_2mortal(newSViv(err)) ;
	setDUALstatus(sv, err);
        XPUSHs(sv) ;
    }
  }
 


MODULE = Compress::Raw::Bzip2 PACKAGE = Compress::Raw::Bzip2

void
DispStream(s, message=NULL)
    Compress::Raw::Bzip2   s
    char *  message

DualType 
bzdeflate (s, buf, output)
    Compress::Raw::Bzip2	s
    SV *	buf
    SV * 	output 
    uInt	cur_length = NO_INIT
    uInt	increment = NO_INIT
    int		RETVAL = 0;
    uInt   bufinc = NO_INIT
  CODE:
    bufinc = s->bufsize;

    /* If the input buffer is a reference, dereference it */
    buf = deRef(buf, "deflate") ;
 
    /* initialise the input buffer */
#ifdef UTF8_AVAILABLE    
    if (DO_UTF8(buf) && !sv_utf8_downgrade(buf, 1))
         croak("Wide character in " COMPRESS_CLASS "::bzdeflate input parameter");
#endif         
    s->stream.next_in = (char*)SvPVbyte_nolen(buf) ;
    s->stream.avail_in = SvCUR(buf) ;
    
    /* and retrieve the output buffer */
    output = deRef_l(output, "deflate") ;
#ifdef UTF8_AVAILABLE    
    if (DO_UTF8(output) && !sv_utf8_downgrade(output, 1))
         croak("Wide character in " COMPRESS_CLASS "::bzdeflate output parameter");
#endif         

    if((s->flags & FLAG_APPEND_OUTPUT) != FLAG_APPEND_OUTPUT) {
        SvCUR_set(output, 0);
        /* sv_setpvn(output, "", 0); */
    }
    cur_length =  SvCUR(output) ;
    s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length;
    increment =  SvLEN(output) -  cur_length;
    s->stream.avail_out =  increment;
    while (s->stream.avail_in != 0) {

        if (s->stream.avail_out == 0) {
	    /* out of space in the output buffer so make it bigger */
            Sv_Grow(output, SvLEN(output) + bufinc) ;
            cur_length += increment ;
            s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length ;
            increment = bufinc ;
            s->stream.avail_out = increment;
            bufinc *= 2 ;
        }

        RETVAL = BZ2_bzCompress(&(s->stream), BZ_RUN);
        if (RETVAL != BZ_RUN_OK) 
            break;
    }

    s->compressedBytes    += cur_length + increment - s->stream.avail_out ;
    s->uncompressedBytes  += SvCUR(buf) - s->stream.avail_in  ;

    s->last_error = RETVAL ;
    if (RETVAL == BZ_RUN_OK) {
        SvPOK_only(output);
        SvCUR_set(output, cur_length + increment - s->stream.avail_out) ;
    }
    OUTPUT:
	RETVAL
	output
  

void
DESTROY(s)
    Compress::Raw::Bzip2	s
  CODE:
    BZ2_bzCompressEnd(&s->stream) ;
    Safefree(s) ;


DualType
bzclose(s, output)
    Compress::Raw::Bzip2	s
    SV * output 
    uInt	cur_length = NO_INIT
    uInt	increment = NO_INIT
    uInt    bufinc = NO_INIT
  CODE:
    bufinc = s->bufsize;
  
    s->stream.avail_in = 0; /* should be zero already anyway */
  
    /* retrieve the output buffer */
    output = deRef_l(output, "close") ;
#ifdef UTF8_AVAILABLE    
    if (DO_UTF8(output) && !sv_utf8_downgrade(output, 1))
         croak("Wide character in " COMPRESS_CLASS "::bzclose input parameter");
#endif         
    if(! s->flags & FLAG_APPEND_OUTPUT) {
        SvCUR_set(output, 0);
        /* sv_setpvn(output, "", 0); */
    }
    cur_length =  SvCUR(output) ;
    s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length;
    increment =  SvLEN(output) -  cur_length;
    s->stream.avail_out =  increment;

    for (;;) {
        if (s->stream.avail_out == 0) {
	    /* consumed all the available output, so extend it */
            Sv_Grow(output, SvLEN(output) + bufinc) ;
            cur_length += increment ;
            s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length ;
            increment = bufinc ;
            s->stream.avail_out = increment;
            bufinc *= 2 ;
        }
        RETVAL = BZ2_bzCompress(&(s->stream), BZ_FINISH);
    
        /* deflate has finished flushing only when it hasn't used up
         * all the available space in the output buffer: 
         */
        /* if (s->stream.avail_out != 0 || RETVAL < 0 ) */
        if (RETVAL == BZ_STREAM_END || RETVAL < 0 )
            break;
    }
  
    /* RETVAL =  (RETVAL == BZ_STREAM_END ? BZ_OK : RETVAL) ; */
    s->last_error = RETVAL ;

    s->compressedBytes    += cur_length + increment - s->stream.avail_out ;
  
    if (RETVAL == BZ_STREAM_END) {
        SvPOK_only(output);
        SvCUR_set(output, cur_length + increment - s->stream.avail_out) ;
    }
    OUTPUT:
	RETVAL
	output


DualType
bzflush(s, output)
    Compress::Raw::Bzip2	s
    SV * output 
    uInt	cur_length = NO_INIT
    uInt	increment = NO_INIT
    uInt    bufinc = NO_INIT
  CODE:
    bufinc = s->bufsize;
  
    s->stream.avail_in = 0; /* should be zero already anyway */
  
    /* retrieve the output buffer */
    output = deRef_l(output, "close") ;
#ifdef UTF8_AVAILABLE    
    if (DO_UTF8(output) && !sv_utf8_downgrade(output, 1))
         croak("Wide character in " COMPRESS_CLASS "::bzflush input parameter");
#endif         
    if(! s->flags & FLAG_APPEND_OUTPUT) {
        SvCUR_set(output, 0);
        /* sv_setpvn(output, "", 0); */
    }
    cur_length =  SvCUR(output) ;
    s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length;
    increment =  SvLEN(output) -  cur_length;
    s->stream.avail_out =  increment;

    for (;;) {
        if (s->stream.avail_out == 0) {
	    /* consumed all the available output, so extend it */
            Sv_Grow(output, SvLEN(output) + bufinc) ;
            cur_length += increment ;
            s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length ;
            increment = bufinc ;
            s->stream.avail_out = increment;
            bufinc *= 2 ;
        }
        RETVAL = BZ2_bzCompress(&(s->stream), BZ_FLUSH);
    
        if (RETVAL == BZ_RUN_OK || RETVAL < 0)
                break;

        /* deflate has finished flushing only when it hasn't used up
         * all the available space in the output buffer: 
         */
        /* RETVAL == if (s->stream.avail_out != 0 || RETVAL < 0 )
            break; */
    }
  
    /* RETVAL =  (RETVAL == BZ_STREAM_END ? BZ_OK : RETVAL) ; */
    s->last_error = RETVAL ;

    s->compressedBytes    += cur_length + increment - s->stream.avail_out ;
  
    if (RETVAL == BZ_RUN_OK) {
        SvPOK_only(output);
        SvCUR_set(output, cur_length + increment - s->stream.avail_out) ;
    }
    OUTPUT:
	RETVAL
	output

uLong
total_in_lo32(s)
        Compress::Raw::Bzip2   s
    CODE:
        RETVAL = s->stream.total_in_lo32 ;
    OUTPUT:
	RETVAL

uLong
total_out_lo32(s)
        Compress::Raw::Bzip2   s
    CODE:
        RETVAL = s->stream.total_out_lo32 ;
    OUTPUT:
	RETVAL

uLong
compressedBytes(s)
        Compress::Raw::Bzip2   s
    CODE:
        RETVAL = s->compressedBytes;
  OUTPUT:
	RETVAL

uLong
uncompressedBytes(s)
        Compress::Raw::Bzip2   s
    CODE:
        RETVAL = s->uncompressedBytes;
  OUTPUT:
	RETVAL

        
MODULE = Compress::Raw::Bunzip2 PACKAGE = Compress::Raw::Bunzip2

void
DispStream(s, message=NULL)
    Compress::Raw::Bunzip2   s
    char *  message

DualType 
bzinflate (s, buf, output)
    Compress::Raw::Bunzip2	s
    SV *	buf
    SV * 	output 
    uInt	cur_length = 0;
    uInt	prefix_length = 0;
    uInt	increment = 0;
    STRLEN  stmp   = NO_INIT
    uInt    bufinc = NO_INIT
  PREINIT:
#ifdef UTF8_AVAILABLE    
    bool	out_utf8  = FALSE;
#endif    
  CODE:
    bufinc = s->bufsize;
    /* If the buffer is a reference, dereference it */
    buf = deRef(buf, "inflate") ;

    if (s->flags & FLAG_CONSUME_INPUT && SvREADONLY(buf))
        croak(UNCOMPRESS_CLASS "::bzinflate input parameter cannot be read-only when ConsumeInput is specified");
#ifdef UTF8_AVAILABLE    
    if (DO_UTF8(buf) && !sv_utf8_downgrade(buf, 1))
         croak("Wide character in " UNCOMPRESS_CLASS "::bzinflate input parameter");
#endif         
    
    /* initialise the input buffer */
    s->stream.next_in = (char*)SvPVbyte_force(buf, stmp) ;
    s->stream.avail_in = SvCUR(buf);
	
    /* and retrieve the output buffer */
    output = deRef_l(output, "inflate") ;
#ifdef UTF8_AVAILABLE    
    if (DO_UTF8(output))
         out_utf8 = TRUE ;
    if (DO_UTF8(output) && !sv_utf8_downgrade(output, 1))
         croak("Wide character in " UNCOMPRESS_CLASS "::bzinflate output parameter");
#endif         
    if((s->flags & FLAG_APPEND_OUTPUT) != FLAG_APPEND_OUTPUT) {
        SvCUR_set(output, 0);
    }
    if (SvLEN(output)) {
        prefix_length = cur_length =  SvCUR(output) ;
        s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length;
        increment = SvLEN(output) -  cur_length - 1;
        s->stream.avail_out = increment;
    }
    else {
        s->stream.avail_out = 0;
    }
    s->bytesInflated = 0;
    
    while (1) {

        if (s->stream.avail_out == 0) {
	    /* out of space in the output buffer so make it bigger */
            Sv_Grow(output, SvLEN(output) + bufinc) ;
            cur_length += increment ;
            s->stream.next_out = (char*) SvPVbyte_nolen(output) + cur_length ;
            increment = bufinc ;
            s->stream.avail_out = increment;
            bufinc *= 2 ;
        }

        RETVAL = BZ2_bzDecompress (&(s->stream));

        if (RETVAL != BZ_OK) 
            break ;

        if (s->stream.avail_out == 0)
            continue ;

        if (s->stream.avail_in == 0) {
            RETVAL = BZ_OK ;
            break ;
        }
	
    }
    
    s->last_error = RETVAL ;
    if (RETVAL == BZ_OK || RETVAL == BZ_STREAM_END) {
	unsigned in ;

        s->bytesInflated = cur_length + increment - s->stream.avail_out - prefix_length;
        s->uncompressedBytes += s->bytesInflated ;
        s->compressedBytes   += SvCUR(buf) - s->stream.avail_in  ;

        SvPOK_only(output);
        SvCUR_set(output, prefix_length + s->bytesInflated) ;
	*SvEND(output) = '\0';
#ifdef UTF8_AVAILABLE    
        if (out_utf8)
            sv_utf8_upgrade(output);
#endif        

	/* fix the input buffer */
	if (s->flags & FLAG_CONSUME_INPUT) {
	    in = s->stream.avail_in ;
	    SvCUR_set(buf, in) ;
	    if (in)
	        Move(s->stream.next_in, SvPVbyte_nolen(buf), in, char) ;	
            *SvEND(buf) = '\0';
            SvSETMAGIC(buf);
	}
    }
    OUTPUT:
	RETVAL
	buf
	output

uLong
inflateCount(s)
    Compress::Raw::Bunzip2	s
    CODE:
        RETVAL = s->bytesInflated;
  OUTPUT:
	RETVAL


void
DESTROY(s)
    Compress::Raw::Bunzip2	s
  CODE:
    BZ2_bzDecompressEnd(&s->stream) ;
    Safefree(s) ;


uLong
status(s)
        Compress::Raw::Bunzip2   s
    CODE:
	RETVAL = s->last_error ;
    OUTPUT:
	RETVAL

uLong
total_in_lo32(s)
        Compress::Raw::Bunzip2   s
    CODE:
        RETVAL = s->stream.total_in_lo32 ;
    OUTPUT:
	RETVAL

uLong
total_out_lo32(s)
        Compress::Raw::Bunzip2   s
    CODE:
        RETVAL = s->stream.total_out_lo32 ;
    OUTPUT:
	RETVAL

uLong
compressedBytes(s)
        Compress::Raw::Bunzip2   s
    CODE:
        RETVAL = s->compressedBytes;
  OUTPUT:
	RETVAL

uLong
uncompressedBytes(s)
        Compress::Raw::Bunzip2   s
    CODE:
        RETVAL = s->uncompressedBytes;
  OUTPUT:
	RETVAL

        
MODULE = Compress::Raw::Bzip2 PACKAGE = Compress::Raw::Bzip2        PREFIX = Zip_
