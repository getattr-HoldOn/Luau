--[[
    Serializer

    Convert Roblox data to a storable format and restore it later.

    Serialize:
        local SerializedData = Serializer:Serialize(Data)

    Deserialize:
        local Data = Serializer:Deserialize(SerializedData)

    JSON:
        local JSON = Serializer:Encode(Data)
        local Data = Serializer:Decode(JSON)

    Supports Roblox datatypes, nested tables, cyclic tables,
    shared references, and special numbers.
]]

local HttpService = game:GetService('HttpService')

local Serializer = {}

local SERIALIZATION_VERSION = 1
local DEFAULT_MAX_DEPTH = 64

local TYPE_KEY = '__Type'
local VERSION_KEY = '__Version'
local DATA_KEY = 'Data'

local TypeHandlers = {}

local function CreateTypeHandler(Serialize, Deserialize)
    return {
        Serialize = Serialize,
        Deserialize = Deserialize
    }
end

local function RegisterBuiltInType(TypeName, Serialize, Deserialize)
    TypeHandlers[TypeName] = CreateTypeHandler(
        Serialize,
        Deserialize
    )
end

local function AssertArray(Value, Name, Length)
    if typeof(Value) ~= 'table' then
        error(Name .. ' must be a table', 0)
    end

    if Length and #Value ~= Length then
        error(
            string.format(
                '%s must contain %d values',
                Name,
                Length
            ),
            0
        )
    end

    for Index = 1, #Value do
        if Value[Index] == nil then
            error(
                string.format(
                    '%s contains an invalid value at index %d',
                    Name,
                    Index
                ),
                0
            )
        end
    end
end

local function AssertNumber(Value, Name)
    if typeof(Value) ~= 'number' then
        error(Name .. ' must be a number', 0)
    end
end

local function AssertString(Value, Name)
    if typeof(Value) ~= 'string' then
        error(Name .. ' must be a string', 0)
    end
end

RegisterBuiltInType(
    'Vector2',

    function(Value)
        return {
            Value.X,
            Value.Y
        }
    end,

    function(Value)
        AssertArray(Value, 'Vector2', 2)

        return Vector2.new(
            Value[1],
            Value[2]
        )
    end
)

RegisterBuiltInType(
    'Vector3',

    function(Value)
        return {
            Value.X,
            Value.Y,
            Value.Z
        }
    end,

    function(Value)
        AssertArray(Value, 'Vector3', 3)

        return Vector3.new(
            Value[1],
            Value[2],
            Value[3]
        )
    end
)

RegisterBuiltInType(
    'Vector2int16',

    function(Value)
        return {
            Value.X,
            Value.Y
        }
    end,

    function(Value)
        AssertArray(Value, 'Vector2int16', 2)

        return Vector2int16.new(
            Value[1],
            Value[2]
        )
    end
)

RegisterBuiltInType(
    'Vector3int16',

    function(Value)
        return {
            Value.X,
            Value.Y,
            Value.Z
        }
    end,

    function(Value)
        AssertArray(Value, 'Vector3int16', 3)

        return Vector3int16.new(
            Value[1],
            Value[2],
            Value[3]
        )
    end
)

RegisterBuiltInType(
    'CFrame',

    function(Value)
        return {
            Value:GetComponents()
        }
    end,

    function(Value)
        AssertArray(Value, 'CFrame', 12)

        return CFrame.new(
            table.unpack(Value)
        )
    end
)

RegisterBuiltInType(
    'Color3',

    function(Value)
        return {
            Value.R,
            Value.G,
            Value.B
        }
    end,

    function(Value)
        AssertArray(Value, 'Color3', 3)

        return Color3.new(
            Value[1],
            Value[2],
            Value[3]
        )
    end
)

RegisterBuiltInType(
    'BrickColor',

    function(Value)
        return Value.Number
    end,

    function(Value)
        AssertNumber(Value, 'BrickColor')

        return BrickColor.new(Value)
    end
)

RegisterBuiltInType(
    'UDim',

    function(Value)
        return {
            Value.Scale,
            Value.Offset
        }
    end,

    function(Value)
        AssertArray(Value, 'UDim', 2)

        return UDim.new(
            Value[1],
            Value[2]
        )
    end
)

