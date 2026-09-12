//! Code model types deserialized from the JSON produced by
//! `codegen/tcgc-component`. The shape is duplicated on the JS
//! side in `tcgc-component/src/index.js`; the two must evolve together.
//!
//! Keep the types open (`additionalProperties` on the JS side) and
//! tolerant of missing fields here — TCGC adds new metadata over time
//! and we don't want every TypeSpec compiler upgrade to break codegen.

const std = @import("std");

pub const CodeModel = struct {
    package_name: []const u8,
    package_version: []const u8,
    target_kind: []const u8,
    service_kind: []const u8,
    clients: []Client = &.{},
    models: []Model = &.{},
    enums: []Enum = &.{},
    unions: []Union = &.{},
};

pub const Client = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    /// True for the top-level client of a service. The emitter renders
    /// `init()`/`deinit()`/auth on the root only; sub-clients borrow the
    /// pipeline by value via accessor methods.
    is_root: bool = true,
    parent_name: ?[]const u8 = null,
    /// Typed client-level state propagated through the sub-client tree
    /// (e.g. ARM's `subscription_id`). The emitter places each entry on
    /// this client, and on `InitOptions` for roots. Sub-client accessors
    /// inherit only fields declared by that child from its parent.
    init_parameters: []InitParameter = &.{},
    /// Default api-version string read from TCGC's `apiVersion`
    /// `clientDefaultValue`. Used to populate `InitOptions.api_version`.
    api_version_default: ?[]const u8 = null,
    endpoint: Endpoint,
    methods: []Method = &.{},
    sub_clients: []SubClient = &.{},
    credential_scopes: [][]const u8 = &.{},
};

pub const InitParameter = struct {
    name: []const u8,
    serialized_name: []const u8,
    doc: ?[]const u8 = null,
    param_type: TypeRef,
    optional: bool = false,
};

pub const Endpoint = struct {
    name: []const u8,
    default_value: ?[]const u8 = null,
};

pub const SubClient = struct {
    accessor_camel: []const u8,
    accessor_snake: []const u8,
    client_name: []const u8,
};

pub const Method = struct {
    name: []const u8,
    name_camel: []const u8,
    doc: ?[]const u8 = null,
    http_method: []const u8,
    path: []const u8,
    /// RFC 6570 URI template from TCGC. Unlike `path`, this preserves
    /// reserved expansion (`{+path}`) used by greedy path parameters.
    uri_template: ?[]const u8 = null,
    /// User-facing method parameters in declaration order (after the
    /// implicit `self` and `allocator`). Client-level params
    /// (`subscription_id`, `api_version`, `endpoint`) and constants
    /// (`Accept`, `Content-Type`) are absent here — they're sourced
    /// from the client struct or hard-coded.
    user_parameters: []UserParameter = &.{},
    /// Path placeholders resolved to either a client-state field or a
    /// user parameter.
    path_parameters: []WireParameter = &.{},
    /// Query-string keys; ordered as TCGC surfaces them.
    query_parameters: []WireParameter = &.{},
    /// HTTP request headers; constants are emitted unconditionally.
    header_parameters: []WireParameter = &.{},
    /// Body to serialize; null for verbs without a payload.
    body_parameter: ?BodyParameter = null,
    response: MethodResponse,
    /// Protocol-level success and error alternatives. These retain
    /// exact status codes, response headers, and raw-body metadata
    /// even when the convenient response above collapses a union.
    responses: []ResponseVariant = &.{},
    exceptions: []ResponseVariant = &.{},
    paging: ?Paging = null,
    long_running: ?LongRunning = null,
    kind: []const u8 = "basic",
};

pub const UserParameter = struct {
    name: []const u8,
    method_name: []const u8,
    doc: ?[]const u8 = null,
    param_type: TypeRef,
    optional: bool = false,
};

pub const WireParameter = struct {
    wire_name: []const u8,
    source: WireSource,
    optional: bool = false,
    style: ?[]const u8 = null,
    explode: ?bool = null,
    allow_reserved: ?bool = null,
    /// "segment" | "repository" | "greedy" | "odata-string".
    path_encoding: ?[]const u8 = null,
};

pub const WireSource = struct {
    /// "client" | "user" | "constant"
    kind: []const u8,
    /// snake_case identifier for "client"/"user" sources.
    name: ?[]const u8 = null,
    /// Constant literal for "constant" sources.
    value: ?[]const u8 = null,
};

pub const BodyParameter = struct {
    user_param_name: []const u8,
    content_type: []const u8,
    content_types: [][]const u8 = &.{},
    body_type: ?TypeRef = null,
    /// "json" | "raw" | "multipart"
    serialization_kind: []const u8 = "json",
};

pub const MethodResponse = struct {
    response_type: ?TypeRef = null,
    status_codes: []std.json.Value = &.{},
};

pub const ResponseVariant = struct {
    status_codes: []std.json.Value = &.{},
    response_type: ?TypeRef = null,
    headers: []ResponseHeader = &.{},
    content_types: [][]const u8 = &.{},
    /// "none" | "json" | "raw" | "multipart"
    body_kind: []const u8 = "none",
};

