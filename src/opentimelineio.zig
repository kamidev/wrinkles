const std = @import("std");
const expectApproxEqAbs= std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const expectError= std.testing.expectError;

const opentime = @import("opentime");
const Duration = f32;

const interval = opentime.interval;
const transform = opentime.transform;
const curve = @import("curve");
const time_topology = @import("time_topology");
const string = @import("string_stuff");

const util = opentime.util;
const otio_allocator = @import("otio_allocator");

const treecode = @import("treecode");

// const ALLOCATOR = otio_allocator.ALLOCATOR;

// const GRAPH_CONSTRUCTION_TRACE_MESSAGES = true;
const GRAPH_CONSTRUCTION_TRACE_MESSAGES = false;

// for VERY LARGE files, turn this off so that dot can process the graphs
const LABEL_HAS_BINARY_TREECODE = true;


// just for roughing tests in
pub const Clip = struct {
    name: ?string.latin_s8 = null,

    // a trim on the media space
    source_range: ?opentime.ContinuousTimeInterval = null,

    // transformation of the media space to the output space
    transform: ?time_topology.TimeTopology = null,

    pub fn trimmed_range(self: @This()) !opentime.ContinuousTimeInterval {
        if (self.source_range) |rng| {
            return rng;
        }

        // normally the available range check would go here
        return error.NoSourceRangeSet;
    }

    pub fn space(self: @This(), label: SpaceLabel) !SpaceReference {
        return .{
            .item = ItemPtr{ .clip_ptr = &self },
            .label= label,
        };
    }

    pub fn topology(self: @This()) !time_topology.TimeTopology {
        if (self.source_range) |range| {
            return time_topology.TimeTopology.init_identity(
                .{.bounds=range}
            );
        } else {
            return error.NotImplemented;
        }
    }

    pub const SPACES = enum(i8) {
        media = 0,
        output = 1,
    };
};

pub const Gap = struct {
    name: ?string.latin_s8 = null,
    duration: time_topology.Ordinate,

    pub fn topology(self: @This()) !time_topology.TimeTopology {
        _ = self;
        return error.NotImplemented;
    }
};

pub const Item = union(enum) {
    clip: Clip,
    gap: Gap,
    track: Track,
    stack: Stack,

    pub fn topology(self: @This()) error{NotImplemented}!time_topology.TimeTopology {
        return switch (self) {
            inline else => |it| try it.topology(),
        };
    }

    pub fn duration(
        self: @This()
    ) error{NotImplemented,NoSourceRangeSet}!Duration 
    {
        return switch (self) {
            .gap => error.NotImplemented,
            .clip => |cl| (try cl.trimmed_range()).duration_seconds(),
            .track => |tr| try tr.duration(),
        };
    }
};

pub const ItemPtr = union(enum) {
    clip_ptr: *const Clip,
    gap_ptr: *const Gap,
    track_ptr: *const Track,
    timeline_ptr: *const Timeline,
    stack_ptr: *const Stack,

    pub fn init_Item(item: *Item) ItemPtr {
        return switch (item.*) {
            .clip  => |*cp| .{ .clip_ptr = cp  },
            .gap   => |*gp| .{ .gap_ptr= gp    },
            .track => |*tr| .{ .track_ptr = tr },
            .stack => |*st| .{ .stack_ptr = st },
        };
    }

    pub fn topology(self: @This()) !time_topology.TimeTopology {
        return switch (self) {
            inline else => |it_ptr| try it_ptr.toplogy(),
        };
    }

    /// == impl
    pub fn equivalent_to(self: @This(), other: ItemPtr) bool {
        return switch(self) {
            .clip_ptr => |cl| cl == other.clip_ptr,
            .gap_ptr => |gp| gp == other.gap_ptr,
            .track_ptr => |tr| tr == other.track_ptr,
            .stack_ptr => |st| st == other.stack_ptr,
            .timeline_ptr => |tl| tl == other.timeline_ptr,
        };
    }

    /// fetch the contained parent pointer
    pub fn parent(self: @This()) ?ItemPtr {
        return switch(self) {
            .clip_ptr => self.clip_ptr.parent,
            .gap_ptr => null,
            .track_ptr => null,
            .stack_ptr => null,
            .timeline_ptr => null,
        };
    }

    pub fn child_index_of(self: @This(), child: ItemPtr) !i32 {
        return switch(self) {
            .track_ptr => self.track_ptr.child_index_of(child),
            else => error.NotAContainer,
        };
    }

    // return list of SpaceReference for this object
    pub fn spaces(
        self: @This(),
        allocator: std.mem.Allocator,
    ) ![]const SpaceReference 
    {
        var result = std.ArrayList(SpaceReference).init(allocator);

        switch (self) {
            .clip_ptr, => {
                try result.append( .{ .item = self, .label = SpaceLabel.output});
                try result.append( .{ .item = self, .label = SpaceLabel.media});
            },
            .track_ptr, .timeline_ptr, .stack_ptr => {
                try result.append( .{ .item = self, .label = SpaceLabel.output});
                try result.append( .{ .item = self, .label = SpaceLabel.intrinsic});
            },
            .gap_ptr => {
                try result.append( .{ .item = self, .label = SpaceLabel.output});
            },
            // else => { return error.NotImplemented; }
        }

        return result.toOwnedSlice();

    }

    pub fn space(self: @This(), label: SpaceLabel) !SpaceReference {
        return .{ .item = self, .label = label };
    }

    pub fn build_transform(
        self: @This(),
        from_space: SpaceLabel,
        to_space: SpaceReference,
        step: u1
    ) !time_topology.TimeTopology 
    {
        if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) {
            std.debug.print(
                "transform from space: {s}\n",
                .{ @tagName(from_space) }
            );
        }

        return switch (self) {
            .track_ptr => |*tr| {
                switch (from_space) {
                    SpaceLabel.output => (
                        return time_topology.TimeTopology.init_identity_infinite()
                    ),
                    SpaceLabel.intrinsic => (
                        return time_topology.TimeTopology.init_identity_infinite()
                    ),
                    SpaceLabel.child => {
                        if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) {
                            std.debug.print("CHILD {b}\n", .{ step});
                        }

                        if (step == 0) {
                            return (
                                time_topology.TimeTopology.init_identity_infinite()
                            );
                        } 
                        else {
                            return try tr.*.transform_to_child(to_space);
                        }

                    },
                    // track supports no other spaces
                    else => unreachable,
                }
            },
            .clip_ptr => |*cl| {
                // Clip spaces and transformations
                //
                // key: 
                //   + space
                //   * transformation
                //
                // +--- OUTPUT
                // |
                // *--- (implicit) post transform->OUTPUT space (reset start time to 0)
                // |
                // +--- (implicit) post effects space
                // |
                // *--- .transform field (in real OTIO this would be relevant EFFECTS)
                // |
                // +--- (implicit) intrinsic
                // |
                // *--- (implicit) media->intrinsic xform: set the start time to 0
                // |
                // +--- MEDIA
                //
                // initially only exposing the MEDIA and OUTPUT spaces
                //

                return switch (from_space) {
                    SpaceLabel.output => {
                        // goes to media
                        const output_to_post_transform = (
                            time_topology.TimeTopology.init_identity_infinite()
                        );

                        const post_transform_to_intrinsic = (
                            cl.*.transform 
                            orelse time_topology.TimeTopology.init_identity_infinite()
                        );

                        const output_to_intrinsic = (
                            try post_transform_to_intrinsic.project_topology(
                                output_to_post_transform
                            )
                        );

                        const media_bounds = try cl.*.trimmed_range();
                        const intrinsic_to_media_xform = (
                            transform.AffineTransform1D{
                                .offset_seconds = media_bounds.start_seconds,
                                .scale = 1,
                            }
                        );
                        const intrinsic_bounds = .{
                            .start_seconds = 0,
                            .end_seconds = media_bounds.duration_seconds()
                        };
                        const intrinsic_to_media = (
                            time_topology.TimeTopology.init_affine(
                                .{
                                    .transform = intrinsic_to_media_xform,
                                    .bounds = intrinsic_bounds,
                                }
                            )
                        );

                        const output_to_media = try intrinsic_to_media.project_topology(
                            output_to_intrinsic
                        );

                        return output_to_media;
                    },
                    else => time_topology.TimeTopology.init_identity(
                        .{
                            .bounds = try cl.*.trimmed_range()
                        }
                    ),
                };
            },
            // wrapped as identity
            .gap_ptr, .timeline_ptr, .stack_ptr => (
                time_topology.TimeTopology.init_identity_infinite()
            ),
            // else => |case| { 
            //     std.log.err("Not Implemented: {any}\n", .{ case });
            //
            //     // return error.NotImplemented;
            //     return time_topology.TimeTopology.init_identity_infinite();
            // },
        };
    }
};

