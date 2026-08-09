const std = @import("std");

/// template fill-point mechanism.
///
/// a template (clash yaml / singbox json) declares fill points as single-line
/// empty lists:
///   proxies: []          (clash)
///   "outbounds": []      (singbox)
/// the renderer replaces the empty list with the generated node block,
/// matching the template's indent style. the rest of the template is kept
/// byte-for-byte.

/// detect the template's indent style: leading whitespace of the first
/// indented line (e.g. "  ", "    ", "\t"). falls back to two spaces.
pub fn detectIndent(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i > 0 and i < line.len) return line[0..i];
    }
    return "  ";
}

/// a template line has the key when: [ws]* key ':' (any position in the line).
fn matchKeyLine(line: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (!std.mem.startsWith(u8, line[i..], key)) return false;
    i += key.len;
    return i < line.len and line[i] == ':';
}

/// a template line matches when: [ws]* key ':' [ws]* '[]' [',']? [ws]* $ (single line).
fn matchFillLine(line: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (!std.mem.startsWith(u8, line[i..], key)) return false;
    i += key.len;
    if (i >= line.len or line[i] != ':') return false;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (!std.mem.startsWith(u8, line[i..], "[]")) return false;
    i += 2;
    if (i < line.len and line[i] == ',') i += 1; // json object: trailing comma
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i == line.len;
}

pub const FillError = error{ MissingFillPoint, NonEmptyList };

/// replace the single-line empty list of `key` with `block`.
///
/// `block` is the complete list body with relative indent (first level at
/// column 0): for yaml "- name: x\n  server: y", for json "[\n  {...},\n  {...}\n]"
/// (open/close brackets included). each block line is prefixed with the fill
/// line's indent + one indent unit, so nested levels align with the template.
/// anything after the "[]" on the fill line (e.g. a json trailing comma) is kept.
///
/// errors: key not found (MissingFillPoint), or the list is not empty (NonEmptyList).
pub fn fillList(
    arena: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
    block: []const u8,
) ![]const u8 {
    const unit = detectIndent(text);
    // trim trailing newlines so split does not yield a phantom empty line
    const src = std.mem.trimRight(u8, text, "\n");

    // pass 1: locate the outermost key line (smallest indent); nested keys
    // with the same name (e.g. a clash group's inner `proxies:`) are ignored.
    var target: ?[]const u8 = null;
    var target_indent: usize = std.math.maxInt(usize);
    {
        var scan = std.mem.splitScalar(u8, src, '\n');
        while (scan.next()) |line| {
            if (matchKeyLine(line, key)) {
                var li: usize = 0;
                while (li < line.len and (line[li] == ' ' or line[li] == '\t')) : (li += 1) {}
                if (li < target_indent) {
                    target_indent = li;
                    target = line;
                }
            }
        }
    }
    const tline = target orelse return error.MissingFillPoint;
    if (!matchFillLine(tline, key)) return error.NonEmptyList;

    // pass 2: rebuild, replacing the target line
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var replaced = false;
    while (lines.next()) |line| {
        if (!replaced and std.mem.eql(u8, line, tline)) {
            replaced = true;
            // locate the "[]" inside this line: key ':' [ws] "["
            var li: usize = 0;
            while (li < line.len and (line[li] == ' ' or line[li] == '\t')) : (li += 1) {}
            const key_end = li + key.len + 1; // key + ':'
            var bi = key_end;
            while (bi < line.len and (line[bi] == ' ' or line[bi] == '\t')) : (bi += 1) {}
            // key line head (indent + key + ':'), then the block on following lines
            try out.appendSlice(arena, line[0..key_end]);
            try out.append(arena, '\n');
            // block lines: prefix = line indent + one unit
            const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ line[0..li], unit });
            var bit = std.mem.splitScalar(u8, block, '\n');
            while (bit.next()) |bl| {
                if (bl.len == 0) continue; // skip trailing newline artifact
                try out.appendSlice(arena, prefix);
                try out.appendSlice(arena, bl);
                try out.append(arena, '\n');
            }
            // keep whatever followed the "[]" on the original line (e.g. json comma)
            const tail = line[bi + 2 ..];
            if (tail.len > 0) {
                try out.appendSlice(arena, tail);
                try out.append(arena, '\n');
            }
        } else {
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// fill-point state of `key` in the template: empty single-line list,
/// non-empty (user content to keep), or missing.
pub const FillState = enum { empty, non_empty, missing };

pub fn fillState(text: []const u8, key: []const u8) FillState {
    // outermost key line wins (nested same-name keys ignored)
    var target: ?[]const u8 = null;
    var target_indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (matchKeyLine(line, key)) {
            var li: usize = 0;
            while (li < line.len and (line[li] == ' ' or line[li] == '\t')) : (li += 1) {}
            if (li < target_indent) {
                target_indent = li;
                target = line;
            }
        }
    }
    const t = target orelse return .missing;
    return if (matchFillLine(t, key)) .empty else .non_empty;
}