pub const ResponseHeader = struct {
    name: []const u8,
    wire_name: []const u8,
    header_type: TypeRef,
    optional: bool = false,
};

pub const Paging = struct {
    items_segments: []?[]const u8 = &.{},
    next_link_segments: []?[]const u8 = &.{},
    next_link_verb: ?[]const u8 = null,
    next_link_operation: ?[]const u8 = null,
    /// Marker set by the JS adapter when the response is the standard
    /// `{ "value": [T, ...], "nextLink": "..." }` ARM envelope. The
    /// emitter uses `core.pager.listPageParser(T)` in that case.
    envelope: ?[]const u8 = null,
    /// The element type T for envelope=`value_next_link`. Null otherwise.
    item_type: ?TypeRef = null,
};

pub const LongRunning = struct {
    final_state_via: ?[]const u8 = null,
    final_response_type: ?TypeRef = null,
};

pub const Model = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    fields: []Field = &.{},
    parents: [][]const u8 = &.{},
    discriminator: ?[]const u8 = null,
    is_input: bool = false,
    is_output: bool = false,
    /// ARM base-type kind, set by the TCGC adapter when this model's
    /// `baseModel` chain terminates in `Azure.ResourceManager.{Proxy,
    /// Tracked,Extension}Resource`. The emitter renders a
    /// `pub const arm_resource_kind: core.arm.ResourceKind = .<kind>;`
    /// inside the generated struct so `core.arm` helpers can dispatch
    /// on it.
    arm_resource_kind: ?[]const u8 = null,
    /// Type accepted for undeclared JSON properties. Null means the
    /// model is closed.
    additional_properties: ?TypeRef = null,
    /// True when any property carries XML serialization options; drives
    /// whether the emitter renders an XML-flavored `serde` decl.
    is_xml: bool = false,
    /// Root XML element name (from `@xml.name`/`@encodedName`), used when
    /// the model is the top-level element of a request/response body.
    xml_name: ?[]const u8 = null,
};

pub const Field = struct {
    name: []const u8,
    serialized_name: []const u8,
    doc: ?[]const u8 = null,
    field_type: TypeRef,
    optional: bool = false,
    read_only: bool = false,
    flatten: bool = false,
    multipart: ?MultipartField = null,
    /// XML serialization options for this property, when present.
    xml: ?XmlField = null,
};

pub const XmlField = struct {
    /// Element (or attribute) name.
    name: []const u8,
    /// True when the property is an XML attribute rather than a child element.
    attribute: bool = false,
    /// When false (the default for arrays), the property is a wrapper element
    /// named `name` containing repeated `items_name` child elements.
    unwrapped: bool = false,
    /// Child element name for wrapped arrays.
    items_name: ?[]const u8 = null,
    ns: ?XmlNs = null,
};

pub const XmlNs = struct {
    namespace: []const u8,
    prefix: []const u8,
};

pub const MultipartField = struct {
    name: []const u8,
    is_file: bool = false,
    is_multi: bool = false,
    content_types: [][]const u8 = &.{},
};

pub const Enum = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    values: []EnumValue = &.{},
    value_type: []const u8 = "string",
    extensible: bool = true,
    /// TCGC represents string-literal unions as extensible enums.
    is_union: bool = false,
};

pub const EnumValue = struct {
    name: []const u8,
    value: std.json.Value,
    doc: ?[]const u8 = null,
};

pub const Union = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    variants: []TypeRef = &.{},
    nullable: bool = false,
};

pub const TypeRef = struct {
    kind: []const u8,
    value: std.json.Value,

    pub fn isModel(self: TypeRef) bool {
        return std.mem.eql(u8, self.kind, "Model");
    }
    pub fn isEnum(self: TypeRef) bool {
        return std.mem.eql(u8, self.kind, "Enum");
    }
    pub fn isOption(self: TypeRef) bool {
        return std.mem.eql(u8, self.kind, "Option");
    }
    pub fn isArray(self: TypeRef) bool {
        return std.mem.eql(u8, self.kind, "Array");
    }
    pub fn isMap(self: TypeRef) bool {
        return std.mem.eql(u8, self.kind, "Map");
    }
    pub fn isScalar(self: TypeRef) bool {
        return std.mem.eql(u8, self.kind, "Scalar");
    }

    /// Returns the scalar string (e.g. "string", "i32") if this is a
    /// `Scalar` type, otherwise null.
    pub fn scalarName(self: TypeRef) ?[]const u8 {
        if (!self.isScalar()) return null;
        return switch (self.value) {
            .string => |s| s,
            else => null,
        };
    }

    /// Returns the named type (model / enum / union name) if this is a
    /// reference type.
    pub fn namedTypeName(self: TypeRef) ?[]const u8 {
        if (!self.isModel() and !self.isEnum() and
            !std.mem.eql(u8, self.kind, "Union")) return null;
        return switch (self.value) {
            .string => |s| s,
            else => null,
        };
    }
};