pub const Track = struct {
    name: ?string.latin_s8 = null,
    children: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator) Track { 
        return .{
            .children = std.ArrayList(Item).init(allocator),
        };
    }

    pub fn deinit(self: @This()) void {
        self.children.deinit();
    }

    pub fn duration(
        self: @This()
    ) !Duration  {
        var total_duration: Duration = 0;
        for (self.children.items) |c| {
            total_duration += try c.duration();
        }

        return total_duration;
    }

    pub fn append(self: *Track, item: Item) !void {
        try self.children.append(item);
    }

    pub fn space(self: *Track, label: SpaceLabel) !SpaceReference {
        return .{
            .item = ItemPtr{ .track_ptr = self },
            .label= label,
        };
    }

    pub fn topology(self: @This()) !time_topology.TimeTopology {
        // build the bounds
        var bounds: ?interval.ContinuousTimeInterval = null;
        for (self.children.items) |it| {
            const it_bound = (try it.topology()).bounds();
            if (bounds) |b| {
                bounds = interval.extend(b, it_bound);
            } else {
                bounds = it_bound;
            }
        }

        // unpack the optional
        const result_bound:interval.ContinuousTimeInterval = bounds orelse .{
            .start_seconds = 0,
            .end_seconds = 0,
        };

        return time_topology.TimeTopology.init_identity(.{.bounds=result_bound});
    }

    pub fn child_index_of(self: @This(), child_to_find: ItemPtr) !i32 {
        return for (self.children.items, 0..) 
                   |current, index| 
        {
            if (std.meta.eql(current, child_to_find)) {
                break index;
            }
        } else null;
    }

    pub fn child_ptr_from_index(self: @This(), index: usize) ItemPtr {
        return ItemPtr.init_Item(&self.children.items[index]);
    }

    pub fn transform_to_child(
        self: @This(),
        child_space_reference: SpaceReference,
    ) !time_topology.TimeTopology {
        // [child 1][child 2]
        const child_index = child_space_reference.child_index orelse unreachable;
        const child = self.child_ptr_from_index(child_index);
        const child_range = try child.clip_ptr.trimmed_range();
        const child_duration = child_range.duration_seconds();

        return time_topology.TimeTopology.init_affine(
            .{
                .bounds = .{
                    .start_seconds = child_range.start_seconds + child_duration,
                    .end_seconds = util.inf
                },
                .transform = .{
                    .offset_seconds = -child_duration,
                    .scale = 1,
                }
            }
        );
    }
};

const SpaceLabel = enum(i8) {
    output = 0,
    intrinsic,
    media,
    child,
};

const SpaceReference = struct {
    item: ItemPtr,
    label: SpaceLabel,
    child_index: ?usize = null,
};

const ProjectionOperatorArgs = struct {
    source: SpaceReference,
    destination: SpaceReference,
};

// @TODO: might boil out over time
const ProjectionOperator = struct {
    args: ProjectionOperatorArgs,
    topology: time_topology.TimeTopology,

    pub fn project_ordinate(self: @This(), ord_to_project: f32) !f32 {
        return self.topology.project_ordinate(ord_to_project);
    }
};

