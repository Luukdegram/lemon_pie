//! Represents a response message to the client.
//! A response header consists of <STATUS><SPACE><META><CR><LF>
//! The response header has a a max length, therefore
//! we can utilize buffers for optimal speed as we do not
//! require any allocators.
//! The body however may require an allocator depending on the
//! use case of the user.
const Response = @This();

const std = @import("std");
const net = std.net;
const MimeType = @import("MimeType.zig");

/// The status representing this response.
/// By default set to "SUCCESS - 20"
status: Status = .success,
/// Buffered writer for writing to the client.
/// By buffering we limit the amount of syscalls and improve
/// the performance.
buffered_writer: std.io.BufferedWriter(4096, net.Stream.Writer),
/// Determines if the response has been flushed or not
/// This prevents double writes to the client.
is_flushed: bool = false,
/// A writer for writing to the response body.
/// All content is flushed at once.
body: std.ArrayList(u8).Writer,

/// Possible errors when sending a response
/// to the client. (This excludes writing to `body`)
pub const Error = net.Stream.WriteError;

/// The maximum amount of bytes a header will entail
/// <STATUS><SPACE><META><CR><LF>
pub const max_header_size: usize = 2 + 1 + 1024 + 1 + 1;

/// Represents a status code.
/// As the spec is not final, this is a non-exhaustive enum,
/// allowing up to 2^6-1 values.
pub const Status = enum(u6) {
    /// Ask the client to send a new request with input as query parameters
    input = 10,
    /// Like `input` but for sensitive input such as passwords.
    sensitive_input = 11,
    /// Success, provides a response body to the client with plain text/binary data.
    success = 20,
    /// Temporary redirect. Client may attempt to retry the same URI at a later point.
    redirect_temporary = 30,
    /// Permanently redirected. The client should use the URI provided in the header's META.
    redirect_permanent = 31,
    /// Temporary failure, client may attempt to retry at a later point.
    temporary_failure = 40,
    /// Server is currently unavailable for maintence, etc.
    server_unavailable = 41,
    /// A CGI process or similar system died unexpectedly or timed out.
    cgi_error = 42,
    /// A proxy request failed because the server was unable to complete a transaction with the remote host.
    proxy_error = 43,
    /// Rate limiting is in effect. META must contain an integer representing the number of seconds the client must wait.
    slow_down = 44,
    /// Permanent failure. Client must not attempt to reconnect to this URI.
    permanent_failure = 50,
    /// The provided URI represents an unknown source. Much like HTTP's 404 code.
    not_found = 51,
    /// The requested resource is no longer available. Clients must no longer connect with this resource.
    gone = 52,
    /// The request was for a resource at a domain not served by the server and the server
    /// does not accept proxy requests.
    proxy_request_refused = 53,
    /// The server was unable to parse the client's request. Presumably due to a malformed request.
    bad_request = 59,
    /// Client was unable to provide a certificate.
    client_certificate_required = 60,
    /// The provided certificate is not authorised for this server.
    certificate_not_authorised = 61,
    /// The provided certificate is invalid.
    certificate_not_valid = 62,
    _,

    /// Returns the integer value representing the `Status`
    pub fn int(self: Status) u6 {
        return @enumToInt(self);
    }
};

/// Sends a response to the client with only a header and an empty body.
/// The response will be written instantly and is_flushed will be set to `true`.
/// Any writes after are illegal.
pub fn writeHeader(self: *Response, status: Status, meta: []const u8) Error!void {
    std.debug.assert(meta.len <= 1024); // max META size is 1024 bytes
    std.debug.assert(status != .success); // success status code requires a body

    try self.buffered_writer.writer().print("{d} {s}\r\n", .{ status.int(), meta });
    try self.buffered_writer.flush();
    self.is_flushed = true; // only on succesful writes
}

/// Flushes and writes the entire contents of `body` to the client.
/// It is valid to call this by the user. However, it is illegal
/// to call this more than once during a request.
///
/// It can provide benefits to call this instead of relying on the server, as
/// work can be done by the user within the same request handle after calling flush,
/// such as writing to a log, database or cleaning up data.
///
/// This also allows the user to provide a specific mime type for the content.
pub fn flush(self: *Response, mime_type: MimeType) Error!void {
    std.debug.assert(!self.is_flushed); // it is illegal to call `flush` more than once.
    std.debug.assert(self.buffered_writer.fifo.count == 0); // It's illegal to use both the writer and `flush`.

    self.buffered_writer.writer().print("{d} {s}\r\n", .{ status.int(), mime_type });

    // write the contents of the body
    if (self.body.context.items.len != 0) {
        try self.buffered_writer.writer().writeAll(self.body.context.items);
    }

    // ensure all bytes are sent
    try self.buffered_writer.flush();
    // only on succesful write do we set `is_flushed`
    self.is_flushed = true;
}
