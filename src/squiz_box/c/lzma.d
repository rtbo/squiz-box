module squiz_box.c.lzma;

import std.traits : isIntegral;

private alias uint8_t = ubyte;
private alias uint32_t = uint;
private alias uint64_t = ulong;

// lzma/version.h

enum LZMA_VERSION_MAJOR = 5;
enum LZMA_VERSION_MINOR = 2;
enum LZMA_VERSION_PATCH = 5;
enum LZMA_VERSION_STABILITY = LZMA_VERSION_STABILITY_STABLE;

/*
 * Map symbolic stability levels to integers.
 */
enum LZMA_VERSION_STABILITY_ALPHA = 0;
enum LZMA_VERSION_STABILITY_BETA = 1;
enum LZMA_VERSION_STABILITY_STABLE = 2;

enum uint LZMA_VERSION = LZMA_VERSION_MAJOR * 10_000_000
    + LZMA_VERSION_MINOR * 10_000
    + LZMA_VERSION_PATCH * 10
    + LZMA_VERSION_STABILITY;

enum LZMA_VERSION_STRING = "5.2.5";

extern (C) uint lzma_version_number() nothrow;

extern (C) const(char)* lzma_version_string() nothrow;

// lzma/base.h

alias lzma_bool = bool;

static assert(lzma_bool.sizeof == 1);

enum lzma_reserved_enum
{
    LZMA_RESERVED_ENUM = 0,
}

enum lzma_ret
{
    LZMA_OK = 0,
    LZMA_STREAM_END = 1,
    LZMA_NO_CHECK = 2,
    LZMA_UNSUPPORTED_CHECK = 3,
    LZMA_GET_CHECK = 4,
    LZMA_MEM_ERROR = 5,
    LZMA_MEMLIMIT_ERROR = 6,
    LZMA_FORMAT_ERROR = 7,
    LZMA_OPTIONS_ERROR = 8,
    LZMA_DATA_ERROR = 9,
    LZMA_BUF_ERROR = 10,
    LZMA_PROG_ERROR = 11,
}

enum lzma_action
{
    LZMA_RUN = 0,
    LZMA_SYNC_FLUSH = 1,
    LZMA_FULL_FLUSH = 2,
    LZMA_FULL_BARRIER = 4,
    LZMA_FINISH = 3
}

struct lzma_allocator
{
    void* function(void* opaque, size_t nmemb, size_t size) alloc;
    void function(void* opaque, void* ptr) free;
    void* opaque;
}

struct lzma_internal;

struct lzma_stream
{
    const uint8_t* next_in;
    size_t avail_in;
    uint64_t total_in;

    uint8_t* next_out;
    size_t avail_out;
    uint64_t total_out;

    const(lzma_allocator)* allocator;

    lzma_internal* internal;

    void* reserved_ptr1;
    void* reserved_ptr2;
    void* reserved_ptr3;
    void* reserved_ptr4;
    uint64_t reserved_int1;
    uint64_t reserved_int2;
    size_t reserved_int3;
    size_t reserved_int4;
    lzma_reserved_enum reserved_enum1;
    lzma_reserved_enum reserved_enum2;
}

extern (C) lzma_ret lzma_code(lzma_stream* strm, lzma_action action) nothrow;

extern (C) void lzma_end(lzma_stream* strm) nothrow;

extern (C) void lzma_get_progress(lzma_stream* strm,
    uint64_t* progress_in, uint64_t* progress_out) nothrow;

extern (C) uint64_t lzma_memusage(const(lzma_stream)* strm)
nothrow pure;

extern (C) uint64_t lzma_memlimit_get(const(lzma_stream)* strm)
nothrow pure;

extern (C) lzma_ret lzma_memlimit_set(
    lzma_stream* strm, uint64_t memlimit) nothrow;

// lzma/vli.h

enum LZMA_VLI_MAX = uint64_t.max / 2;

enum LZMA_VLI_UNKNOWN = uint64_t.max;

enum LZMA_VLI_BYTES_MAX = 9;

lzma_vli LZMA_VLI_C(N)(N n) if (isIntegral!N)
{
    return n;
}

alias lzma_vli = uint64_t;

bool lzma_vli_is_valid(lzma_vli vli)
{
    return vli <= LZMA_VLI_MAX || vli == LZMA_VLI_UNKNOWN;
}