/// Map of a timeline.  Can find transformations through the map.
const TopologicalMap = struct {
    map_space_to_code:std.AutoHashMap(
          SpaceReference,
          treecode.Treecode,
    ),
    map_code_to_space:treecode.TreecodeHashMap(SpaceReference),

    pub fn init(allocator: std.mem.Allocator) !TopologicalMap {
        return .{ 
            .map_space_to_code = std.AutoHashMap(
            SpaceReference,
            treecode.Treecode,
        ).init(allocator),
            .map_code_to_space = treecode.TreecodeHashMap(
                SpaceReference,
            ).init(allocator),
        };
    }

    pub fn deinit(self: @This()) void {
        // build a mutable alias of self
        var mutable_self = self;

        // free the guts
        mutable_self.map_space_to_code.deinit();
        mutable_self.map_code_to_space.deinit();
    }

    const ROOT_TREECODE:treecode.TreecodeWord = 0b1;

    pub fn root(self: @This()) SpaceReference {
        const tree_word = treecode.Treecode{
            .sz = 1,
            .treecode_array = blk: {
                var output = [_]treecode.TreecodeWord{ ROOT_TREECODE };
                break :blk &output;
            },
            .allocator = undefined,
        };

        // should always have a root object
        return self.map_code_to_space.get(tree_word) orelse unreachable;
    }

    pub fn build_projection_operator(
        self: @This(),
        args: ProjectionOperatorArgs,
    ) !ProjectionOperator {
        var source_code = (
            if (self.map_space_to_code.get(args.source)) |code| code 
            else return error.SourceNotInMap
        );

        var destination_code = (
            if (self.map_space_to_code.get(args.destination)) |code| code 
            else return error.DestinationNotInMap
        );

        if (path_exists(source_code, destination_code) == false) {
            errdefer std.debug.print(
                "\nERROR\nsource: {b} dest: {b}\n",
                .{ source_code.treecode_array[0], destination_code.treecode_array[0] }
            );
            return error.NoPathBetweenSpaces;
        }

        const needs_inversion = (
            source_code.code_length() > destination_code.code_length()
        );

        var current = args.source;

        // only supporting forward projection at the moment
        if (needs_inversion) {
            const tmp = source_code;
            source_code = destination_code;
            destination_code = tmp;

            current = args.destination;
        }

        var current_code = source_code;

        var proj = time_topology.TimeTopology.init_identity_infinite();

        if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) {
            std.debug.print(
                "starting walk from: {b} to: {b}\n",
                .{
                    current_code.treecode_array[0],
                    destination_code.treecode_array[0] 
                }
            );
        }

        while (current_code.eql(destination_code) == false) 
        {
            const next_step = try current_code.next_step_towards(destination_code);

            var next_code = try current_code.clone();
            try next_code.append(next_step);

            // path has already been verified
            const next = self.map_code_to_space.get(
                next_code
            ) orelse unreachable;
            if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) { 
                std.debug.print(
                    "  step {b} to next code: {d}\n",
                    .{ next_step, next_code.hash() }
                );
            }

            var next_proj = try current.item.build_transform(
                current.label,
                next,
                next_step
            );

            // transformation spaces:
            // proj:         input   -> current
            // next_proj:    current -> next
            // current_proj: input   -> next
            const current_proj = try next_proj.project_topology(proj);

            current_code = next_code;
            current = next;
            proj = current_proj;
        }

        if (needs_inversion) {
            proj = try proj.inverted();
        }

        return .{
            .args = args,
            .topology = proj,
        };
    }

    // @TODO: add a print for the enum of the transform on the node
    //        that at least lets you spot empty/bezier/affine etc
    //        transforms
    //
    fn label_for_node_leaky(
        allocator: std.mem.Allocator,
        ref: SpaceReference,
        code: treecode.Treecode,
    ) !string.latin_s8 
    {
        const item_kind = switch(ref.item) {
            .track_ptr => "track",
            .clip_ptr => "clip",
            .gap_ptr => "gap",
            .timeline_ptr => "timeline",
            .stack_ptr => "stack",
        };


        if (LABEL_HAS_BINARY_TREECODE) {
            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            try code.to_str(&buf);

            const args = .{
                item_kind,
                @tagName(ref.label),
                buf.items,
            };
            return std.fmt.allocPrint(allocator, "{s}_{s}_{s}", args);
        } 
        else {
            const args = .{ item_kind, @tagName(ref.label), code.hash(), };

            return std.fmt.allocPrint(allocator, "{s}_{s}_{any}", args);
        }

    }

    // @TODO: doesn't need an allocator
    pub fn write_dot_graph(
        self:@This(),
        allocator_: std.mem.Allocator,
        filepath: string.latin_s8
    ) !void 
    {
        const root_space = self.root(); 
        _ = allocator_;
        
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var buf = std.ArrayList(u8).init(allocator);

        // open the file
        const file = try std.fs.createFileAbsolute(filepath,.{});
        defer file.close();
        errdefer file.close();

        try file.writeAll("digraph OTIO_TopologicalMap {\n");


        const Node = struct {
            space: SpaceReference,
            code: treecode.Treecode 
        };

        var stack = std.ArrayList(Node).init(allocator);

        try stack.append(
            .{
                .space = root_space,
                .code = try treecode.Treecode.init_word(
                    allocator,
                    0b1
                )
            }
        );

        while (stack.items.len > 0) {
            const current = stack.pop();
            const current_label = try label_for_node_leaky(
                allocator,
                current.space,
                current.code
            );

            {
                var left = try current.code.clone();
                try left.append(0);

                if (self.map_code_to_space.get(left)) |next| {
                    const next_label = try label_for_node_leaky(
                        allocator,
                        next,
                        left
                    );
                    try file.writeAll(
                        try std.fmt.allocPrint(
                            allocator,
                            "  {s} -> {s}\n",
                            .{current_label, next_label}
                        )
                    );
                    try stack.append(.{.space = next, .code = left});
                } else {
                    buf.clearAndFree();
                    try left.to_str(&buf);

                    try file.writeAll(
                        try std.fmt.allocPrint(
                            allocator,
                            "  {s} \n  [shape=point]{s} -> {s}\n",
                            .{buf.items, current_label, buf.items }
                        )
                    );
                }
            }

            {
                var right = try current.code.clone();
                try right.append(1);

                if (self.map_code_to_space.get(right)) |next| {
                    const next_label = try label_for_node_leaky(
                        allocator,
                        next,
                        right
                    );
                    try file.writeAll(
                        try std.fmt.allocPrint(
                            allocator,
                            "  {s} -> {s}\n",
                            .{current_label, next_label}
                        )
                    );
                    try stack.append(.{.space = next, .code = right});
                } else {
                    buf.clearAndFree();
                    try right.to_str(&buf);
                    try file.writeAll(
                        try std.fmt.allocPrint(
                            allocator,
                            "  {s} [shape=point]\n  {s} -> {s}\n",
                            .{buf.items, current_label, buf.items}
                        )
                    );
                }
            }
        }

        try file.writeAll("}\n");
    }
};

pub fn path_exists(fst: treecode.Treecode, snd: treecode.Treecode) bool {
    return fst.eql(snd) or (fst.is_superset_of(snd) or snd.is_superset_of(fst));
}

pub fn depth_child_code(
    parent_code:treecode.Treecode,
    index: usize
) !treecode.Treecode 
{
    var result = try parent_code.clone();
    var i:usize = 0;
    while (i < index):(i+=1) {
        try result.append(0);
    }
    return result;
}

test "depth_child_hash: math" {
    var root = try treecode.Treecode.init_word(
        std.testing.allocator,
        0b1000
    );
    defer root.deinit();

    var i:usize = 0;

    const expected_root:treecode.TreecodeWord = 0b1000;

    while (i<4) 
        : (i+=1) 
    {
        var result = try depth_child_code(root, i);
        defer result.deinit();

        const expected = std.math.shl(treecode.TreecodeWord, expected_root, i); 

        errdefer std.debug.print(
            "iteration: {d}, expected: {b} got: {b}\n",
            .{ i, expected, result.treecode_array[0] }
        );

        try expectEqual(expected, result.treecode_array[0]);
    }
}
//
// // get the index of the child by how many times the child is a "right" from the
// // parent.
// //
// // examples:
// // 0b11101 2
// // 0b1011111 0
// // 0b11100 2
// // 0b1100111111 1
// pub fn right_child_index(
//     child_code:treecode.Treecode
// ) usize {
//     // find the marker bit
//
//     _ = child_code;
//
//     return 0;
// }

// test "right_child_index" {
//     const TestData = struct {
//         leading_ones: usize,
//         trailing_ones: usize,
//         middle_zeros: usize,
//     };
//
//     const tests = [_]TestData{
//         .{ .leading_ones = 1, .trailing_ones = 1, .middle_zeros = 1 },
//         .{ .leading_ones = 1, .trailing_ones = 10, .middle_zeros = 1 },
//         .{ .leading_ones = 0, .trailing_ones = 10, .middle_zeros = 1 },
//         .{ .leading_ones = 128, .trailing_ones = 32, .middle_zeros = 1 },
//         .{ .leading_ones = 1, .trailing_ones = 2, .middle_zeros = 126 },
//         .{ .leading_ones = 1024, .trailing_ones = 1, .middle_zeros = 1024 },
//         .{ .leading_ones = 1024, .trailing_ones = 1, .middle_zeros = 1 },
//         .{ .leading_ones = 1, .trailing_ones = 1024, .middle_zeros = 1 },
//     };
//
//     for (tests) |t, index| {
//         var tc = try treecode.Treecode.init_empty(std.testing.allocator);
//         defer tc.deinit();
//
//         var i:usize = 0;
//         while (i < t.leading_ones) : (i += 1) {
//             try tc.append(1);
//         }
//
//         i = 0;
//         while (i < t.middle_zeros) : (i += 1) {
//             try tc.append(0);
//         }
//
//         i = 0;
//         while (i  t.trailing_ones) : (i += 1) {
//             try tc.append(1);
//         }
//
//         errdefer std.debug.print(
//             "\niteration: {d}\n leading: {d} zeros: {d} trailing: {d} right_child_index: {b}\n",
//             .{ index, t.leading_ones, t.middle_zeros, t.trailing_ones, right_child_index(tc) },
//         );
//         
//         try std.testing.expectEqual(t.trailing_ones, right_child_index(tc));
//     }
// }