RegisterBuiltInType(
    'UDim2',

    function(Value)
        return {
            Value.X.Scale,
            Value.X.Offset,
            Value.Y.Scale,
            Value.Y.Offset
        }
    end,

    function(Value)
        AssertArray(Value, 'UDim2', 4)

        return UDim2.new(
            Value[1],
            Value[2],
            Value[3],
            Value[4]
        )
    end
)

RegisterBuiltInType(
    'NumberRange',

    function(Value)
        return {
            Value.Min,
            Value.Max
        }
    end,

    function(Value)
        AssertArray(Value, 'NumberRange', 2)

        return NumberRange.new(
            Value[1],
            Value[2]
        )
    end
)

RegisterBuiltInType(
    'Rect',

    function(Value)
        return {
            Value.Min.X,
            Value.Min.Y,
            Value.Max.X,
            Value.Max.Y
        }
    end,

    function(Value)
        AssertArray(Value, 'Rect', 4)

        return Rect.new(
            Vector2.new(
                Value[1],
                Value[2]
            ),
            Vector2.new(
                Value[3],
                Value[4]
            )
        )
    end
)

RegisterBuiltInType(
    'Region3',

    function(Value)
        local HalfSize = Value.Size / 2
        local Position = Value.CFrame.Position

        return {
            Position.X - HalfSize.X,
            Position.Y - HalfSize.Y,
            Position.Z - HalfSize.Z,
            Position.X + HalfSize.X,
            Position.Y + HalfSize.Y,
            Position.Z + HalfSize.Z
        }
    end,

    function(Value)
        AssertArray(Value, 'Region3', 6)

        return Region3.new(
            Vector3.new(
                Value[1],
                Value[2],
                Value[3]
            ),
            Vector3.new(
                Value[4],
                Value[5],
                Value[6]
            )
        )
    end
)

RegisterBuiltInType(
    'Region3int16',

    function(Value)
        return {
            Value.Min.X,
            Value.Min.Y,
            Value.Min.Z,
            Value.Max.X,
            Value.Max.Y,
            Value.Max.Z
        }
    end,

    function(Value)
        AssertArray(Value, 'Region3int16', 6)

        return Region3int16.new(
            Vector3int16.new(
                Value[1],
                Value[2],
                Value[3]
            ),
            Vector3int16.new(
                Value[4],
                Value[5],
                Value[6]
            )
        )
    end
)

RegisterBuiltInType(
    'Ray',

    function(Value)
        return {
            Value.Origin.X,
            Value.Origin.Y,
            Value.Origin.Z,
            Value.Direction.X,
            Value.Direction.Y,
            Value.Direction.Z
        }
    end,

    function(Value)
        AssertArray(Value, 'Ray', 6)

        return Ray.new(
            Vector3.new(
                Value[1],
                Value[2],
                Value[3]
            ),
            Vector3.new(
                Value[4],
                Value[5],
                Value[6]
            )
        )
    end
)

RegisterBuiltInType(
    'ColorSequence',

    function(Value)
        local Keypoints = {}

        for Index, Keypoint in ipairs(Value.Keypoints) do
            Keypoints[Index] = {
                Keypoint.Time,
                Keypoint.Value.R,
                Keypoint.Value.G,
                Keypoint.Value.B
            }
        end

        return Keypoints
    end,

    function(Value)
        if typeof(Value) ~= 'table' then
            error('ColorSequence data must be a table', 0)
        end

        local Keypoints = {}

        for Index, Keypoint in ipairs(Value) do
            AssertArray(
                Keypoint,
                'ColorSequence keypoint',
                4
            )

            Keypoints[Index] = ColorSequenceKeypoint.new(
                Keypoint[1],
                Color3.new(
                    Keypoint[2],
                    Keypoint[3],
                    Keypoint[4]
                )
            )
        end

        return ColorSequence.new(Keypoints)
    end
)

