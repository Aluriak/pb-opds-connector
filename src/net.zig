const std = @import("std");
const curl = @cImport({
    @cInclude("curl/curl.h");
});

const DOWNLOAD_DIR = "/mnt/ext1/Downloads/";

fn curlWriteFile(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) callconv(.C) usize {
    return std.c.fwrite(ptr, size, nmemb, @ptrCast(stream));
}

pub fn download(url: []const u8) !void {
    const uri = try std.Uri.parse(url);
    const last_slash_idx = std.mem.lastIndexOfScalar(u8, uri, '/') orelse return error.InvalidUrlFormat;
    const origFilename = url[last_slash_idx + 1 ..];

    if (origFilename.len == 0) {
        return error.CouldNotExtractFilename;
    }

    var pathBuf: [384]u8 = undefined;
    const targetPath = try std.fmt.bufPrintZ(&pathbuf, "{s}{s}", .{ DOWNLOAD_DIR, origFilename });

    const fh = std.c.fopen(targetPath.ptr, "wb") orelse return error.CannotOpenFileForWriting;
    defer _ = std.c.fclose(fh);

    const cUrl = try allocator.dupeZ(u8, url);
    defer allocator.free(cUrl);

    const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, cUrl.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteFile);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, fh);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT, @as(c_long, 60));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) {
        return error.DownloadFailed;
    }
}