// @TODO: this function is super sloppy with its allocations and needs to be
//        rebuilt
pub fn build_topological_map(
    // allocator: std.mem.Allocator,
    root_item: ItemPtr
) !TopologicalMap 
{
    const tmp_allocator = otio_allocator.ALLOCATOR;
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // const tmp_allocator = arena.allocator();
    //
    var tmp_topo_map = try TopologicalMap.init(tmp_allocator);

    const Node = struct {
        path_code: treecode.Treecode,
        object: ItemPtr,
    };

    var stack = std.ArrayList(Node).init(tmp_allocator);

    const start_code = try treecode.Treecode.init_word(tmp_allocator, 0b1);

    // root node
    try stack.append(.{.object = root_item, .path_code = start_code});

    if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) {
        std.debug.print("starting graph...\n", .{});
    }

    while (stack.items.len > 0) 
    {
        const current = stack.pop();

        var current_code = try current.path_code.clone();

        {
            // object intermediate spaces
            const spaces = try current.object.spaces(
                tmp_allocator
            );

            for (0.., spaces) 
                |index, space_ref| 
            {
                const child_code = try depth_child_code(current_code, index);
                if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) {
                    std.debug.assert(tmp_topo_map.map_code_to_space.get(child_code) == null);
                    std.debug.assert(tmp_topo_map.map_space_to_code.get(space_ref) == null);
                    std.debug.print(
                        "[{d}] code: {b} hash: {d} adding local space: '{s}.{s}'\n",
                        .{
                            index,
                            child_code.treecode_array[0],
                            child_code.hash(), 
                            @tagName(space_ref.item),
                            @tagName(space_ref.label)
                        }
                    );
                }
                try tmp_topo_map.map_space_to_code.put(space_ref, child_code);
                try tmp_topo_map.map_code_to_space.put(child_code, space_ref);

                if (index == (spaces.len - 1)) {
                    current_code = child_code;
                }
            }
        }

        // transforms to children
        const children = switch (current.object) {
            inline .track_ptr, .stack_ptr => |st_or_tr|  st_or_tr.children.items,
            .timeline_ptr => |tl|  &[_]Item{ .{ .stack = tl.tracks } },
            else => &[_]Item{},
        };

        for (children, 0..) 
            |*child, index| 
            {
                const item_ptr:ItemPtr = switch (child.*) {
                    .clip => |*cl| .{ .clip_ptr = cl },
                    .gap => |*gp| .{ .gap_ptr = gp },
                    .track => |*tr_p| .{ .track_ptr = tr_p },
                    .stack => |*st_p| .{ .stack_ptr = st_p },
                };

                const child_space_code = try sequential_child_code(
                    current_code,
                    index
                );

                // insert the child scope
                const space_ref = SpaceReference{
                    .item = current.object,
                    .label = SpaceLabel.child,
                    .child_index = index,
                };

                if (GRAPH_CONSTRUCTION_TRACE_MESSAGES) {
                    std.debug.assert(tmp_topo_map.map_code_to_space.get(child_space_code) == null);

                    if (tmp_topo_map.map_space_to_code.get(space_ref)) |other_code| {
                        std.debug.print(
                            "\n ERROR SPACE ALREADY PRESENT[{d}] code: {b} other_code: {b} adding child space: '{s}.{s}.{d}'\n",
                            .{
                                index,
                                child_space_code.treecode_array[0],
                                other_code.treecode_array[0],
                                @tagName(space_ref.item),
                                @tagName(space_ref.label),
                                space_ref.child_index.?,
                            }
                        );

                        std.debug.assert(false);
                    }
                    std.debug.print(
                        "[{d}] code: {b} hash: {d} adding child space: '{s}.{s}.{d}'\n",
                        .{
                            index,
                            child_space_code.treecode_array[0],
                            child_space_code.hash(),
                            @tagName(space_ref.item),
                            @tagName(space_ref.label),
                            space_ref.child_index.?,
                        }
                    );
                }
                try tmp_topo_map.map_space_to_code.put(space_ref, child_space_code);
                try tmp_topo_map.map_code_to_space.put(child_space_code, space_ref);

                const child_code = try depth_child_code(child_space_code, 1);

                try stack.insert(
                    0,
                    .{ .object= item_ptr, .path_code = child_code}
                );
            }
    }

    // var result = try TopologicalMap.init(allocator);
    //
    // result.map_code_to_space = try tmp_topo_map.map_code_to_space.cloneWithAllocator(
    //     allocator
    // );
    // result.map_space_to_code = try tmp_topo_map.map_space_to_code.cloneWithAllocator(
    //     allocator
    // );
    //
    // std.debug.assert(result.map_code_to_space.count() > 0);
    // std.debug.assert(result.map_space_to_code.count() > 0);

    // return result;
    return tmp_topo_map;
}

test "clip topology construction" {
    const start_seconds:f32 = 1;
    const end_seconds:f32 = 10;
    const cl = Clip {
        .source_range = .{
            .start_seconds = start_seconds,
            .end_seconds = end_seconds 
        }
    };

    const topo = try cl.topology();

    try expectApproxEqAbs(
        start_seconds,
        topo.bounds().start_seconds,
        util.EPSILON,
    );

    try expectApproxEqAbs(
        end_seconds,
        topo.bounds().end_seconds,
        util.EPSILON,
    );
}

test "track topology construction" {
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();

    const start_seconds:f32 = 1;
    const end_seconds:f32 = 10;
    const cl = Clip {
        .source_range = .{
            .start_seconds = start_seconds,
            .end_seconds = end_seconds 
        }
    };
    try tr.append(.{ .clip = cl });

    const topo =  try tr.topology();

    try expectApproxEqAbs(
        start_seconds,
        topo.bounds().start_seconds,
        util.EPSILON,
    );

    try expectApproxEqAbs(
        end_seconds,
        topo.bounds().end_seconds,
        util.EPSILON,
    );
}

test "build_topological_map check root node" {
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();

    const start_seconds:f32 = 1;
    const end_seconds:f32 = 10;

    const cl = Clip {
        .source_range = .{
            .start_seconds = start_seconds,
            .end_seconds = end_seconds 
        }
    };
    try tr.append(.{ .clip = cl });

    var i:i32 = 0;
    while (i < 10) {
        const cl2 = Clip {
            .source_range = .{
                .start_seconds = start_seconds,
                .end_seconds = end_seconds 
            }
        };
        try tr.append(.{ .clip = cl2 });
        i+=1;
    }

    try std.testing.expectEqual(@as(usize, 11), tr.children.items.len);

    const map = try build_topological_map(
        // std.testing.allocator,
        .{ .track_ptr = &tr },
    );
    defer map.deinit();

    try expectEqual(
        tr.space(.output),
        map.root(),
    );

}