extern (C) lzma_ret lzma_vli_encode(lzma_vli vli, size_t* vli_pos,
    uint8_t* out_, size_t* out_pos, size_t out_size) nothrow;

extern (C) lzma_ret lzma_vli_decode(lzma_vli* vli, size_t* vli_pos,
    const uint8_t* in_, size_t* in_pos, size_t in_size)
nothrow;

extern (C) uint32_t lzma_vli_size(lzma_vli vli)
nothrow pure;

// lzma/check.h

enum lzma_check
{
    LZMA_CHECK_NONE = 0,
    LZMA_CHECK_CRC32 = 1,
    LZMA_CHECK_CRC64 = 4,
    LZMA_CHECK_SHA256 = 10
}

enum LZMA_CHECK_ID_MAX = 15;

extern (C) lzma_bool lzma_check_is_supported(lzma_check check)
nothrow;

extern (C) uint32_t lzma_check_size(lzma_check check)
nothrow;

enum LZMA_CHECK_SIZE_MAX = 64;

extern (C) uint32_t lzma_crc32(
    const uint8_t* buf, size_t size, uint32_t crc)
nothrow pure;

extern (C) uint64_t lzma_crc64(
    const uint8_t* buf, size_t size, uint64_t crc)
nothrow pure;

extern (C) lzma_check lzma_get_check(const lzma_stream* strm)
nothrow;

// lzma/filter.h
enum LZMA_FILTERS_MAX = 4;

struct lzma_filter
{
    lzma_vli id;
    void* options;
}

extern (C) lzma_bool lzma_filter_encoder_is_supported(lzma_vli id)
nothrow;

extern (C) lzma_bool lzma_filter_decoder_is_supported(lzma_vli id)
nothrow;

extern (C) lzma_ret lzma_filters_copy(
    const lzma_filter* src, lzma_filter* dest,
    const lzma_allocator* allocator) nothrow;

extern (C) uint64_t lzma_raw_encoder_memusage(const lzma_filter* filters)
nothrow pure;

extern (C) uint64_t lzma_raw_decoder_memusage(const lzma_filter* filters)
nothrow pure;

extern (C) lzma_ret lzma_raw_encoder(
    lzma_stream* strm, const lzma_filter* filters)
nothrow;

extern (C) lzma_ret lzma_raw_decoder(
    lzma_stream* strm, const lzma_filter* filters)
nothrow;

extern (C) lzma_ret lzma_filters_update(
    lzma_stream* strm, const lzma_filter* filters) nothrow;

extern (C) lzma_ret lzma_raw_buffer_encode(
    const lzma_filter* filters, const lzma_allocator* allocator,
    const uint8_t* in_, size_t in_size, uint8_t* out_,
    size_t* out_pos, size_t out_size) nothrow;

extern (C) lzma_ret lzma_raw_buffer_decode(
    const lzma_filter* filters, const lzma_allocator* allocator,
    const uint8_t* in_, size_t* in_pos, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size) nothrow;

extern (C) lzma_ret lzma_properties_size(
    uint32_t* size, const lzma_filter* filter) nothrow;

extern (C) lzma_ret lzma_properties_encode(
    const lzma_filter* filter, uint8_t* props) nothrow;

extern (C) lzma_ret lzma_properties_decode(
    lzma_filter* filter, const lzma_allocator* allocator,
    const uint8_t* props, size_t props_size) nothrow;

extern (C) lzma_ret lzma_filter_flags_size(
    uint32_t* size, const lzma_filter* filter)
nothrow;

extern (C) lzma_ret lzma_filter_flags_encode(const lzma_filter* filter,
    uint8_t* out_, size_t* out_pos, size_t out_size)
nothrow;

extern (C) lzma_ret lzma_filter_flags_decode(
    lzma_filter* filter, const lzma_allocator* allocator,
    const uint8_t* in_, size_t* in_pos, size_t in_size)
nothrow;

// lzma/bcj.h

enum LZMA_FILTER_X86 = LZMA_VLI_C(0x04);

enum LZMA_FILTER_POWERPC = LZMA_VLI_C(0x05);

enum LZMA_FILTER_IA64 = LZMA_VLI_C(0x06);

enum LZMA_FILTER_ARM = LZMA_VLI_C(0x07);

enum LZMA_FILTER_ARMTHUMB = LZMA_VLI_C(0x08);

enum LZMA_FILTER_SPARC = LZMA_VLI_C(0x09);

