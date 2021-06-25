//! Implements RFC3986's generic syntax
//! https://datatracker.ietf.org/doc/html/rfc3986
//! NOTE: This includes changes according to the Gemini protocol
//! section 1.2.
//! https://gemini.circumlunar.space/docs/specification.html

const std = @import("std");

pub const Uri = struct {
    /// Scheme component of the URI. i.e gemini://
    scheme: []const u8,
    /// Host component, i.e. http://<host>
    host: []const u8,
    /// Optional port component, i.e. http://<host>:[port]
    port: ?u16,
    /// Path component of the URI, i.e. gemini://<host>[:port][/path]
    path: ?[]const u8,
    /// Query component of an URI, i.e. <host>[path]?[query]
    query: ?[]const u8,
    /// Fragment identifier component, which allows for indirect identification of
    /// a secondary resource
    fragment: ?[]const u8,
};

pub const ParseError = struct {
    /// Gemini URI's have a maximum length of 1024 bytes.
    UriTooLong,
    /// Misses the 'gemini://' scheme
    MissingScheme,
    /// URI is missing the host component
    MissingHost,
    /// The port was included but could not be parsed
    InvalidPort,
    /// Expected a specific character, but instead found a different one
    UnexpectedCharacter,
    /// Host contains an IP-literal, but is missing a closing ']'
    MissingClosingBracket,
};

/// Parses a given slice `input` into a Gemini compliant URI.
/// Produces a `ParseError` when the given input is invalid.
pub fn parse(input: []const u8) ParseError!Uri {
    if (input.len == 0) return error.MissingScheme;

    var uri: Uri = .{
        .scheme = undefined,
        .host = undefined,
        .port = null,
        .path = null,
        .query = null,
        .fragment = null,
    };

    const State = enum {
        scheme,
        host,
        port,
        path,
        query,
        fragment,
    };

    var state: State = .scheme;
    var index: usize = 0;
    while (index < input.len) {
        const char = input[index];
        switch (state) {
            .scheme => switch (char) {
                'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => index += 1,
                else => |cur| {
                    if (cur != ':') return error.UnexpectedCharacter; // expected ':' but found a different character
                    uri.scheme = input[0..index];
                    state = .host;

                    // read until after '://'
                    index += try expectCharacters(input[index..], "://");
                },
            },
            .host => switch (char) {
                '[' => {
                    const start = index + 1;

                    for (input[index..]) |cur, idx| {
                        if (cur == ']') {
                            uri.host = input[start .. start + idx];
                            break;
                        }
                    } else return error.MissingClosingBracket;
                    index += uri.host.len;
                },
                else => if (isRegName(char)) {
                    const start = index;
                    while (isRegName(input[index])) {
                        index += 1;
                    } else {
                        uri.host = input[start..index];
                    }
                } else switch (char) {
                    // port is present
                    ':' => {
                        index += 1;
                        const start = index;
                        while (std.ascii.isDigit(input[index])) {
                            index += 1;
                        } else {
                            uri.port = try std.fmt.parseInt(input[start..index], 10);
                        }
                    },
                    '/', '?', '#' => |cur| {
                        index += 1;
                        state = switch (cur) {
                            '/' => .path,
                            '?' => .query,
                            '#' => .fragment,
                            else => unreachable,
                        };
                    },
                    else => return error.UnexpectedCharacter, // expected authority separator
                },
            },
            .path => {},
            .query => {},
            .fragment => {},
        }
    }
}

/// Reads over the given slice `buffer` until it reaches the given `delimiters` slice.
/// Returns the length it read until found.
fn expectCharacters(buffer: []const u8, delimiters: []const u8) !usize {
    if (buffer.len < delimiters.len) return error.UnexpectedCharacter;

    if (!std.mem.startsWith(u8, buffer, delimiters)) return error.UnexpectedCharacter;
    return delimiters.len;
}

/// Returns true when Reg-name
/// *( unreserved / %<HEX> / sub-delims )
fn isRegName(char: u8) bool {
    return isUnreserved(char) or char == '%' or isSubDelim(char);
}

/// Checks if unreserved character
/// ALPHA / DIGIT/ [ "-" / "." / "_" / "~" ]
fn isUnreserved(char: u8) bool {
    return std.ascii.isAlpha or std.ascii.isDigit or switch (char) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Returns true when character is a sub-delim character
/// !, $, &, \, (, ), *, *, +, ',', =
fn isSubDelim(char: u8) bool {
    return switch (char) {
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        '=',
        => true,
        else => false,
    };
}