/// reserved anchor name: a `- <anchor>` line inside user-defined clash proxy-groups
/// is expanded to the real node-name list (macro-style). node names are
/// "sub@node" so this can never collide with a real node.
pub const nodes_anchor = "__NODES__";

/// a line matches when: [ws]* "- " anchor [ws]* $.
fn matchAnchorLine(line: []const u8, anchor: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (!std.mem.startsWith(u8, line[i..], "- ")) return false;
    i += 2;
    if (!std.mem.startsWith(u8, line[i..], anchor)) return false;
    i += anchor.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i == line.len;
}

/// expand every `- <anchor>` line into `block` (one item per line, indented like
/// the anchor line). non-matching lines are kept as-is; text is returned
/// unchanged when no anchor line is present (no error: absence is explicit).
/// an anchor that appears anywhere else (inline, comment, etc.) is an error:
/// the anchor is a reserved word and must be a standalone list item.
pub fn expandAnchor(
    arena: std.mem.Allocator,
    text: []const u8,
    anchor: []const u8,
    block: []const u8,
) ![]const u8 {
    const src = std.mem.trimRight(u8, text, "\n");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (matchAnchorLine(line, anchor)) {
            var li: usize = 0;
            while (li < line.len and (line[li] == ' ' or line[li] == '\t')) : (li += 1) {}
            const indent = line[0..li];
            var bit = std.mem.splitScalar(u8, block, '\n');
            while (bit.next()) |bl| {
                if (bl.len == 0) continue;
                try out.appendSlice(arena, indent);
                try out.appendSlice(arena, bl);
                try out.append(arena, '\n');
            }
        } else if (std.mem.indexOf(u8, line, anchor) != null) {
            return error.MisplacedAnchor;
        } else {
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// append a top-level block to the template text: "key:\n" + block (relative indent).
pub fn appendBlock(
    arena: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
    block: []const u8,
) ![]const u8 {
    const unit = detectIndent(text);
    var out = std.ArrayListUnmanaged(u8).empty;
    try out.appendSlice(arena, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(arena, '\n');
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, ":\n");
    var bit = std.mem.splitScalar(u8, block, '\n');
    while (bit.next()) |bl| {
        if (bl.len == 0) continue; // skip trailing newline artifact
        try out.appendSlice(arena, unit);
        try out.appendSlice(arena, bl);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

// ---------------- tests ----------------

test "detectIndent" {
    try std.testing.expectEqualStrings("  ", detectIndent("a: 1\n  b: 2\n"));
    try std.testing.expectEqualStrings("    ", detectIndent("a: 1\n    b: 2\n"));
    try std.testing.expectEqualStrings("\t", detectIndent("a: 1\n\tb: 2\n"));
    try std.testing.expectEqualStrings("  ", detectIndent("no indent here\n"));
}

test "fillList basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tpl = "mixed-port: 7890\nproxies: []\nrules:\n- MATCH,PROXY\n";
    const out = try fillList(a, tpl, "proxies", "- name: x\n  server: y\n");
    try std.testing.expectEqualStrings(
        "mixed-port: 7890\nproxies:\n  - name: x\n    server: y\nrules:\n- MATCH,PROXY\n",
        out,
    );
}

test "fillList respects template indent style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 4-space template: indent unit is 4 (first indented line), fill prefix = 4 + 4
    const tpl = "mixed-port: 7890\n    proxies: []\n";
    const out = try fillList(a, tpl, "proxies", "- name: x\n  server: y\n");
    try std.testing.expectEqualStrings("mixed-port: 7890\n    proxies:\n        - name: x\n          server: y\n", out);
}

test "fillList json key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tpl = "{\n  \"log\": {},\n  \"outbounds\": []\n}\n";
    const out = try fillList(a, tpl, "\"outbounds\"", "[\n  {\n    \"a\": 1\n  },\n  {\n    \"b\": 2\n  }\n]\n");
    try std.testing.expectEqualStrings(
        "{\n  \"log\": {},\n  \"outbounds\":\n    [\n      {\n        \"a\": 1\n      },\n      {\n        \"b\": 2\n      }\n    ]\n}\n",
        out,
    );
}

test "fillList errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // missing key
    try std.testing.expectError(error.MissingFillPoint, fillList(a, "a: 1\n", "proxies", "- x"));
    // key exists but non-empty (single-line)
    try std.testing.expectError(error.NonEmptyList, fillList(a, "proxies: [1, 2]\n", "proxies", "- y"));
    // key exists but non-empty (multi-line)
    try std.testing.expectError(error.NonEmptyList, fillList(a, "proxies:\n  - name: x\n", "proxies", "- y"));
}

test "fillState and appendBlock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(FillState.empty, fillState("proxies: []\n", "proxies"));
    try std.testing.expectEqual(FillState.non_empty, fillState("proxies:\n  - x\n", "proxies"));
    try std.testing.expectEqual(FillState.non_empty, fillState("proxies: [1, 2]\n", "proxies"));
    try std.testing.expectEqual(FillState.missing, fillState("other: []\n", "proxies"));

    const out = try appendBlock(a, "a: 1\n", "proxy-groups", "- name: PROXY\n  type: select\n");
    try std.testing.expectEqualStrings("a: 1\nproxy-groups:\n  - name: PROXY\n    type: select\n", out);
}