struct lzma_options_bcj
{
    uint32_t start_offset;
}

// lzma/delta.h

enum LZMA_FILTER_DELTA = LZMA_VLI_C(0x03);

enum lzma_delta_type
{
    LZMA_DELTA_TYPE_BYTE
}

enum LZMA_DELTA_DIST_MIN = 1;
enum LZMA_DELTA_DIST_MAX = 256;

struct lzma_options_delta
{
    lzma_delta_type type;

    uint32_t dist;
    uint32_t reserved_int1;
    uint32_t reserved_int2;
    uint32_t reserved_int3;
    uint32_t reserved_int4;
    void* reserved_ptr1;
    void* reserved_ptr2;
}

// lzma/lzma12.h

enum LZMA_FILTER_LZMA1 = LZMA_VLI_C(0x4000000000000001);

enum LZMA_FILTER_LZMA2 = LZMA_VLI_C(0x21);

enum lzma_match_finder
{
    LZMA_MF_HC3 = 0x03,
    LZMA_MF_HC4 = 0x04,

    LZMA_MF_BT2 = 0x12,

    LZMA_MF_BT3 = 0x13,

    LZMA_MF_BT4 = 0x14
}

extern (C) lzma_bool lzma_mf_is_supported(lzma_match_finder match_finder)
nothrow;

enum lzma_mode
{
    LZMA_MODE_FAST = 1,
    LZMA_MODE_NORMAL = 2
}

extern (C) lzma_bool lzma_mode_is_supported(lzma_mode mode)
nothrow;

enum LZMA_DICT_SIZE_MIN = 4096;
enum LZMA_DICT_SIZE_DEFAULT = 1 << 23;
enum LZMA_LCLP_MIN = 0;
enum LZMA_LCLP_MAX = 4;
enum LZMA_LC_DEFAULT = 3;
enum LZMA_LP_DEFAULT = 0;
enum LZMA_PB_MIN = 0;
enum LZMA_PB_MAX = 4;
enum LZMA_PB_DEFAULT = 2;

struct lzma_options_lzma
{
    uint32_t dict_size;

    const uint8_t* preset_dict;

    uint32_t preset_dict_size;

    uint32_t lc;

    uint32_t lp;

    uint32_t pb;
    lzma_mode mode;

    uint32_t nice_len;

    lzma_match_finder mf;

    uint32_t depth;

    uint32_t reserved_int1;
    uint32_t reserved_int2;
    uint32_t reserved_int3;
    uint32_t reserved_int4;
    uint32_t reserved_int5;
    uint32_t reserved_int6;
    uint32_t reserved_int7;
    uint32_t reserved_int8;
    lzma_reserved_enum reserved_enum1;
    lzma_reserved_enum reserved_enum2;
    lzma_reserved_enum reserved_enum3;
    lzma_reserved_enum reserved_enum4;
    void* reserved_ptr1;
    void* reserved_ptr2;
}

extern (C) lzma_bool lzma_lzma_preset(
    lzma_options_lzma* options, uint32_t preset) nothrow;

// lzma/containers.h
/************
 * Encoding *
 ************/

enum uint32_t LZMA_PRESET_DEFAULT = 6;

enum uint32_t LZMA_PRESET_LEVEL_MASK = 0x1F;

enum uint32_t LZMA_PRESET_EXTREME = 1 << 31;

struct lzma_mt
{
    uint32_t flags;

    uint32_t threads;

    uint64_t block_size;

    uint32_t timeout;

    uint32_t preset;

    const lzma_filter* filters;

    lzma_check check;

    lzma_reserved_enum reserved_enum1;
    lzma_reserved_enum reserved_enum2;
    lzma_reserved_enum reserved_enum3;
    uint32_t reserved_int1;
    uint32_t reserved_int2;
    uint32_t reserved_int3;
    uint32_t reserved_int4;
    uint64_t reserved_int5;
    uint64_t reserved_int6;
    uint64_t reserved_int7;
    uint64_t reserved_int8;
    void* reserved_ptr1;
    void* reserved_ptr2;
    void* reserved_ptr3;
    void* reserved_ptr4;
}

extern (C) uint64_t lzma_easy_encoder_memusage(uint32_t preset)
nothrow pure;

extern (C) uint64_t lzma_easy_decoder_memusage(uint32_t preset)
nothrow pure;

