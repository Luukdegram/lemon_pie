//! Uses a mime database with useful methods
//! to construct mime types.
const MimeType = @This();
const std = @import("std");

const mime_database = @import("mime_db.zig").mime_database;

/// Textual representation of the mime type as content-type
text: []const u8,

/// Returns the content-type of a MimeType
pub fn toString(self: MimeType) []const u8 {
    return self.text;
}

/// Returns the extension that belongs to a MimeType
pub fn toExtension(self: MimeType) ?[]const u8 {
    for (mime_database) |mapping| {
        if (std.mem.eql(u8, mapping.mime_type, self.text)) {
            return mapping.mime_type;
        }
    }
    return null;
}

/// Returns the MimeType based on the extension
pub fn fromExtension(ext: []const u8) MimeType {
    for (mime_database) |mapping| {
        if (std.mem.eql(u8, mapping.extension, ext)) {
            return MimeType{ .text = mapping.mime_type };
        }
    }

    // Default to gemini's mime type as defined in section 5
    return MimeType{ .text = "text/gemini; charset=UTF-8" };
}

/// Returns the MimeType based on the file name
pub fn fromFileName(name: []const u8) MimeType {
    return fromExtension(std.fs.path.extension(name));
}

/// Format function that can be used inside print statements.
/// Will print the mimetype's string content, rather than a struct.
///
/// Discards the input format string and options.
pub fn format(self: MimeType, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try writer.print("{s}", .{self.text});
}
