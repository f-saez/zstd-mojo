
import sys.ffi
from memory.unsafe_pointer import UnsafePointer
from random import randint
from testing.testing import assert_true, assert_false, assert_equal

# size_t should be UInt but UInt is really incomplete right now, (June 2024)
# so I'll have to deal with Int
alias size_t = Int

alias ZSTD_versionNumber = fn() -> UInt32
alias ZSTD_compressBound = fn(size_t) -> size_t  
alias ZSTD_isError = fn(size_t) -> UInt32
alias ZSTD_getErrorName = fn(size_t) -> UnsafePointer[UInt8]
alias ZSTD_minCLevel = fn() -> Int32
alias ZSTD_maxCLevel = fn() -> Int32
alias ZSTD_defaultCLevel = fn() -> Int32 
alias ZSTD_compress = fn(UnsafePointer[UInt8], size_t, UnsafePointer[UInt8], size_t, Int32) -> size_t 
alias ZSTD_decompress = fn(UnsafePointer[UInt8], size_t, UnsafePointer[UInt8], size_t) -> size_t 
alias ZSTD_getFrameContentSize = fn(UnsafePointer[UInt8], size_t) -> UInt64 

alias LIBNAME = "libzstd.so"

@value
struct ZSTDVersion(Stringable):
    var major: UInt32
    var minor: UInt32
    var version: UInt32

    fn __init__(inout self, v : UInt32):
        self.major = v/(100*100)
        self.minor = (v/100) - (self.major*100)
        self.version = v - (self.major*100*100) - (self.minor*100)
    
    fn __str__(self) -> String:
        return String(self.major)+"."+String(self.minor)+"."+String(self.version)
    