RegisterBuiltInType(
    'NumberSequence',

    function(Value)
        local Keypoints = {}

        for Index, Keypoint in ipairs(Value.Keypoints) do
            Keypoints[Index] = {
                Keypoint.Time,
                Keypoint.Value,
                Keypoint.Envelope
            }
        end

        return Keypoints
    end,

    function(Value)
        if typeof(Value) ~= 'table' then
            error('NumberSequence data must be a table', 0)
        end

        local Keypoints = {}

        for Index, Keypoint in ipairs(Value) do
            AssertArray(
                Keypoint,
                'NumberSequence keypoint',
                3
            )

            Keypoints[Index] = NumberSequenceKeypoint.new(
                Keypoint[1],
                Keypoint[2],
                Keypoint[3]
            )
        end

        return NumberSequence.new(Keypoints)
    end
)

RegisterBuiltInType(
    'PhysicalProperties',

    function(Value)
        return {
            Value.Density,
            Value.Friction,
            Value.Elasticity,
            Value.FrictionWeight,
            Value.ElasticityWeight
        }
    end,

    function(Value)
        AssertArray(Value, 'PhysicalProperties', 5)

        return PhysicalProperties.new(
            Value[1],
            Value[2],
            Value[3],
            Value[4],
            Value[5]
        )
    end
)

RegisterBuiltInType(
    'TweenInfo',

    function(Value)
        return {
            Value.Time,
            Value.EasingStyle.Name,
            Value.EasingDirection.Name,
            Value.RepeatCount,
            Value.Reverses,
            Value.DelayTime
        }
    end,

    function(Value)
        AssertArray(Value, 'TweenInfo', 6)

        local EasingStyle = Enum.EasingStyle[Value[2]]
        local EasingDirection = Enum.EasingDirection[Value[3]]

        if not EasingStyle then
            error(
                'Invalid TweenInfo EasingStyle: ' ..
                tostring(Value[2]),
                0
            )
        end

        if not EasingDirection then
            error(
                'Invalid TweenInfo EasingDirection: ' ..
                tostring(Value[3]),
                0
            )
        end

        return TweenInfo.new(
            Value[1],
            EasingStyle,
            EasingDirection,
            Value[4],
            Value[5],
            Value[6]
        )
    end
)

RegisterBuiltInType(
    'EnumItem',

    function(Value)
        return {
            Value.EnumType.Name,
            Value.Name
        }
    end,

    function(Value)
        AssertArray(Value, 'EnumItem', 2)

        local EnumType = Enum[Value[1]]

        if not EnumType then
            error(
                'Unknown enum type: ' ..
                tostring(Value[1]),
                0
            )
        end

        local EnumItem = EnumType[Value[2]]

        if not EnumItem then
            error(
                string.format(
                    'Unknown enum item: %s.%s',
                    Value[1],
                    Value[2]
                ),
                0
            )
        end

        return EnumItem
    end
)

RegisterBuiltInType(
    'Font',

    function(Value)
        return {
            Value.Family,
            Value.Weight.Name,
            Value.Style.Name
        }
    end,

    function(Value)
        AssertArray(Value, 'Font', 3)

        local Weight = Enum.FontWeight[Value[2]]
        local Style = Enum.FontStyle[Value[3]]

        if not Weight then
            error(
                'Invalid FontWeight: ' ..
                tostring(Value[2]),
                0
            )
        end

        if not Style then
            error(
                'Invalid FontStyle: ' ..
                tostring(Value[3]),
                0
            )
        end

        return Font.new(
            Value[1],
            Weight,
            Style
        )
    end
)

RegisterBuiltInType(
    'DateTime',

    function(Value)
        return Value.UnixTimestampMillis
    end,

    function(Value)
        AssertNumber(
            Value,
            'DateTime timestamp'
        )

        return DateTime.fromUnixTimestampMillis(Value)
    end
)

local function SerializeNumber(Value)
    if Value ~= Value then
        return {
            [TYPE_KEY] = 'Number',
            Value = 'NaN'
        }
    end

    if Value == math.huge then
        return {
            [TYPE_KEY] = 'Number',
            Value = 'Infinity'
        }
    end

    if Value == -math.huge then
        return {
            [TYPE_KEY] = 'Number',
            Value = '-Infinity'
        }
    end

    return Value
end

local function DeserializeNumber(Value)
    if typeof(Value) ~= 'table' then
        error(
            'Invalid serialized number',
            0
        )
    end

    if Value.Value == 'NaN' then
        return 0 / 0
    end

    if Value.Value == 'Infinity' then
        return math.huge
    end

    if Value.Value == '-Infinity' then
        return -math.huge
    end

    error(
        'Invalid special number value: ' ..
        tostring(Value.Value),
        0
    )