test "path_code: graph test" {
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();

    const start_seconds:f32 = 1;
    const end_seconds:f32 = 10;

    const cl = Clip {
        .source_range = .{
            .start_seconds = start_seconds,
            .end_seconds = end_seconds 
        }
    };
    try tr.append(.{ .clip = cl });

    var i:i32 = 0;
    while (i < 10) {
        const cl2 = Clip {
            .source_range = .{
                .start_seconds = start_seconds,
                .end_seconds = end_seconds 
            }
        };
        try tr.append(.{ .clip = cl2 });
        i+=1;
    }

    try std.testing.expectEqual(@as(usize, 11), tr.children.items.len);

    const map = try build_topological_map(
        // std.testing.allocator,
        .{ .track_ptr = &tr },
    );
    defer map.deinit();

    try expectEqual(
        tr.space(.output),
        map.root(),
    );

    try map.write_dot_graph(
        std.testing.allocator,
        "/var/tmp/graph_test_output.dot"
    );

    // should be the same length
    try std.testing.expectEqual(
        map.map_space_to_code.count(),
        map.map_code_to_space.count(),
    );
    try std.testing.expectEqual(
        @as(usize, 35),
        map.map_space_to_code.count()
    );

    try map.write_dot_graph(
        std.testing.allocator,
        "/var/tmp/current.dot",
    );

    const TestData = struct {
        ind: usize,
        expect: treecode.TreecodeWord, 
    };

    const test_data = [_]TestData{
        .{.ind = 0, .expect= 0b1010 },
        .{.ind = 1, .expect= 0b10110 },
        .{.ind = 2, .expect= 0b101110 },
    };
    for (0.., test_data)
        |t_i, t| 
    {
        const space = (
            try tr.child_ptr_from_index(t.ind).space(SpaceLabel.output)
        );
        const result = map.map_space_to_code.get(space) orelse unreachable;

        errdefer std.log.err(
            "\n[iteration: {d}] index: {d} expected: {b} result: {b} \n",
            .{t_i, t.ind, t.expect, result.treecode_array[0]}
        );

        const expect = try treecode.Treecode.init_word(
            std.testing.allocator,
            t.expect
        );
        defer expect.deinit();

        try std.testing.expect(expect.eql(result));
    }
}

test "Track with clip with identity transform projection" {
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();

    const start_seconds:f32 = 1;
    const end_seconds:f32 = 10;
    const range = interval.ContinuousTimeInterval{
        .start_seconds = start_seconds,
        .end_seconds = end_seconds,
    };

    const cl = Clip{.source_range = range};
    try tr.append(.{ .clip = cl });

    var i:i32 = 0;
    while (i < 10) {
        const cl2 = Clip {.source_range = range};
        try tr.append(.{ .clip = cl2 });
        i+=1;
    }

    const map = try build_topological_map(
        // std.testing.allocator,
        .{ .track_ptr = &tr },
    );
    defer map.deinit();

    const clip = tr.child_ptr_from_index(0);
    const track_to_clip = try map.build_projection_operator(
        .{
            .source = try tr.space(SpaceLabel.output),
            .destination =  try clip.space(SpaceLabel.media)
        }
    );

    // check the bounds
    try expectApproxEqAbs(
        @as(f32, 0),
        track_to_clip.topology.bounds().start_seconds,
        util.EPSILON,
    );

    try expectApproxEqAbs(
        end_seconds - start_seconds,
        track_to_clip.topology.bounds().end_seconds,
        util.EPSILON,
    );

    // check the projection
    try expectApproxEqAbs(
        @as(f32, 4),
        try track_to_clip.project_ordinate(3),
        util.EPSILON,
    );
}


test "PathMap: Track with clip with identity transform topological" {
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();

    const cl = Clip { .source_range = .{ .start_seconds = 0, .end_seconds = 2 } };

    // a copy -- which is why we can't use `cl` in our searches.
    try tr.append(.{ .clip = cl });

    const root = ItemPtr{ .track_ptr = &tr };

    const map = try build_topological_map(
        // std.testing.allocator,
        root,
    );
    defer map.deinit();

    try expectEqual(@as(usize, 5), map.map_code_to_space.count());
    try expectEqual(@as(usize, 5), map.map_space_to_code.count());

    try expectEqual(root, map.root().item);

    const root_code = map.map_space_to_code.get(map.root()) orelse unreachable;

    {
        var tc = try treecode.Treecode.init_word(std.testing.allocator, 0b1);
        defer tc.deinit();
        try std.testing.expect(tc.eql(root_code));
    }

    const clip = tr.child_ptr_from_index(0);
    const clip_code = map.map_space_to_code.get(try clip.space(SpaceLabel.media)) orelse unreachable;

    {
        var tc = try treecode.Treecode.init_word(std.testing.allocator, 0b10010);
        defer tc.deinit();
        errdefer std.debug.print(
            "\ntc: {b}, clip_code: {b}\n",
            .{ tc.treecode_array[0], clip_code.treecode_array[0] },
        );
        try std.testing.expect(tc.eql(clip_code));
    }

    try expectEqual(true, path_exists(clip_code, root_code));

    const root_output_to_clip_media = try map.build_projection_operator(
        .{
            .source = try root.space(SpaceLabel.output),
            .destination = try clip.space(SpaceLabel.media)
        }
    );

    try expectError(
        time_topology.TimeTopology.ProjectionError.OutOfBounds,
        root_output_to_clip_media.project_ordinate(3)
    );

    try expectApproxEqAbs(
        @as(f32, 1),
        try root_output_to_clip_media.project_ordinate(1),
        util.EPSILON,
    );
}

test "Projection: Track with single clip with identity transform and bounds" {
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();

    const root = ItemPtr{ .track_ptr = &tr };

    const cl = Clip { .source_range = .{ .start_seconds = 0, .end_seconds = 2 } };
    try tr.append(.{ .clip = cl });

    const clip = tr.child_ptr_from_index(0);

    const map = try build_topological_map(
        // std.testing.allocator,
        root,
    );
    defer map.deinit();

    try expectEqual(
        @as(usize, 5),
        map.map_code_to_space.count()
    );
    try expectEqual(
        @as(usize, 5),
        map.map_space_to_code.count()
    );

    const root_output_to_clip_media = try map.build_projection_operator(
        .{ 
            .source = try root.space(SpaceLabel.output),
            .destination = try clip.space(SpaceLabel.media),
        }
    );

    // check the bounds
    try expectApproxEqAbs(
        (cl.source_range orelse interval.ContinuousTimeInterval{}).start_seconds,
        root_output_to_clip_media.topology.bounds().start_seconds,
        util.EPSILON,
    );

    try expectApproxEqAbs(
        (cl.source_range orelse interval.ContinuousTimeInterval{}).end_seconds,
        root_output_to_clip_media.topology.bounds().end_seconds,
        util.EPSILON,
    );

    try expectError(
        time_topology.TimeTopology.ProjectionError.OutOfBounds,
        root_output_to_clip_media.project_ordinate(3)
    );
}