extern (C) lzma_ret lzma_easy_encoder(
    lzma_stream* strm, uint32_t preset, lzma_check check)
nothrow;

extern (C) lzma_ret lzma_easy_buffer_encode(
    uint32_t preset, lzma_check check,
    const lzma_allocator* allocator,
    const uint8_t* in_, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size) nothrow;

extern (C) lzma_ret lzma_stream_encoder(lzma_stream* strm,
    const lzma_filter* filters, lzma_check check)
nothrow;

extern (C) uint64_t lzma_stream_encoder_mt_memusage(
    const lzma_mt* options) nothrow pure;

extern (C) lzma_ret lzma_stream_encoder_mt(
    lzma_stream* strm, const lzma_mt* options)
nothrow;

extern (C) lzma_ret lzma_alone_encoder(
    lzma_stream* strm, const lzma_options_lzma* options)
nothrow;

extern (C) size_t lzma_stream_buffer_bound(size_t uncompressed_size)
nothrow;

extern (C) lzma_ret lzma_stream_buffer_encode(
    lzma_filter* filters, lzma_check check,
    const lzma_allocator* allocator,
    const uint8_t* in_, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size)
nothrow;

/************
 * Decoding *
 ************/
enum uint32_t LZMA_TELL_NO_CHECK = 0x01;

enum uint32_t LZMA_TELL_UNSUPPORTED_CHECK = 0x02;

enum uint32_t LZMA_TELL_ANY_CHECK = 0x04;

enum uint32_t LZMA_IGNORE_CHECK = 0x10;

enum uint32_t LZMA_CONCATENATED = 0x08;

extern (C) lzma_ret lzma_stream_decoder(
    lzma_stream* strm, uint64_t memlimit, uint32_t flags)
nothrow;

extern (C) lzma_ret lzma_auto_decoder(
    lzma_stream* strm, uint64_t memlimit, uint32_t flags)
nothrow;

extern (C) lzma_ret lzma_alone_decoder(
    lzma_stream* strm, uint64_t memlimit)
nothrow;

extern (C) lzma_ret lzma_stream_buffer_decode(
    uint64_t* memlimit, uint32_t flags,
    const lzma_allocator* allocator,
    const uint8_t* in_, size_t* in_pos, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size)
nothrow;

// lzma/stream_flags.h

enum LZMA_STREAM_HEADER_SIZE = 12;

enum LZMA_BACKWARD_SIZE_MIN = 4;
enum LZMA_BACKWARD_SIZE_MAX = (LZMA_VLI_C(1) << 34);

struct lzma_stream_flags
{
    uint32_t version_;
    lzma_vli backward_size;
    lzma_check check;

    lzma_reserved_enum reserved_enum1;
    lzma_reserved_enum reserved_enum2;
    lzma_reserved_enum reserved_enum3;
    lzma_reserved_enum reserved_enum4;
    lzma_bool reserved_bool1;
    lzma_bool reserved_bool2;
    lzma_bool reserved_bool3;
    lzma_bool reserved_bool4;
    lzma_bool reserved_bool5;
    lzma_bool reserved_bool6;
    lzma_bool reserved_bool7;
    lzma_bool reserved_bool8;
    uint32_t reserved_int1;
    uint32_t reserved_int2;
}

extern (C) lzma_ret lzma_stream_header_encode(
    const lzma_stream_flags* options, uint8_t* out_)
nothrow;

extern (C) lzma_ret lzma_stream_footer_encode(
    const lzma_stream_flags* options, uint8_t* out_)
nothrow;

extern (C) lzma_ret lzma_stream_header_decode(
    lzma_stream_flags* options, const uint8_t* in_)
nothrow;

extern (C) lzma_ret lzma_stream_footer_decode(
    lzma_stream_flags* options, const uint8_t* in_)
nothrow;

extern (C) lzma_ret lzma_stream_flags_compare(
    const lzma_stream_flags* a, const lzma_stream_flags* b)
nothrow pure;

// lzma/block.h

enum LZMA_BLOCK_HEADER_SIZE_MIN = 8;
enum LZMA_BLOCK_HEADER_SIZE_MAX = 1024;

struct lzma_block
{
    uint32_t version_;

    uint32_t header_size;

    lzma_check check;

    lzma_vli compressed_size;

    lzma_vli uncompressed_size;

    lzma_filter* filters;