end

local function SerializeValue(Value, State, Depth)
    if Depth > State.MaxDepth then
        error(
            string.format(
                'Maximum serialization depth exceeded: %d',
                State.MaxDepth
            ),
            0
        )
    end

    local ValueType = typeof(Value)

    if ValueType == 'nil' then
        return {
            [TYPE_KEY] = 'Nil'
        }
    end

    if ValueType == 'boolean'
        or ValueType == 'string' then

        return Value
    end

    if ValueType == 'number' then
        return SerializeNumber(Value)
    end

    if ValueType == 'table' then
        local ExistingID = State.SerializedTables[Value]

        if ExistingID then
            return {
                [TYPE_KEY] = 'Reference',
                ID = ExistingID
            }
        end

        State.NextID += 1

        local ID = State.NextID

        State.SerializedTables[Value] = ID

        local Entries = {}

        for Key, TableValue in pairs(Value) do
            Entries[#Entries + 1] = {
                Key = SerializeValue(
                    Key,
                    State,
                    Depth + 1
                ),

                Value = SerializeValue(
                    TableValue,
                    State,
                    Depth + 1
                )
            }
        end

        return {
            [TYPE_KEY] = 'Table',
            ID = ID,
            Entries = Entries
        }
    end

    local TypeHandler = TypeHandlers[ValueType]

    if TypeHandler then
        local Success, SerializedValue = pcall(
            TypeHandler.Serialize,
            Value
        )

        if not Success then
            error(
                string.format(
                    'Failed to serialize %s: %s',
                    ValueType,
                    tostring(SerializedValue)
                ),
                0
            )
        end

        return {
            [TYPE_KEY] = ValueType,
            Value = SerializedValue
        }
    end

    error(
        string.format(
            'Unsupported data type: %s',
            ValueType
        ),
        0
    )
end

local function DeserializeValue(Value, State, Depth)
    if Depth > State.MaxDepth then
        error(
            string.format(
                'Maximum deserialization depth exceeded: %d',
                State.MaxDepth
            ),
            0
        )
    end

    if typeof(Value) ~= 'table' then
        return Value
    end

    local Type = Value[TYPE_KEY]

    if Type == 'Nil' then
        return nil
    end

    if Type == 'Number' then
        return DeserializeNumber(Value)
    end

    if Type == 'Reference' then
        if typeof(Value.ID) ~= 'number'
            or Value.ID < 1
            or Value.ID % 1 ~= 0 then

            error(
                'Invalid table reference ID',
                0
            )
        end

        local ReferencedTable = State.Tables[Value.ID]

        if not ReferencedTable then
            error(
                string.format(
                    'Missing table reference: %d',
                    Value.ID
                ),
                0
            )
        end

        return ReferencedTable
    end

    if Type == 'Table' then
        if typeof(Value.ID) ~= 'number'
            or Value.ID < 1
            or Value.ID % 1 ~= 0 then

            error(
                'Invalid serialized table ID',
                0
            )
        end

        if typeof(Value.Entries) ~= 'table' then
            error(
                'Invalid serialized table entries',
                0
            )
        end

        local ExistingTable = State.Tables[Value.ID]

        if ExistingTable then
            return ExistingTable
        end

        local Result = {}

        State.Tables[Value.ID] = Result

        for Index, Entry in ipairs(Value.Entries) do
            if typeof(Entry) ~= 'table' then
                error(
                    string.format(
                        'Invalid table entry at index %d',
                        Index
                    ),
                    0
                )
            end

            if Entry.Key == nil then
                error(
                    string.format(
                        'Table entry %d is missing Key',
                        Index
                    ),
                    0
                )
            end

            if Entry.Value == nil then
                error(
                    string.format(
                        'Table entry %d is missing Value',
                        Index
                    ),
                    0
                )
            end

            local Key = DeserializeValue(
                Entry.Key,
                State,
                Depth + 1
            )

            if Key == nil then
                error(
                    string.format(
                        'Table entry %d contains a nil key',
                        Index
                    ),
                    0
                )
            end

            local TableValue = DeserializeValue(
                Entry.Value,
                State,
                Depth + 1
            )

            Result[Key] = TableValue
        end

        return Result
    end

    if typeof(Type) ~= 'string' then
        error(
            'Serialized value is missing __Type',
            0
        )
    end

    local TypeHandler = TypeHandlers[Type]

    if not TypeHandler then
        error(
            'Unknown serialized type: ' .. Type,
            0
        )
    end

    if Value.Value == nil then
        error(
            'Serialized value is missing Value for type: ' ..
            Type,
            0
        )
    end

    local Success, Result = pcall(
        TypeHandler.Deserialize,
        Value.Value
    )

    if not Success then
        error(
            string.format(
                'Failed to deserialize %s: %s',
                Type,
                tostring(Result)
            ),
            0
        )
    end

    return Result
