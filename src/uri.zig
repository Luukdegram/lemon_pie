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

pub const ParseError = error{
    /// Gemini URI's have a maximum length of 1024 bytes.
    UriTooLong,
    /// Misses the 'gemini://' scheme
    MissingScheme,
    /// URI is missing the host component
    MissingHost,
    /// The port was included but could not be parsed
    InvalidPort,
    /// Expected a specific character, but instead found a different one
    InvalidCharacter,
    /// Host contains an IP-literal, but is missing a closing ']'
    MissingClosingBracket,
    /// The port number does not fit within the type (u16).
    Overflow,
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
        // when we finished a component,
        // use this to detect what to parse next.
        detect_next,
    };

    var state: State = .scheme;
    var index: usize = 0;
    while (index < input.len) {
        const char = input[index];
        switch (state) {
            .scheme => switch (char) {
                'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => index += 1,
                ':' => {
                    uri.scheme = input[0..index];
                    state = .host;

                    // read until after '://'
                    index += try expectCharacters(input[index..], "://");
                },
                else => return error.InvalidCharacter, // expected ':' but found a different character
            },
            .host => switch (char) {
                '[' => {
                    index += 1;
                    const start = index;

                    for (input[index..]) |cur, idx| {
                        if (cur == ']') {
                            uri.host = input[start .. start + idx];
                            break;
                        }
                    } else return error.MissingClosingBracket;
                    index += uri.host.len + 1;
                },
                else => if (isRegName(char)) {
                    const start = index;
                    while (index < input.len and isRegName(input[index])) {
                        index += 1;
                    } else {
                        uri.host = input[start..index];
                    }
                    state = .detect_next;
                } else {
                    state = .detect_next;
                },
            },
            .detect_next => switch (char) {
                ':', '/', '?', '#' => |cur| {
                    index += 1;
                    state = switch (cur) {
                        '/' => .path,
                        '?' => .query,
                        '#' => .fragment,
                        ':' => .port,
                        else => unreachable,
                    };
                },
                else => return error.InvalidCharacter,
            },
            .port => {
                const start = index;
                while (index < input.len and std.ascii.isDigit(input[index])) {
                    index += 1;
                } else {
                    uri.port = try std.fmt.parseInt(u16, input[start..index], 10);
                }
                state = .detect_next;
            },
            .path => {
                const start = index;
                const end = if (std.mem.indexOfAnyPos(u8, input, index, "?#")) |pos| blk: {
                    state = switch (input[pos]) {
                        '#' => .fragment,
                        '?' => .query,
                        else => unreachable,
                    };
                    break :blk pos;
                } else input.len;

                uri.path = input[start..end];
                index = end;
            },
            .query => {
                const start = if (char == '?') index + 1 else index;
                const end = if (std.mem.indexOfScalarPos(u8, input, start, '#')) |frag| blk: {
                    state = .fragment;
                    break :blk frag;
                } else input.len;
                uri.query = input[start..end];
                index = end;
            },
            .fragment => {
                const start = if (char == '#') index + 1 else index;
                uri.fragment = input[start..input.len];
                break;
            },
        }
    }
    return uri;
}

/// Reads over the given slice `buffer` until it reaches the given `delimiters` slice.
/// Returns the length it read until found.
fn expectCharacters(buffer: []const u8, delimiters: []const u8) !usize {
    if (!std.mem.startsWith(u8, buffer, delimiters)) return error.InvalidCharacter;
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
    return std.ascii.isAlpha(char) or std.ascii.isDigit(char) or switch (char) {
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

/// Returns true when given char is pchar
/// unreserved / pct-encoded / sub-delims / ":" / "@"
fn isPChar(char: u8) bool {
    return switch (char) {
        '%', ':', '@' => true,
        else => isUnreserved(char) or isSubDelim(char),
    };
}

test "Scheme" {
    const cases = .{
        .{ "https://", "https" },
        .{ "gemini://", "gemini" },
        .{ "git://", "git" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.scheme);
    }

    const error_cases = .{
        "htt?s", "gem||", "ha$",
    };

    inline for (error_cases) |case| {
        try std.testing.expectError(ParseError.InvalidCharacter, parse(case));
    }
}

test "Host" {
    const cases = .{
        .{ "https://exa2ple", "exa2ple" },
        .{ "gemini://example.com", "example.com" },
        .{ "git://sub.domain.com", "sub.domain.com" },
        .{ "https://[2001:db8:0:0:0:0:2:1]", "2001:db8:0:0:0:0:2:1" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.host);
    }

    const error_cases = .{
        "https://exam|", "gemini://exa\"", "git://sub.example.[om",
    };

    inline for (error_cases) |case| {
        try std.testing.expectError(ParseError.InvalidCharacter, parse(case));
    }
}

test "Port" {
    const cases = .{
        .{ "gemini://example.com:100", 100 },
        .{ "gemini://example.com:8080", 8080 },
        .{ "gemini://example.com:8080/", 8080 },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqual(@as(u16, case[1]), uri.port.?);
    }

    const error_cases = .{
        "https://exammple.com:10a", "https://example.com:[",
    };

    inline for (error_cases) |case| {
        try std.testing.expectError(error.InvalidCharacter, parse(case));
    }
}

test "Path" {
    const cases = .{
        .{ "gemini://example.com:100/hello", "hello" },
        .{ "gemini://example.com/hello/world", "hello/world" },
        .{ "gemini://example.com/../hello", "../hello" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.path.?);
    }
}

test "Query" {
    const cases = .{
        .{ "gemini://example.com:100/hello?", "" },
        .{ "gemini://example.com/?cool=true", "cool=true" },
        .{ "gemini://example.com?hello=world", "hello=world" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.query.?);
    }
}

test "Fragment" {
    const cases = .{
        .{ "gemini://example.com:100/hello?#hi", "hi" },
        .{ "gemini://example.com/#hello", "hello" },
        .{ "gemini://example.com#hello-world", "hello-world" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.fragment.?);
    }
}