test "Projection: Track with multiple clips with identity transform and bounds" {
    //
    //                          0               3             6
    // track.output space       [---------------*-------------)
    // track.intrinsic space    [---------------*-------------)
    // child.clip output space  [--------)[-----*---)[-*------)
    //                          0        2 0    1   2 0       2 
    //
    var tr = Track.init(std.testing.allocator);
    defer tr.deinit();
    const track_ptr = ItemPtr{ .track_ptr = &tr };

    const cl = Clip { .source_range = .{ .start_seconds = 0, .end_seconds = 2 } };

    // add three copies
    try tr.append(.{ .clip = cl });
    try tr.append(.{ .clip = cl });
    try tr.append(.{ .clip = cl });

    const TestData = struct {
        ind: usize,
        t_ord: f32,
        m_ord: f32,
        err: bool
    };

    const map = try build_topological_map(
        // std.testing.allocator,
        track_ptr,
    );
    defer map.deinit();

    const tests = [_]TestData{
        .{ .ind = 1, .t_ord = 3, .m_ord = 1, .err = false},
        .{ .ind = 0, .t_ord = 1, .m_ord = 1, .err = false },
        .{ .ind = 2, .t_ord = 5, .m_ord = 1, .err = false },
        .{ .ind = 0, .t_ord = 7, .m_ord = 1, .err = true },
    };

    for (tests, 0..) |t, t_i| {
        const child = tr.child_ptr_from_index(t.ind);

        const tr_output_to_clip_media = try map.build_projection_operator(
            .{
                .source = try track_ptr.space(SpaceLabel.output),
                .destination = try child.space(SpaceLabel.media),
            }
        );

        errdefer std.log.err(
            "[{d}] index: {d} track ordinate: {d} expected: {d} error: {any}\n",
            .{t_i, t.ind, t.t_ord, t.m_ord, t.err}
        );
        if (t.err)
        {
            try expectError(
                time_topology.TimeTopology.ProjectionError.OutOfBounds,
                tr_output_to_clip_media.project_ordinate(t.t_ord)
            );
        }
        else{
            const result = try tr_output_to_clip_media.project_ordinate(t.t_ord);

            try expectApproxEqAbs(result, t.m_ord, util.EPSILON);
        }
    }

    const clip = tr.child_ptr_from_index(0);

    const root_output_to_clip_media = try map.build_projection_operator(
        .{ 
            .source = try track_ptr.space(SpaceLabel.output),
            .destination = try clip.space(SpaceLabel.media),
        }
    );

    // check the bounds
    try expectApproxEqAbs(
        (cl.source_range orelse interval.ContinuousTimeInterval{}).start_seconds,
        root_output_to_clip_media.topology.bounds().start_seconds,
        util.EPSILON,
    );

    try expectApproxEqAbs(
        (cl.source_range orelse interval.ContinuousTimeInterval{}).end_seconds,
        root_output_to_clip_media.topology.bounds().end_seconds,
        util.EPSILON,
    );

    try expectError(
        time_topology.TimeTopology.ProjectionError.OutOfBounds,
        root_output_to_clip_media.project_ordinate(3)
    );
}

test "Single Clip Media to Output Identity transform" {
    //
    //              0                 7           10
    // output space [-----------------*-----------)
    // media space  [-----------------*-----------)
    //              100               107         110 (seconds)
    //              
    const source_range = interval.ContinuousTimeInterval{
        .start_seconds = 100,
        .end_seconds = 110 
    };

    const cl = Clip { .source_range = source_range };
    const cl_ptr : ItemPtr = .{ .clip_ptr = &cl};

    const map = try build_topological_map(
        // std.testing.allocator,
        cl_ptr,
    );
    // defer map.deinit();

    try expectEqual(
        @as(usize, 2),
        map.map_code_to_space.count()
    );
    try expectEqual(
        @as(usize, 2),
        map.map_space_to_code.count()
    );

    // output->media
    {
        const clip_output_to_media = try map.build_projection_operator(
            .{
                .source =  try cl_ptr.space(SpaceLabel.output),
                .destination = try cl_ptr.space(SpaceLabel.media),
            }
        );

        try expectApproxEqAbs(
            @as(f32, 103),
            try clip_output_to_media.project_ordinate(3),
            util.EPSILON,
        );

        try expectApproxEqAbs(
            @as(f32,0),
            clip_output_to_media.topology.bounds().start_seconds,
            util.EPSILON,
        );

        try expectApproxEqAbs(
            source_range.duration_seconds(),
            clip_output_to_media.topology.bounds().end_seconds,
            util.EPSILON,
        );
    }

    // media->output
    {
        const clip_output_to_media = try map.build_projection_operator(
            .{
                .source =  try cl_ptr.space(SpaceLabel.media),
                .destination = try cl_ptr.space(SpaceLabel.output),
            }
        );

        try expectApproxEqAbs(
            @as(f32, 3),
            try clip_output_to_media.project_ordinate(103),
            util.EPSILON,
        );
    }
}

test "Single Clip reverse transform" {
    //
    // xform: reverse (linear w/ -1 slope)
    // note: transforms map from the _output_ space to the _media_ space
    //
    //              0                 7           10
    // output       [-----------------*-----------)
    // (transform)  10                3           0
    // media        [-----------------*-----------)
    //              110               103         100 (seconds)
    //

    const start = curve.ControlPoint{ .time = 0, .value = 10 };
    const end = curve.ControlPoint{ .time = 10, .value = 0 };
    const inv_tx = time_topology.TimeTopology.init_linear_start_end(start, end);

    const source_range:interval.ContinuousTimeInterval = .{
        .start_seconds = 100,
        .end_seconds = 110,
    };

    const cl = Clip { .source_range = source_range, .transform = inv_tx };
    const cl_ptr : ItemPtr = .{ .clip_ptr = &cl};

    const map = try build_topological_map(
        // std.testing.allocator,
        cl_ptr,
    );
    defer map.deinit();

    // output->media (forward projection)
    {
        const clip_output_to_media_topo = try map.build_projection_operator(
            .{
                .source =  try cl_ptr.space(SpaceLabel.output),
                .destination = try cl_ptr.space(SpaceLabel.media),
            }
        );
        
        try expectApproxEqAbs(
            start.time,
            clip_output_to_media_topo.topology.bounds().start_seconds,
            util.EPSILON,
        );

        try expectApproxEqAbs(
            end.time,
            clip_output_to_media_topo.topology.bounds().end_seconds,
            util.EPSILON,
        );

        try expectApproxEqAbs(
            @as(f32, 107),
            try clip_output_to_media_topo.project_ordinate(3),
            util.EPSILON,
        );
    }

    // media->output (reverse projection)
    {
        const clip_media_to_output = try map.build_projection_operator(
            .{
                .source =  try cl_ptr.space(SpaceLabel.media),
                .destination = try cl_ptr.space(SpaceLabel.output),
            }
        );

        try expectApproxEqAbs(
            @as(f32, 3),
            try clip_media_to_output.project_ordinate(107),
            util.EPSILON,
        );
    }
}