    uint8_t[LZMA_CHECK_SIZE_MAX] raw_check;

    void* reserved_ptr1;
    void* reserved_ptr2;
    void* reserved_ptr3;
    uint32_t reserved_int1;
    uint32_t reserved_int2;
    lzma_vli reserved_int3;
    lzma_vli reserved_int4;
    lzma_vli reserved_int5;
    lzma_vli reserved_int6;
    lzma_vli reserved_int7;
    lzma_vli reserved_int8;
    lzma_reserved_enum reserved_enum1;
    lzma_reserved_enum reserved_enum2;
    lzma_reserved_enum reserved_enum3;
    lzma_reserved_enum reserved_enum4;

    lzma_bool ignore_check;

    lzma_bool reserved_bool2;
    lzma_bool reserved_bool3;
    lzma_bool reserved_bool4;
    lzma_bool reserved_bool5;
    lzma_bool reserved_bool6;
    lzma_bool reserved_bool7;
    lzma_bool reserved_bool8;
}

uint32_t lzma_block_header_size_decode(B)(B b)
{
    return (b + 1) * 4;
}

extern (C) lzma_ret lzma_block_header_size(lzma_block* block)
nothrow;

extern (C) lzma_ret lzma_block_header_encode(
    const lzma_block* block, uint8_t* out_)
nothrow;

extern (C) lzma_ret lzma_block_header_decode(lzma_block* block,
    const lzma_allocator* allocator, const uint8_t* in_)
nothrow;

extern (C) lzma_ret lzma_block_compressed_size(
    lzma_block* block, lzma_vli unpadded_size)
nothrow;

extern (C) lzma_vli lzma_block_unpadded_size(const lzma_block* block)
nothrow pure;

extern (C) lzma_vli lzma_block_total_size(const lzma_block* block)
nothrow pure;

extern (C) lzma_ret lzma_block_encoder(
    lzma_stream* strm, lzma_block* block)
nothrow;

extern (C) lzma_ret lzma_block_decoder(
    lzma_stream* strm, lzma_block* block)
nothrow;

extern (C) size_t lzma_block_buffer_bound(size_t uncompressed_size)
nothrow;

extern (C) lzma_ret lzma_block_buffer_encode(
    lzma_block* block, const lzma_allocator* allocator,
    const uint8_t* in_, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size)
nothrow;

extern (C) lzma_ret lzma_block_uncomp_encode(lzma_block* block,
    const uint8_t* in_, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size)
nothrow;

extern (C) lzma_ret lzma_block_buffer_decode(
    lzma_block* block, const lzma_allocator* allocator,
    const uint8_t* in_, size_t* in_pos, size_t in_size,
    uint8_t* out_, size_t* out_pos, size_t out_size)
nothrow;

// lzma/index.h

struct lzma_index;

struct lzma_index_iter_stream
{
    const lzma_stream_flags* flags;

    const void* reserved_ptr1;
    const void* reserved_ptr2;
    const void* reserved_ptr3;

    lzma_vli number;

    lzma_vli block_count;

    lzma_vli compressed_offset;

    lzma_vli uncompressed_offset;

    lzma_vli compressed_size;

    lzma_vli uncompressed_size;

    lzma_vli padding;

    lzma_vli reserved_vli1;
    lzma_vli reserved_vli2;
    lzma_vli reserved_vli3;
    lzma_vli reserved_vli4;
}

struct lzma_index_iter_block
{
    lzma_vli number_in_file;

    lzma_vli compressed_file_offset;

    lzma_vli uncompressed_file_offset;

    lzma_vli number_in_stream;

    lzma_vli compressed_stream_offset;

    lzma_vli uncompressed_stream_offset;

    lzma_vli uncompressed_size;

    lzma_vli unpadded_size;

    lzma_vli total_size;

    lzma_vli reserved_vli1;
    lzma_vli reserved_vli2;
    lzma_vli reserved_vli3;
    lzma_vli reserved_vli4;

    const void* reserved_ptr1;
    const void* reserved_ptr2;
    const void* reserved_ptr3;
    const void* reserved_ptr4;
}

union lzma_index_iter_internal
{
    const void* p;
    size_t s;
    lzma_vli v;
}

struct lzma_index_iter
{
    lzma_index_iter_stream stream;
    lzma_index_iter_block block;
    lzma_index_iter_internal[6] internal;
}

