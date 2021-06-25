//! Request represents the data received by the client.
//! Whenever the client connects to the server, we parse and verify
//! the request. The Request and its data is available to the user of the library
//! by passing it from the server to the handler.
const Request = @This();
const std = @import("std");
const uri = @import("uri.zig");

/// Parsed URL from the client's request.
uri: uri.Uri,

/// Parses a request, validates it and then returns a `Request` instance
pub fn parse(reader: anytype, buffer: []u8) Parser(@TypeOf(reader)).Error!Request {
    var parser = Parser(@TypeOf(reader)).init(reader, buffer);
    return parser.parseAndValidate();
}

/// All error cases which can be hit when validating
/// a Gemini request.
pub const ParseError = error{
    /// Request is invalid, the first line does not end with \r\n.
    MissingCRLF,
    /// Request is missing mandatory URI.
    MissingUri,
    /// The URI has a maximum length of 1024 bytes, including its scheme.
    UriTooLong,
    /// When the provided buffer is smaller than 1024 bytes.
    BufferTooSmall,
    /// Connection was closed by the client.
    EndOfStream,
} || uri.ParseError;

/// Constructs a generic `Parser` for a given `ReaderType`.
fn Parser(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        reader: ReaderType,
        buffer: []u8,
        index: usize,

        const Error = ReaderType.Error || ParseError;

        /// Initializes a new `Parser` with a reader of type `ReaderType`
        fn init(reader: ReaderType, buffer: []u8) Self {
            return .{ .reader = reader, .buffer = buffer, .index = 0 };
        }

        /// Parses the request and validates it
        fn parseAndValidate(self: *Self) Error!Request {
            if (self.buffer.len < 1024) return error.BufferTooSmall;
            const read = try self.reader.read(self.buffer);
            if (read == 0) return error.EndOfStream;
            if (read == 2) return error.MissingUri;

            // URI's have a maximum length of 1024 bytes including its scheme
            if (read > 1026) {
                return error.UriTooLong;
            }

            // verify CRLF
            if (!std.mem.eql(u8, self.buffer[read - 2 ..], "\r\n")) {
                return error.MissingCRLF;
            }

            return Request{ .uri = try uri.parse(self.buffer[0 .. read - 2]) };
        }
    };
}

test "Happy flow" {
    const valid = "gemini://example.com/hello-world\r\n";
    var buf: [1024]u8 = undefined;
    _ = try parse(std.io.fixedBufferStream(valid).reader(), &buf);
}

test "Unhappy flow" {
    const error_cases = .{
        .{ "gemini://example.com", error.MissingCRLF },
        .{ &[_]u8{0} ** 1027, error.UriTooLong },
        .{ "\r\n", error.MissingUri },
        .{ "", error.EndOfStream },
    };

    inline for (error_cases) |case| {
        var buf: [1028]u8 = undefined;
        try std.testing.expectError(
            case[1],
            parse(std.io.fixedBufferStream(case[0]).reader(), &buf),
        );
    }

    var buf: [1]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        parse(std.io.fixedBufferStream("test").reader(), &buf),
    );
}
