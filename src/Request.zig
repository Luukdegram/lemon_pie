//! Request represents the data received by the client.
//! Whenever the client connects to the server, we parse and verify
//! the request. The Request and its data is available to the user of the library
//! by passing it from the server to the handler.
const Request = @This();
const std = @import("std");
const url = @import("url.zig");

/// Parsed URL from the client's request.
url: url.Url,

/// Parses a request, validates it and then returns a `Request` instance
pub fn parse(reader: anytype, buffer: []u8) Parser(@TypeOf(reader)).Error!Request {
    var parser = Parser(@TypeOf(reader)).init(reader, buffer);
    return parser.parseAndValidate();
}

/// All error cases which can be hit when validating
/// a Gemini request.
pub const ParserError = error{
    /// Request is invalid, the first line does not end with \r\n
    MissingCRLF,
    /// The URL has a maximum length of 1024 bytes, including its scheme.
    URLTooLong,
};

/// Constructs a generic `Parser` for a given `ReaderType`.
fn Parser(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        reader: ReaderType,
        buffer: []u8,
        index: usize,

        const Error = ReaderType.Error || ParserError;

        /// Initializes a new `Parser` with a reader of type `ReaderType`
        fn init(reader: ReaderType, buffer: []u8) Self {
            return .{ .reader = reader, .buffer = buffer, .index = 0 };
        }

        /// Parses the request and validates it
        fn parseAndValidate(self: *Self) Error!Request {
            const request_line = try self.reader.readUntilDelimiterOrEoF(self.buffer, '\n');
            if (request_line.len < 3) return error.MissingCRLF;

            // verify CRLF
            if (!std.mem.eql(u8, request_line[request_line.len - 2 ..], "\r\n")) {
                return error.MissingCRLF;
            }

            const url_len = request_line.len - 2;

            // URL's have a maximum length of 1024 bytes including its scheme
            if (request_line.len > 1026) {
                return error.URLTooLong;
            }

            return Request{ .url = try url.parse(self.buffer[0..url_len]) };
        }
    };
}