test "expandAnchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tpl = "proxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - AUTO\n      - __NODES__\n  - name: AUTO\n    proxies:\n      - __NODES__\n      - DIRECT\n";
    const out = try expandAnchor(a, tpl, nodes_anchor, "- n1\n- n2\n");
    try std.testing.expectEqualStrings(
        "proxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - AUTO\n      - n1\n      - n2\n  - name: AUTO\n    proxies:\n      - n1\n      - n2\n      - DIRECT\n",
        out,
    );
    // no anchor: unchanged
    const plain = try expandAnchor(a, "a: 1\n- x\n", nodes_anchor, "- n1\n");
    try std.testing.expectEqualStrings("a: 1\n- x\n", plain);
    // inline anchor (not a standalone list item) is an error
    try std.testing.expectError(error.MisplacedAnchor, expandAnchor(a, "proxies: [__NODES__]\n", nodes_anchor, "- n1\n"));
    try std.testing.expectError(error.MisplacedAnchor, expandAnchor(a, "- __NODES__,extra\n", nodes_anchor, "- n1\n"));
}

test "expandAnchor multiple anchors and indent alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // two anchors at different indents (4 and 8 spaces)
    const tpl = "proxy-groups:\n    - name: A\n        proxies:\n            - __NODES__\n    - name: B\n        proxies:\n            - __NODES__\n";
    const out = try expandAnchor(a, tpl, nodes_anchor, "- n1\n- n2\n");
    try std.testing.expectEqualStrings(
        "proxy-groups:\n    - name: A\n        proxies:\n            - n1\n            - n2\n    - name: B\n        proxies:\n            - n1\n            - n2\n",
        out,
    );
    // block with two items and a trailing newline
    const out2 = try expandAnchor(a, "- __NODES__\n", nodes_anchor, "- x\n- y\n");
    try std.testing.expectEqualStrings("- x\n- y\n", out2);
    // bare anchor word (not a list item) is misplaced
    try std.testing.expectError(error.MisplacedAnchor, expandAnchor(a, "__NODES__\n", nodes_anchor, "- a\n"));
    const out4 = try expandAnchor(a, "- __NODES__\n", nodes_anchor, "- a\n");
    try std.testing.expectEqualStrings("- a\n", out4);
}

test "compile-check" {
    _ = &fillList;
    _ = &expandAnchor;
    _ = &appendBlock;
    _ = &detectIndent;
    _ = &fillState;
    _ = &matchFillLine;
    _ = &matchKeyLine;
    _ = &matchAnchorLine;
}