test "Single Clip bezier transform" {
    //
    // xform: s-curve read from sample curve file
    //        curves map from the output space to the intrinsic space for clips
    //
    //              0                             10
    // output       [-----------------------------)
    //                               _,-----------x
    // transform                   _/
    // (curve)                   ,/
    //              x-----------'
    // intrinsic    [-----------------------------)
    //              0                             10 (seconds)
    // media        100                          110 (seconds)
    //
    // the media space is defined by the source range
    //

    const base_curve = try curve.read_curve_json(
        "curves/scurve.curve.json",
        std.testing.allocator,
    );
    defer base_curve.deinit(std.testing.allocator);

    // this curve is [-0.5, 0.5), rescale it into test range
    const xform_curve = try curve.rescaled_curve(
        base_curve,
        //  the range of the clip for testing - rescale factors
        .{
            .{ .time = 0, .value = 0, },
            .{ .time = 10, .value = 10, },
        }
    );
    const curve_topo = time_topology.TimeTopology.init_bezier_cubic(
        xform_curve
    );

    // test the input space range
    const curve_bounds_input = curve_topo.bounds();
    try expectApproxEqAbs(
        @as(f32, 0),
        curve_bounds_input.start_seconds, util.EPSILON
    );
    try expectApproxEqAbs(
        @as(f32, 10),
        curve_bounds_input.end_seconds, util.EPSILON
    );

    // test the output space range (the media space of the clip)
    const curve_bounds_output = xform_curve.extents_value();
    try expectApproxEqAbs(
        @as(f32, 0),
        curve_bounds_output.start_seconds, util.EPSILON
    );
    try expectApproxEqAbs(
        @as(f32, 10),
        curve_bounds_output.end_seconds, util.EPSILON
    );

    try std.testing.expect(
        std.meta.activeTag(curve_topo) != time_topology.TimeTopology.empty
    );

    const source_range:interval.ContinuousTimeInterval = .{
        .start_seconds = 100,
        .end_seconds = 110,
    };
    const cl = Clip {
        .source_range = source_range,
        .transform = curve_topo 
    };
    const cl_ptr : ItemPtr = .{ .clip_ptr = &cl };

    const map = try build_topological_map(
        // std.testing.allocator,
        cl_ptr
    );
    defer map.deinit();

    // output->media (forward projection)
    {
        const clip_output_to_media_proj = try map.build_projection_operator(
            .{
                .source =  try cl_ptr.space(SpaceLabel.output),
                .destination = try cl_ptr.space(SpaceLabel.media),
            }
        );

        // note that the clips output space is the curve's input space
        const output_bounds = (
            clip_output_to_media_proj.topology.bounds()
        );
        try expectApproxEqAbs(
            curve_bounds_output.start_seconds, 
            output_bounds.start_seconds,
            util.EPSILON
        );
        try expectApproxEqAbs(
            curve_bounds_output.end_seconds, 
            output_bounds.end_seconds,
            util.EPSILON
        );

        // invert it back and check it against the inpout curve bounds
        const clip_media_to_output = (
            try clip_output_to_media_proj.topology.inverted()
        );
        const clip_media_to_output_bounds = (
            clip_media_to_output.bounds()
        );
        try expectApproxEqAbs(
            @as(f32, 100),
            clip_media_to_output_bounds.start_seconds, util.EPSILON
        );
        try expectApproxEqAbs(
            @as(f32, 110),
            clip_media_to_output_bounds.end_seconds, util.EPSILON
        );

        try std.testing.expect(
            std.meta.activeTag(clip_output_to_media_proj.topology) 
            != time_topology.TimeTopology.empty
        );

        // walk over the output space of the curve
        const o_s_time = output_bounds.start_seconds;
        const o_e_time = output_bounds.end_seconds;
        var output_time = o_s_time;
        while (output_time < o_e_time) 
            : (output_time += 0.01) 
        {
            // output time -> media time
            const media_time = (
                try clip_output_to_media_proj.project_ordinate(output_time)
            );
            
            errdefer std.log.err(
        "\nERR1\n  output_time: {d} \n"
                ++ "  topology output_bounds: {any} \n"
                ++ "  topology curve bounds: {any} \n ",
                .{
                    output_time,
                    clip_output_to_media_proj.topology.bounds(),
                    clip_output_to_media_proj.topology.bezier_curve.compute_bounds(),
                }
            );

            // media time -> output time
            const computed_output_time = (
                try clip_media_to_output.project_ordinate(media_time)
            ); 

            errdefer std.log.err(
                "\nERR\n  output_time: {d} \n"
                ++ "  computed_output_time: {d} \n"
                ++ " source_range: {any}\n"
                ++ "  output_bounds: {any} \n",
                .{
                    output_time,
                    computed_output_time,
                    source_range,
                    output_bounds,
                }
            );

            try expectApproxEqAbs(
                computed_output_time,
                output_time,
                util.EPSILON
            );
        }
    }

    // media->output (reverse projection)
    {
        const clip_media_to_output = try map.build_projection_operator(
            .{
                .source =  try cl_ptr.space(SpaceLabel.media),
                .destination = try cl_ptr.space(SpaceLabel.output),
            }
        );

        try expectApproxEqAbs(
            @as(f32, 6.5745),
            try clip_media_to_output.project_ordinate(107),
            util.EPSILON,
        );
    }
}

// @TODO: this needs to be init/deinit()
/// top level object
pub const Timeline = struct {
    tracks:Stack = Stack.init(std.testing.allocator),
};

/// children of a stack are simultaneous in time
pub const Stack = struct {
    name: ?string.latin_s8 = null,
    children: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator) Stack { 
        return .{
            .children = std.ArrayList(Item).init(allocator)
        };
    }

    pub fn deinit(self: @This()) void {
        self.children.deinit();
    }

    pub fn topology(self: @This()) !time_topology.TimeTopology {
        // build the bounds
        var bounds: ?interval.ContinuousTimeInterval = null;
        for (self.children.items) |it| {
            const it_bound = (try it.topology()).bounds();
            if (bounds) |b| {
                bounds = interval.extend(b, it_bound);
            } else {
                bounds = it_bound;
            }
        }

        if (bounds) |b| {
            return time_topology.TimeTopology.init_affine(.{ .bounds = b });
        } else {
            return time_topology.TimeTopology.init_empty();
        }
    }
};

pub const SerializableObjectTypes = enum {
    Timeline,
    Stack,
    Track,
    Clip,
    Gap,
};

pub const SerializableObject = union(SerializableObjectTypes) {
    Timeline:Timeline,
    Stack:Stack,
    Track:Track,
    Clip:Clip,
    Gap:Gap,
};

pub const IntrinsicSchema = enum {
    TimeRange,
    RationalTime,
};

pub fn read_float(
    obj:std.json.Value
) time_topology.Ordinate 
{
    return switch (obj) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => 0,
    };
}

pub fn read_ordinate_from_rt(
    obj:?std.json.ObjectMap
) ?time_topology.Ordinate 
{
    if (obj) 
       |o| 
    {
        const value = read_float(o.get("value").?);
        const rate = read_float(o.get("rate").?);

        return @floatCast(value/rate);
    } 
    else 
    {
        return null;
    }
}

pub fn read_time_range(obj:?std.json.ObjectMap) ?interval.ContinuousTimeInterval {
    if (obj) |o| {
        const start_time = read_ordinate_from_rt(o.get("start_time").?.object).?;
        const duration = read_ordinate_from_rt(o.get("duration").?.object).?;
        return .{ .start_seconds = start_time, .end_seconds = start_time + duration };
    } else {
        return null;
    }
}

