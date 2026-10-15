//! Bindings for the few libcurl symbols we use, so no curl headers are needed.
//! The option numbers are part of libcurl's stable ABI (see curl/curl.h).
pub const CURL = opaque {};
pub const CURLE_OK: c_int = 0;
pub const CURLAUTH_BASIC: c_long = 1;
pub const CURLAUTH_ANY: c_long = ~@as(c_long, 0x10);
pub const CURLOPT_TIMEOUT: c_int = 13;
pub const CURLOPT_VERBOSE: c_int = 41;
pub const CURLOPT_NOPROGRESS: c_int = 43;
pub const CURLOPT_FAILONERROR: c_int = 45;
pub const CURLOPT_FOLLOWLOCATION: c_int = 52;
pub const CURLOPT_CONNECTTIMEOUT: c_int = 78;
pub const CURLOPT_HTTPAUTH: c_int = 107;
pub const CURLOPT_WRITEDATA: c_int = 10001;
pub const CURLOPT_ERRORBUFFER: c_int = 10010;
pub const CURLOPT_URL: c_int = 10002;
pub const CURLOPT_USERPWD: c_int = 10005;
pub const CURLOPT_USERAGENT: c_int = 10018;
pub const CURLOPT_WRITEFUNCTION: c_int = 20011;
pub const CURLOPT_XFERINFOFUNCTION: c_int = 20219;
pub const CURLINFO_RESPONSE_CODE: c_int = 0x200002;
/// The size curl expects for CURLOPT_ERRORBUFFER
pub const CURL_ERROR_SIZE = 256;

pub extern fn curl_easy_init() ?*CURL;
pub extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) c_int;
pub extern fn curl_easy_perform(handle: *CURL) c_int;
pub extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) c_int;
pub extern fn curl_easy_cleanup(handle: *CURL) void;