end

function Serializer:RegisterType(
    TypeName,
    Serialize,
    Deserialize
)
    assert(
        typeof(TypeName) == 'string'
            and TypeName ~= '',
        'TypeName must be a non-empty string'
    )

    assert(
        typeof(Serialize) == 'function',
        'Serialize must be a function'
    )

    assert(
        typeof(Deserialize) == 'function',
        'Deserialize must be a function'
    )

    if TypeHandlers[TypeName] then
        error(
            'Serializer type already exists: ' ..
            TypeName,
            2
        )
    end

    if TypeName == 'Table'
        or TypeName == 'Reference'
        or TypeName == 'Nil'
        or TypeName == 'Number' then

        error(
            'Reserved serializer type: ' ..
            TypeName,
            2
        )
    end

    TypeHandlers[TypeName] = CreateTypeHandler(
        Serialize,
        Deserialize
    )
end

function Serializer:GetVersion()
    return SERIALIZATION_VERSION
end

function Serializer:Serialize(
    Value,
    MaxDepth
)
    MaxDepth = MaxDepth or DEFAULT_MAX_DEPTH

    assert(
        typeof(MaxDepth) == 'number'
            and MaxDepth >= 1
            and MaxDepth % 1 == 0,
        'MaxDepth must be a positive integer'
    )

    return {
        [VERSION_KEY] = SERIALIZATION_VERSION,

        [DATA_KEY] = SerializeValue(
            Value,
            {
                SerializedTables = {},
                NextID = 0,
                MaxDepth = MaxDepth
            },
            0
        )
    }
end

function Serializer:Deserialize(
    Value,
    MaxDepth
)
    MaxDepth = MaxDepth or DEFAULT_MAX_DEPTH

    assert(
        typeof(MaxDepth) == 'number'
            and MaxDepth >= 1
            and MaxDepth % 1 == 0,
        'MaxDepth must be a positive integer'
    )

    if typeof(Value) ~= 'table' then
        error(
            'Serialized data must be a table',
            2
        )
    end

    if Value[VERSION_KEY] ~= SERIALIZATION_VERSION then
        error(
            string.format(
                'Unsupported serialization version: %s',
                tostring(Value[VERSION_KEY])
            ),
            2
        )
    end

    if Value[DATA_KEY] == nil then
        error(
            'Serialized data is missing Data',
            2
        )
    end

    return DeserializeValue(
        Value[DATA_KEY],
        {
            Tables = {},
            MaxDepth = MaxDepth
        },
        0
    )
end

function Serializer:Encode(
    Value,
    MaxDepth
)
    local SerializedData = self:Serialize(
        Value,
        MaxDepth
    )

    local Success, Result = pcall(
        HttpService.JSONEncode,
        HttpService,
        SerializedData
    )

    if not Success then
        error(
            'Failed to encode serialized data: ' ..
            tostring(Result),
            2
        )
    end

    return Result
end

function Serializer:Decode(
    Value,
    MaxDepth
)
    if typeof(Value) ~= 'string' then
        error(
            'Encoded data must be a string',
            2
        )
    end

    local Success, SerializedData = pcall(
        HttpService.JSONDecode,
        HttpService,
        Value
    )

    if not Success then
        error(
            'Failed to decode JSON: ' ..
            tostring(SerializedData),
            2
        )
    end

    return self:Deserialize(
        SerializedData,
        MaxDepth
    )
end

return Serializer