enum lzma_index_iter_mode
{
    LZMA_INDEX_ITER_ANY = 0,

    LZMA_INDEX_ITER_STREAM = 1,

    LZMA_INDEX_ITER_BLOCK = 2,

    LZMA_INDEX_ITER_NONEMPTY_BLOCK = 3
}

extern (C) uint64_t lzma_index_memusage(
    lzma_vli streams, lzma_vli blocks) nothrow;

extern (C) uint64_t lzma_index_memused(const lzma_index* i)
nothrow;

extern (C) lzma_index* lzma_index_init(const lzma_allocator* allocator)
nothrow;

extern (C) void lzma_index_end(
    lzma_index* i, const lzma_allocator* allocator) nothrow;

extern (C) lzma_ret lzma_index_append(
    lzma_index* i, const lzma_allocator* allocator,
    lzma_vli unpadded_size, lzma_vli uncompressed_size)
nothrow;

extern (C) lzma_ret lzma_index_stream_flags(
    lzma_index* i, const lzma_stream_flags* stream_flags)
nothrow;

extern (C) uint32_t lzma_index_checks(const lzma_index* i)
nothrow pure;

extern (C) lzma_ret lzma_index_stream_padding(
    lzma_index* i, lzma_vli stream_padding)
nothrow;

extern (C) lzma_vli lzma_index_stream_count(const lzma_index* i)
nothrow pure;

extern (C) lzma_vli lzma_index_block_count(const lzma_index* i)
nothrow pure;

extern (C) lzma_vli lzma_index_size(const lzma_index* i)
nothrow pure;

extern (C) lzma_vli lzma_index_stream_size(const lzma_index* i)
nothrow pure;

extern (C) lzma_vli lzma_index_total_size(const lzma_index* i)
nothrow pure;

extern (C) lzma_vli lzma_index_file_size(const lzma_index* i)
nothrow pure;

extern (C) lzma_vli lzma_index_uncompressed_size(const lzma_index* i)
nothrow pure;

extern (C) void lzma_index_iter_init(
    lzma_index_iter* iter, const lzma_index* i) nothrow;

extern (C) void lzma_index_iter_rewind(lzma_index_iter* iter)
nothrow;

extern (C) lzma_bool lzma_index_iter_next(
    lzma_index_iter* iter, lzma_index_iter_mode mode)
nothrow;

extern (C) lzma_bool lzma_index_iter_locate(
    lzma_index_iter* iter, lzma_vli target) nothrow;

extern (C) lzma_ret lzma_index_cat(lzma_index* dest, lzma_index* src,
    const lzma_allocator* allocator)
nothrow;

extern (C) lzma_index* lzma_index_dup(
    const lzma_index* i, const lzma_allocator* allocator)
nothrow;

extern (C) lzma_ret lzma_index_encoder(
    lzma_stream* strm, const lzma_index* i)
nothrow;

extern (C) lzma_ret lzma_index_decoder(
    lzma_stream* strm, lzma_index** i, uint64_t memlimit)
nothrow;

extern (C) lzma_ret lzma_index_buffer_encode(const lzma_index* i,
    uint8_t* out_, size_t* out_pos, size_t out_size) nothrow;

extern (C) lzma_ret lzma_index_buffer_decode(lzma_index** i,
    uint64_t* memlimit, const lzma_allocator* allocator,
    const uint8_t* in_, size_t* in_pos, size_t in_size)
nothrow;

// lzma/index_hash.h

struct lzma_index_hash;

extern (C) lzma_index_hash* lzma_index_hash_init(
    lzma_index_hash* index_hash, const lzma_allocator* allocator)
nothrow;

extern (C) void lzma_index_hash_end(
    lzma_index_hash* index_hash, const lzma_allocator* allocator)
nothrow;

extern (C) lzma_ret lzma_index_hash_append(lzma_index_hash* index_hash,
    lzma_vli unpadded_size, lzma_vli uncompressed_size)
nothrow;

extern (C) lzma_ret lzma_index_hash_decode(lzma_index_hash* index_hash,
    const uint8_t* in_, size_t* in_pos, size_t in_size)
nothrow;

extern (C) lzma_vli lzma_index_hash_size(
    const lzma_index_hash* index_hash)
nothrow pure;

// lzma/hardware.h

extern (C) uint64_t lzma_physmem() nothrow;

extern (C) uint32_t lzma_cputhreads() nothrow;