@value
struct ZSTD:
    var _handle : ffi.DLHandle
    var _min_comp_level : Int32
    var _max_comp_level : Int32
    var _default_comp_level : Int32

    fn __init__(inout self, owned handle : ffi.DLHandle):
        self._handle = handle
        self._min_comp_level = self._handle.get_function[ZSTD_minCLevel]("ZSTD_minCLevel")()  # minimum negative compression level allowed, requires v1.4.0+
        self._max_comp_level = self._handle.get_function[ZSTD_maxCLevel]("ZSTD_maxCLevel")()
        self._default_comp_level = self._handle.get_function[ZSTD_defaultCLevel]("ZSTD_defaultCLevel")()

    @staticmethod
    fn new() -> Optional[Self]:
        var result = Optional[Self](None)
        var handle = ffi.DLHandle(LIBNAME, ffi.RTLD.NOW)
        if handle.__bool__():
            result = Optional[Self]( Self(handle) )
        else:
            print("Unable to load ",LIBNAME)
        return result

    fn version(self) -> ZSTDVersion:
        var num = self._handle.get_function[ZSTD_versionNumber]("ZSTD_versionNumber")()
        return ZSTDVersion(num)

    fn compress_bound(self, input_size : size_t) -> Int:
        """
        ZSTD_compressBound() :
            maximum compressed size in worst case single-pass scenario.
            When invoking `ZSTD_compress()` or any other one-pass compression function,
            it's recommended to provide @dstCapacity >= ZSTD_compressBound(srcSize)
            as it eliminates one potential failure scenario,
            aka not enough room in dst buffer to write the compressed frame.
            Note : ZSTD_compressBound() itself can fail, if @srcSize > ZSTD_MAX_INPUT_SIZE .
                In which case, ZSTD_compressBound() will return an error code
                which can be tested using ZSTD_isError().
        """
        return self._handle.get_function[ZSTD_compressBound]("ZSTD_compressBound")(input_size)
    
    fn is_error(self, e : size_t) -> Bool:
        return self._handle.get_function[ZSTD_isError]("ZSTD_isError")(e)
    
    fn get_error_name(self, e : Int) -> String:
        var result = String()
        var ptr = self._handle.get_function[ZSTD_getErrorName]("ZSTD_getErrorName")(e)
        var tmp:UInt64 = ptr
        if tmp!=0:  # is this a good way to detect null pointer ?
            var x = List[UInt8]()
            for offset in range(0,1024):  # I don't wanna loop too much. An error message is not supposed to be that long
                x.append(ptr[offset])  # zstd seems to be the owner of the allocated memory, so I'll copy the data to avoid a double-free error
                if ptr[offset]==0:
                    break
            result = String(x)
        return result
    
    @always_inline
    fn min_comp_level(self) -> Int32:
        """
        Min_comp_level():
            minimum negative compression level allowed, requires v1.4.0+.
        """
        return self._min_comp_level
    
    @always_inline
    fn max_comp_level(self) -> Int32:
        return self._max_comp_level
    
    @always_inline
    fn default_comp_level(self) -> Int32:
        return self._default_comp_level

    fn compress(self, dst : List[UInt8], src : List[UInt8], comp_level : Int32) -> Int:
        var cl:Int32
        if comp_level<self.min_comp_level():
            cl = self.min_comp_level()
        elif comp_level>self.max_comp_level():
            cl = self.max_comp_level()
        else:
            cl = comp_level    
        return self._handle.get_function[ZSTD_compress]("ZSTD_compress")(dst.unsafe_ptr(), dst.size, src.unsafe_ptr(), src.size, cl)

    @always_inline
    fn is_content_size_unknown(self, v : UInt64) -> Bool:
        return v==UInt64(-1)

    @always_inline
    fn is_content_size_error(self, v : UInt64) -> Bool:
        return v==UInt64(-2)
        
    fn get_frame_content_size(self, src : List[UInt8]) -> UInt64: 
        """
        ZSTD_getFrameContentSize():
            `src` should point to the start of a ZSTD encoded frame.
            @return : - decompressed size of `src` frame content, if known
                        - ZSTD_CONTENTSIZE_UNKNOWN if the size cannot be determined
                        - ZSTD_CONTENTSIZE_ERROR if an error occurred (e.g. invalid magic number, srcSize too small)
               note 1 : a 0 return value means the frame is valid but "empty".
               note 2 : decompressed size is an optional field, it may not be present, typically in streaming mode.
                        When `return==ZSTD_CONTENTSIZE_UNKNOWN`, data to decompress could be any size.
                        In which case, it's necessary to use streaming mode to decompress data.
                        Optionally, application can rely on some implicit limit,
                        as ZSTD_decompress() only needs an upper bound of decompressed size.
                        (For example, data could be necessarily cut into blocks <= 16 KB).
               note 3 : decompressed size is always present when compression is completed using single-pass functions,
                        such as ZSTD_compress(), ZSTD_compressCCtx() ZSTD_compress_usingDict() or ZSTD_compress_usingCDict().
               note 4 : decompressed size can be very large (64-bits value),
                        potentially larger than what local system can handle as a single memory segment.
                        In which case, it's necessary to use streaming mode to decompress data.
               note 5 : If source is untrusted, decompressed size could be wrong or intentionally modified.
                        Always ensure return value fits within application's authorized limits.
                        Each application can set its own limits.
        """
        # `srcSize` must be at least as large as the frame header and any size >= `ZSTD_frameHeaderSize_max` is large enough.
        #  ZSTD_frameHeaderSize_max==5, so 10 seems a good value
        return self._handle.get_function[ZSTD_getFrameContentSize]("ZSTD_getFrameContentSize")(src.unsafe_ptr(), 10)

    fn decompress(self, dst : List[UInt8], src : List[UInt8], src_size : Int) -> Int:
        return self._handle.get_function[ZSTD_decompress]("ZSTD_decompress")(dst.unsafe_ptr(), dst.size, src.unsafe_ptr(), src_size)

    @staticmethod
    fn validation() raises:
        """
          Yeah, I know. This should be in a file in test directory.
          I'll do that later.
        """
        fn compare_list(a : List[UInt8], b : List[UInt8]) raises -> Bool:
            assert_true(a.size==b.size,"size error")
            for idx in range(0,a.size):
                assert_true(a[idx]==b[idx],"value error")
            return True

        var original = List[UInt8]()
        original.resize(16384,0)
        var aaa = ZSTD.new()
        assert_true(aaa)
        var zstd = aaa.take()
        var recommended_size = zstd.compress_bound(original.size)
        assert_true(recommended_size>original.size,"error while calling compress_bound")

        var compressed = List[UInt8]()
        var uncompress = List[UInt8]()

        # first shot, best case : an easy to compressed file
        compressed.resize(recommended_size,0)
        var result = zstd.compress(compressed, original, zstd.max_comp_level())
        assert_false(zstd.is_error(result),"error while compressing")
        assert_equal(zstd.get_error_name(result),"No error detected")
        # the compressed size must be smaller than the original size
        assert_true(result<original.size,"error while compressing")
        
        # we could resize compress with .resize(result)
        # but we're gonna use it as a dumb buffer
        var tmp = zstd.get_frame_content_size(compressed)
        assert_true(tmp==original.size,"error while compressing or getting frame content size")
       
        uncompress.resize( int(tmp), 0)
        result = zstd.decompress(uncompress, compressed, result)
        assert_false(zstd.is_error(result),"error while decompressing")
        assert_equal(zstd.get_error_name(result),"No error detected")
        assert_true(compare_list(original,uncompress),"result is not the same as source")

        # second shot, worst case : just noise
        var p = DTypePointer[DType.uint8](original.unsafe_ptr())
        randint[DType.uint8](p, original.size, 0, 255)
        # a compressed file is usually smaller than the original, but we are compressing pure noise
        # so we should expect a bigger file, but not biggeer than the recommended size
        result = zstd.compress(compressed, original, zstd.max_comp_level())
        assert_false(zstd.is_error(result),"error while compressing")
        assert_equal(zstd.get_error_name(result),"No error detected")
        assert_true(result>=original.size,"error while compressing")
        
        # once again
        tmp = zstd.get_frame_content_size(compressed)
        assert_true(tmp==original.size,"error while compressing or getting frame content size")
        result = zstd.decompress(uncompress, compressed, result)
        assert_false(zstd.is_error(result),"error while decompressing")
        assert_equal(zstd.get_error_name(result),"No error detected")
        assert_true(compare_list(original,uncompress),"result is not the same as source")
                      
        # to make things go wrong
        uncompress.resize( 1, 0)
        result = zstd.decompress(uncompress, compressed, result)
        assert_true(zstd.is_error(result),"error while decompressing")
        assert_equal(zstd.get_error_name(result),"Src size is incorrect")


fn main() raises:
   ZSTD.validation()
    


    