pub fn read_otio_object(
    obj:std.json.ObjectMap
) !SerializableObject 
{
    const maybe_schema_and_version_str = obj.get("OTIO_SCHEMA");

    if (maybe_schema_and_version_str == null) {
        return error.NotAnOtioSchemaObject;
    }

    const full_string = maybe_schema_and_version_str.?.string;

    var split_schema_string = std.mem.split(
        u8,
        full_string,
        "."
    );

    const maybe_schema_str = split_schema_string.next();
    if (maybe_schema_str == null) {
        return error.MalformedSchemaString;
    }
    const schema_str = maybe_schema_str.?;

    const maybe_schema_enum = std.meta.stringToEnum(
        SerializableObjectTypes,
        schema_str
    );
    if (maybe_schema_enum == null) {
        errdefer std.log.err("No schema: {s}\n", .{schema_str});
        return error.NoSuchSchema;
    }

    const schema_enum = maybe_schema_enum.?;

    const name = if (obj.get("name")) |n| switch (n) {
        .string => |s| s,
        else => null
    } else null;

    switch (schema_enum) {
        .Timeline => { 
            var st_json = try read_otio_object(obj.get("tracks").?.object);
            const st = Stack{
                .name = st_json.Stack.name,
                .children = try st_json.Stack.children.clone(),
            };
            const tl = Timeline{ .tracks = st };
            return .{ .Timeline = tl };
        },
        .Stack => {

            var st = Stack.init(std.testing.allocator);
            st.name = name;

            for (obj.get("children").?.array.items) |track| {
                try st.children.append(
                    .{ .track = (try read_otio_object(track.object)).Track }
                );
            }

            return .{ .Stack = st };
        },
        .Track => {
            var tr = Track.init(std.testing.allocator);
            tr.name = name;

            for (obj.get("children").?.array.items) |child| {
                switch (try read_otio_object(child.object)) {
                    .Clip => |cl| { try tr.children.append( .{ .clip = cl }); },
                    .Gap => |gp| { try tr.children.append( .{ .gap = gp }); },
                    else => return error.NotImplemented,
                }
            }

            return .{ .Track = tr };
        },
        .Clip => {
            const source_range = (
                if (obj.get("source_range")) 
                |sr| switch (sr) {
                    .object => |o| read_time_range(o),
                    else => null,
                }
                else null
            );

            const cl = Clip{
                .name=name,
                .source_range = source_range,
            };

            return .{ .Clip = cl };
        },
        .Gap => {
            const source_range = (
                if (obj.get("source_range")) 
                |sr| switch (sr) {
                    .object => |o| read_time_range(o),
                    else => null,
                }
                else null
            );

            const gp = Gap{
                .name=name,
                .duration = source_range.?.duration_seconds(),
            };

            return .{ .Gap = gp };
        },
        // else => { 
        //     errdefer std.log.err("Not implemented yet: {s}\n", .{ schema_str });
        //     return error.NotImplemented; 
        // }
    }

    return error.NotImplemented;
}

pub fn read_from_file(
    allocator: std.mem.Allocator,
    file_path: string.latin_s8
) !Timeline 
{
    const fi = try std.fs.cwd().openFile(file_path, .{});
    defer fi.close();

    const source = try fi.readToEndAlloc(
        allocator,
        std.math.maxInt(u32)
    );
    // defer allocator.free(source);

    const result = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        source,
        .{}
    );
    // defer result.object.clearAndFree();

    const hopefully_timeline = try read_otio_object(
        result.object
    );

    if (hopefully_timeline == SerializableObject.Timeline) {
        return hopefully_timeline.Timeline;
    }

    return error.NotImplemented;
}

test "read_from_file test" {
    // @TODO: disabled because it has a bonkers amount of leaking in it.
    //        the JSON reader and json.object.Value -> struct code needs to be
    //        redone.
    //
    //        its a good idea, and can definitely be rescued.
    if (true) {
        return error.SkipZigTest;
    }
    const root = "simple_cut";
    // const root = "multiple_track";
    const otio_fpath = root ++ ".otio";
    const dot_fpath = root ++ ".dot";

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tl = try read_from_file(
        allocator,
        "sample_otio_files/"++otio_fpath
    );
    defer tl.tracks.deinit();

    const track0 = tl.tracks.children.items[0].track;

    if (std.mem.eql(u8, root, "simple_cut"))
    {
        try expectEqual(@as(usize, 1), tl.tracks.children.items.len);

        try expectEqual(@as(usize, 4), track0.children.items.len);
        try std.testing.expectEqualStrings(
            "Clip-001",
            track0.children.items[0].clip.name.?
        );
    }

    const tl_ptr = ItemPtr{ .timeline_ptr = &tl };
    const target_clip_ptr = (
        track0.child_ptr_from_index(0)
    );

    const map = try build_topological_map(
        // std.testing.allocator,
        tl_ptr
    );
    defer map.deinit();

    const tl_output_to_clip_media = try map.build_projection_operator(
        .{
            .source = try tl_ptr.space(SpaceLabel.output),
            .destination = try target_clip_ptr.space(SpaceLabel.media),
        }
    );
    
    try map.write_dot_graph(
        std.testing.allocator,
        "/var/tmp/" ++ dot_fpath,
    );

    try expectApproxEqAbs(
        @as(time_topology.Ordinate, 0.175),
        try tl_output_to_clip_media.project_ordinate(0.05),
        util.EPSILON
    );
}

fn sequential_child_code(src: treecode.Treecode, index: usize) !treecode.Treecode {
    var result = try src.clone();
    var i:usize = 0;
    while (i <= index):(i+=1) {
        try result.append(1);
    }
    return result;
}

test "sequential_child_hash: math" {
    var root = try treecode.Treecode.init_word(
        std.testing.allocator,
        0b1000
    );
    defer root.deinit();

    var i:usize = 0;

    var test_code = try root.clone();
    defer test_code.deinit();

    while (i<4) : (i+=1) {
        var result = try sequential_child_code(root, i);
        defer result.deinit();

        try test_code.append(1);

        errdefer std.debug.print(
            "iteration: {d}, expected: {b} got: {b}\n",
            .{ i, test_code.treecode_array[0], result.treecode_array[0] }
        );

        try std.testing.expect(test_code.eql(result));
    }

}

test "label_for_node_leaky" {
    var tr = Track.init(std.testing.allocator);
    const sr = SpaceReference{
        .label = SpaceLabel.output,
        .item = .{ .track_ptr = &tr } 
    };

    var tc = try treecode.Treecode.init_word(
        std.testing.allocator,
        0b1101001
    );
    defer tc.deinit();

    const result = try TopologicalMap.label_for_node_leaky(
        std.testing.allocator,
        sr,
        tc
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("track_output_1101001", result);
}

test "test spaces list" {
    const cl = Clip{};
    const it = ItemPtr{ .clip_ptr = &cl };
    const spaces = try it.spaces(std.testing.allocator);
    defer std.testing.allocator.free(spaces);

    try expectEqual(
       SpaceLabel.output, spaces[0].label, 
    );
    try expectEqual(
       SpaceLabel.media, spaces[1].label, 
    );
    try expectEqual(
       "output", @tagName(SpaceLabel.output)
    );
    try expectEqual(
       "media", @tagName(SpaceLabel.media),
    );
}
