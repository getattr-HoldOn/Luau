--[[
    Serializer

    Convert supported values to a storable format and restore them later.

    Serialize:
        local SerializedData = Serializer:Serialize(Data)

    Deserialize:
        local Data = Serializer:Deserialize(SerializedData)

    JSON:
        local JsonText = Serializer:Encode(Data)
        local Data = Serializer:Decode(JsonText)

    Supports nested tables, cyclic tables, shared references,
    special numbers, and common Roblox datatypes.
]]

export type SerializerOptions = {
  MaxDepth: number?,
  MaxDecodeFrames: number?,
  MaxTables: number?,
  MaxEntries: number?,
  MaxNodes: number?,
  MaxTypedObjects: number?,
  MaxStringLength: number?,
  MaxTotalStringBytes: number?,
  MaxBufferBytes: number?,
  MaxBytes: number?,
}

export type SerializerAPI = {
  Serialize: (self: any, Value: any, Options: (number | SerializerOptions)?) -> any,
  Deserialize: (self: any, Snapshot: any, Options: (number | SerializerOptions)?) -> any,
  Encode: (self: any, Value: any, Options: (number | SerializerOptions)?) -> string,
  Decode: (self: any, JsonText: string, Options: (number | SerializerOptions)?) -> any,
  Upgrade: (self: any, Snapshot: any, Options: (number | SerializerOptions)?) -> any,
  RegisterType: (self: any, Name: string, Serialize: (any) -> any, Deserialize: (any, number) -> any, Predicate: ((any) -> boolean)?, SourceType: string?, SchemaVersion: number?) -> (),
  RegisterVersionDecoder: (self: any, Version: number, Decoder: (any, any) -> any) -> (),
  GetVersion: (self: any) -> number,
}

type ResolvedOptions = {
  MaxDepth: number,
  MaxDecodeFrames: number,
  MaxTables: number,
  MaxEntries: number,
  MaxNodes: number,
  MaxTypedObjects: number,
  MaxStringLength: number,
  MaxTotalStringBytes: number,
  MaxBufferBytes: number,
  MaxBytes: number,
}

type TypeHandler = {
  Serialize: (any) -> any,
  Deserialize: (any, number) -> any,
  Predicate: ((any) -> boolean)?,
  SchemaVersion: number,
}

type CapturedNode = {
  Kind: string,
  Name: string?,
  SchemaVersion: number?,
  Payload: any?,
  Entries: { any }?,
  ReferenceCount: number,
}

type CounterState = {
  Options: ResolvedOptions,
  Nodes: number,
  Tables: number,
  Entries: number,
  TypedObjects: number,
  TotalStringBytes: number,
  MaxEncodedBytes: number?,
}

local HttpService = game:GetService('HttpService')
local Serializer = {}

local SerializationVersion = 4
local DefaultOptions = {
  MaxDepth = 64,
  MaxDecodeFrames = 512,
  MaxTables = 30000,
  MaxEntries = 150000,
  MaxNodes = 300000,
  MaxTypedObjects = 300000,
  MaxStringLength = 2000000,
  MaxTotalStringBytes = 4000000,
  MaxBufferBytes = 1000000,
  MaxBytes = 4000000,
}

local TypeHandlers = {}
local PredicateHandlers = {}
local PredicateDispatchCache = {}
local VersionDecoders = {}

local ReservedTypeNames = {
  table = true,
  number = true,
  string = true,
  boolean = true,
  ['nil'] = true,
  Table = true,
  Reference = true,
  Nil = true,
  Number = true,
}

local NumericArrayLengths = {
  Vector2 = 2,
  Vector3 = 3,
  Vector2int16 = 2,
  Vector3int16 = 3,
  CFrame = 12,
  Color3 = 3,
  UDim = 2,
  UDim2 = 4,
  NumberRange = 2,
  Rect = 4,
  Region3 = 6,
  Region3int16 = 6,
  Ray = 6,
  PhysicalProperties = 5,
}

local function Fail(Message)
  error('Serializer: ' .. Message, 0)
end

local function IsPositiveInteger(Value)
  return typeof(Value) == 'number'
    and Value >= 1
    and Value < math.huge
    and Value % 1 == 0
end

local function ResolveOptions(Options)
  if Options == nil then
    Options = {}
  end

  if typeof(Options) == 'number' then
    Options = { MaxDepth = Options }
  end

  if typeof(Options) ~= 'table' then
    Fail('options must be a table or positive MaxDepth integer')
  end

  local Result = {}

  for Key, Default in pairs(DefaultOptions) do
    local Value = Options[Key]

    if Value == nil then
      Value = Default
    end

    if not IsPositiveInteger(Value) then
      Fail(Key .. ' must be a positive finite integer')
    end

    if Key == 'MaxDepth' and Value > 256 then
      Fail('MaxDepth cannot exceed hard recursion cap (256)')
    end

    if Key == 'MaxDecodeFrames' and Value > 512 then
      Fail('MaxDecodeFrames cannot exceed hard recursion cap (512)')
    end

    Result[Key] = Value
  end

  for Key in pairs(Options) do
    if DefaultOptions[Key] == nil then
      Fail('unknown option: ' .. tostring(Key))
    end
  end

  return Result
end

local function DenseLength(Value, Name)
  if typeof(Value) ~= 'table' then
    Fail(Name .. ' must be an array')
  end

  local Count = 0

  for Key in pairs(Value) do
    if not IsPositiveInteger(Key) then
      Fail(Name .. ' has a non-array key')
    end

    Count += 1
  end

  for Index = 1, Count do
    if rawget(Value, Index) == nil then
      Fail(Name .. ' has a hole at ' .. Index)
    end
  end

  return Count
end

local function AssertArray(Value, Name, Length)
  local Count = DenseLength(Value, Name)

  if Length ~= nil and Count ~= Length then
    Fail(string.format('%s needs %d values, got %d', Name, Length, Count))
  end
end

local function AssertNumber(Value, Name)
  if typeof(Value) ~= 'number' then
    Fail(Name .. ' must be a number')
  end
end

local function AssertFiniteNumber(Value, Name)
  AssertNumber(Value, Name)
  if Value ~= Value or Value == math.huge or Value == -math.huge then
    Fail(Name .. ' must be finite')
  end
end

local function AssertString(Value, Name)
  if typeof(Value) ~= 'string' then
    Fail(Name .. ' must be a string')
  end
end

local function AssertNumericArray(Value, Name, Length)
  AssertArray(Value, Name, Length)
  for Index = 1, Length do
    AssertNumber(Value[Index], Name .. '[' .. Index .. ']')
  end
end

local function CreateTypeHandler(Serialize, Deserialize, Predicate, SchemaVersion)
  return {
    Serialize = Serialize,
    Deserialize = Deserialize,
    Predicate = Predicate,
    SchemaVersion = SchemaVersion or 1,
  }
end

local function RegisterBuiltInType(TypeName, Serialize, Deserialize)
  local RequiredLength = NumericArrayLengths[TypeName]

  if RequiredLength ~= nil then
    local OriginalDeserializer = Deserialize
    Deserialize = function(Value)
      AssertNumericArray(Value, TypeName, RequiredLength)
      return OriginalDeserializer(Value)
    end
  end
  TypeHandlers[TypeName] = CreateTypeHandler(Serialize, Deserialize, nil)
end

RegisterBuiltInType(
  'Vector2',

  function(Value)
    return {
      Value.X,
      Value.Y,
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
      Value.Z,
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
      Value.Y,
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
      Value.Z,
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
      Value:GetComponents(),
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
      Value.B,
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
      Value.Offset,
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
      Value.Y.Offset,
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
      Value.Max,
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
      Value.Max.Y,
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
      Position.Z + HalfSize.Z,
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
      Value.Max.Z,
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
      Value.Direction.Z,
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
        Keypoint.Value.B,
      }
    end

    return Keypoints
  end,

  function(Value)
    AssertArray(Value, 'ColorSequence')

    local Keypoints = {}

    for Index, Keypoint in ipairs(Value) do
      AssertArray(
        Keypoint,
        'ColorSequence keypoint',
        4
      )

      AssertNumericArray(Keypoint, 'ColorSequence keypoint', 4)
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
        Keypoint.Envelope,
      }
    end

    return Keypoints
  end,

  function(Value)
    AssertArray(Value, 'NumberSequence')

    local Keypoints = {}

    for Index, Keypoint in ipairs(Value) do
      AssertArray(
        Keypoint,
        'NumberSequence keypoint',
        3
      )

      AssertNumericArray(Keypoint, 'NumberSequence keypoint', 3)
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
      Value.ElasticityWeight,
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
      Value.DelayTime,
    }
  end,

  function(Value)
    AssertArray(Value, 'TweenInfo', 6)

    AssertFiniteNumber(Value[1], 'TweenInfo Time')
    AssertFiniteNumber(Value[4], 'TweenInfo RepeatCount')
    AssertFiniteNumber(Value[6], 'TweenInfo DelayTime')
    AssertString(Value[2], 'TweenInfo EasingStyle')
    AssertString(Value[3], 'TweenInfo EasingDirection')

    if typeof(Value[5]) ~= 'boolean' then
      Fail('TweenInfo Reverses must be a boolean')
    end

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
      Value.Name,
    }
  end,

  function(Value)
    AssertArray(Value, 'EnumItem', 2)

    AssertString(Value[1], 'EnumItem enum type')
    AssertString(Value[2], 'EnumItem name')

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
    local Family = Value.Family

    if typeof(Family) == 'Content' then
      if Family.SourceType ~= Enum.ContentSourceType.Uri then
        Fail('Font Family must contain a URI')
      end
      Family = Family.Uri
    end

    AssertString(Family, 'Font Family')

    return {
      Family,
      Value.Weight.Name,
      Value.Style.Name,
    }
  end,

  function(Value)
    AssertArray(Value, 'Font', 3)

    AssertString(Value[2], 'Font Weight')
    AssertString(Value[3], 'Font Style')

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

    local Family = Value[1]

    if typeof(Family) == 'Content' then
      if Family.SourceType ~= Enum.ContentSourceType.Uri then
        Fail('Font Family must contain a URI')
      end
      Family = Family.Uri
    elseif typeof(Family) ~= 'string' then
      Fail('Font Family must be a Content URI or legacy string')
    end

    AssertString(Family, 'Font Family')

    local Success, Result = pcall(Font.new, Family, Weight, Style)

    if Success then
      return Result
    end

    if Content ~= nil then
      local ContentSuccess, ContentFamily = pcall(Content.fromUri, Family)

      if ContentSuccess then
        local FontSuccess, ContentFont = pcall(Font.new, ContentFamily, Weight, Style)

        if FontSuccess then
          return ContentFont
        end
      end
    end

    error(Result, 0)
  end
)

RegisterBuiltInType(
  'DateTime',

  function(Value)
    return Value.UnixTimestampMillis
  end,

  function(Value)
    AssertFiniteNumber(
      Value,
      'DateTime timestamp'
    )

    if Value % 1 ~= 0 or Value < -17987443200000 or Value > 253402300799999 then
      Fail('DateTime timestamp is outside the supported millisecond range')
    end

    return DateTime.fromUnixTimestampMillis(Value)
  end
)

RegisterBuiltInType(
  'Content',

  function(Value)
    if Value.SourceType == Enum.ContentSourceType.None then
      return { 'None' }
    end

    if Value.SourceType == Enum.ContentSourceType.Uri then
      AssertString(Value.Uri, 'Content URI')
      return { 'Uri', Value.Uri }
    end

    Fail('Content with an object or opaque source cannot be serialized')
  end,

  function(Value)
    local Count = DenseLength(Value, 'Content')

    if Count == 1 and Value[1] == 'None' then
      return Content.none
    end

    if Count == 2 and Value[1] == 'Uri' then
      AssertString(Value[2], 'Content URI')
      return Content.fromUri(Value[2])
    end

    Fail('invalid Content payload')
  end
)

RegisterBuiltInType(
  'buffer',
  function(Value)
    local Encoded = game:GetService('EncodingService'):Base64Encode(Value)

    return buffer.tostring(Encoded)
  end,
  function(Value)
    AssertString(Value, 'buffer payload')
    return game:GetService('EncodingService'):Base64Decode(buffer.fromstring(Value))
  end
)

local function Touch(State: CounterState, Depth: number)
  if Depth > State.Options.MaxDepth then
    Fail('maximum depth exceeded: ' .. State.Options.MaxDepth)
  end

  State.Nodes += 1

  if State.Nodes > State.Options.MaxNodes then
    Fail('maximum node visits exceeded')
  end
end

local function CheckStringBudget(State: CounterState, Value: string)
  if #Value > State.Options.MaxStringLength then
    Fail('string exceeds MaxStringLength')
  end

  State.TotalStringBytes += #Value

  if State.TotalStringBytes > State.Options.MaxTotalStringBytes then
    Fail('total strings exceed MaxTotalStringBytes')
  end

  if State.MaxEncodedBytes ~= nil and State.TotalStringBytes > State.MaxEncodedBytes then
    Fail('JSON exceeds MaxBytes')
  end
end

local function CountEntry(State: CounterState)
  State.Entries += 1

  if State.Entries > State.Options.MaxEntries then
    Fail('maximum table entries exceeded')
  end
end

local function CountTable(State: CounterState)
  State.Tables += 1

  if State.Tables > State.Options.MaxTables then
    Fail('maximum table count exceeded')
  end
end

local function CountTypedObject(State: CounterState)
  State.TypedObjects += 1

  if State.TypedObjects > State.Options.MaxTypedObjects then
    Fail('maximum typed object count exceeded')
  end
end

local function MatchHandler(Value, ValueType, SkipHandlerName)
  local Candidates = PredicateDispatchCache[ValueType]

  if Candidates == nil then
    Candidates = {}

    for _, Candidate in ipairs(PredicateHandlers) do
      if Candidate.SourceType == nil or Candidate.SourceType == ValueType then
        Candidates[#Candidates + 1] = Candidate
      end
    end

    PredicateDispatchCache[ValueType] = Candidates
  end

  for _, Candidate in ipairs(Candidates) do
    if Candidate.Name == SkipHandlerName then
      continue
    end

    local Success, Matched = pcall(Candidate.Predicate, Value)

    if not Success then
      Fail('custom type predicate failed: ' .. tostring(Matched))
    end

    if Matched then
      return Candidate.Name, Candidate.Handler
    end
  end

  return nil, nil
end

local function CallSerialize(Handler, Name, Value)
  local Success, Payload = pcall(Handler.Serialize, Value)

  if not Success then
    Fail('failed to serialize ' .. Name .. ': ' .. tostring(Payload))
  end

  if Payload == nil then
    Fail('serializer for ' .. Name .. ' returned nil payload')
  end

  return Payload
end

local Capture

local function CaptureTyped(Value, Name, Handler, State, Depth)
  CountTypedObject(State)
  CheckStringBudget(State, Name)

  local Node = {
    Kind = 'Typed',
    Name = Name,
    SchemaVersion = Handler.SchemaVersion,
    Payload = nil,
    ReferenceCount = 1,
  }

  State.Seen[Value] = Node
  State.ActiveTyped[Value] = true

  local PreviousTypedCaptureStart = State.TypedCaptureStart
  State.TypedCaptureStart = State.CaptureOrder
  local Payload = CallSerialize(Handler, Name, Value)
  Node.Payload = Capture(Payload, State, Depth + 1, Name)
  State.TypedCaptureStart = PreviousTypedCaptureStart
  State.ActiveTyped[Value] = nil
  return Node
end

Capture = function(Value, State, Depth, SkipHandlerName)
  Touch(State, Depth)
  local ValueType = typeof(Value)

  if ValueType == 'nil' or ValueType == 'boolean' then
    return Value
  end

  if ValueType == 'string' then
    CheckStringBudget(State, Value)
    return Value
  end

  if ValueType == 'number' then
    return Value
  end

  local ExistingNode = State.Seen[Value]

  if ExistingNode ~= nil then
    State.HasReferences = true
    local ActiveTableOrder = State.ActiveTables[Value]

    if ActiveTableOrder ~= nil
      and State.TypedCaptureStart ~= nil
      and ActiveTableOrder <= State.TypedCaptureStart
    then
      Fail('custom-type payload references an incomplete table')
    end

    if State.ActiveTyped[Value] then
      Fail('cyclic custom-type payload cannot reconstruct its own object')
    end

    ExistingNode.ReferenceCount += 1
    return ExistingNode
  end

  if ValueType == 'buffer' and buffer.len(Value) > State.Options.MaxBufferBytes then
    Fail('buffer exceeds MaxBufferBytes')
  end

  local CustomName, CustomHandler = MatchHandler(Value, ValueType, SkipHandlerName)

  if CustomName ~= nil then
    return CaptureTyped(Value, CustomName, CustomHandler, State, Depth)
  end

  if ValueType == 'table' then
    CountTable(State)
    local Node = {
      Kind = 'Table',
      Entries = {},
      ReferenceCount = 1,
    }
    State.Seen[Value] = Node
    State.CaptureOrder += 1
    State.ActiveTables[Value] = State.CaptureOrder

    local CapturedEntries = Node.Entries

    for Key, Item in pairs(Value) do
      CountEntry(State)
      CapturedEntries[#CapturedEntries + 1] = Capture(Key, State, Depth + 1)
      CapturedEntries[#CapturedEntries + 1] = Capture(Item, State, Depth + 1)
    end

    State.ActiveTables[Value] = nil

    return Node
  end

  local Handler = TypeHandlers[ValueType]

  if Handler ~= nil then
    return CaptureTyped(Value, ValueType, Handler, State, Depth)
  end
  Fail('unsupported value type: ' .. ValueType)
end

local PrimitiveKeyRanks = {
  boolean = 1,
  number = 2,
  string = 3,
}

local function OrderedEntryIndices(Entries)
  local EntryCount = #Entries / 2

  for Index = 1, #Entries, 2 do
    local KeyType = typeof(Entries[Index])

    if PrimitiveKeyRanks[KeyType] == nil then
      return nil
    end
  end

  local Indices = table.create(EntryCount)

  for Index = 1, EntryCount do
    Indices[Index] = Index
  end

  table.sort(Indices, function(FirstIndex, SecondIndex)
    local FirstKey = Entries[FirstIndex * 2 - 1]
    local SecondKey = Entries[SecondIndex * 2 - 1]
    local FirstType = typeof(FirstKey)
    local SecondType = typeof(SecondKey)

    if FirstType ~= SecondType then
      return PrimitiveKeyRanks[FirstType] < PrimitiveKeyRanks[SecondType]
    end

    if FirstType == 'boolean' then
      return not FirstKey and SecondKey
    end

    return FirstKey < SecondKey
  end)

  return Indices
end

local function TableKind(Entries)
  local EntryCount = #Entries / 2

  if EntryCount == 0 then
    return 'a'
  end

  local AllStringKeys = true
  local AllArrayKeys = true

  for Index = 1, #Entries, 2 do
    local Key = Entries[Index]

    if typeof(Key) ~= 'string' then
      AllStringKeys = false
    end

    if not IsPositiveInteger(Key) or Key > EntryCount then
      AllArrayKeys = false
    end
  end

  if AllArrayKeys then
    return 'a'
  end

  if AllStringKeys then
    return 'o'
  end

  return 'm'
end

local EncodeNode

local function EncodeTableContent(Node, State)
  local Entries = Node.Entries
  local Kind = TableKind(Entries)

  if Kind == 'a' or Kind == 'o' then
    local Data = {}

    for Index = 1, #Entries, 2 do
      Data[Entries[Index]] = EncodeNode(Entries[Index + 1], State)
    end

    return Kind, Data
  end

  local Data = {}
  local SortedIndices = OrderedEntryIndices(Entries)

  if SortedIndices ~= nil then
    for _, EntryIndex in ipairs(SortedIndices) do
      local KeyIndex = EntryIndex * 2 - 1
      Data[#Data + 1] = {
        EncodeNode(Entries[KeyIndex], State),
        EncodeNode(Entries[KeyIndex + 1], State),
      }
    end
  else
    for Index = 1, #Entries, 2 do
      Data[#Data + 1] = {
        EncodeNode(Entries[Index], State),
        EncodeNode(Entries[Index + 1], State),
      }
    end
  end

  return Kind, Data
end

local function EncodeNodeBody(Node, State)
  if Node == nil then
    return { ['$'] = 'z' }
  end

  local NodeType = typeof(Node)

  if NodeType == 'number' then
    if Node ~= Node then
      return { ['$'] = 'x', v = 'nan' }
    end

    if Node == math.huge then
      return { ['$'] = 'x', v = '+inf' }
    end

    if Node == -math.huge then
      return { ['$'] = 'x', v = '-inf' }
    end

    return Node
  end

  if NodeType ~= 'table' then
    return Node
  end

  local IsSharedNode = Node.ReferenceCount > 1
  local ReferenceIdentifier = nil

  if IsSharedNode then
    ReferenceIdentifier = State.ReferenceIdentifiers[Node]
    if ReferenceIdentifier ~= nil then
      return { ['$'] = 'r', i = ReferenceIdentifier }
    end

    State.NextReferenceIdentifier += 1
    ReferenceIdentifier = State.NextReferenceIdentifier
    State.ReferenceIdentifiers[Node] = ReferenceIdentifier
  end

  if Node.Kind == 'Typed' then
    local Encoded = {
      ['$'] = 'u',
      n = Node.Name,
      v = EncodeNode(Node.Payload, State),
    }

    if Node.SchemaVersion > 1 then
      Encoded.s = Node.SchemaVersion
    end

    if ReferenceIdentifier ~= nil then
      Encoded.i = ReferenceIdentifier
      State.Definitions[ReferenceIdentifier] = Encoded
    end

    return Encoded
  end

  local Kind, Data = EncodeTableContent(Node, State)

  if ReferenceIdentifier ~= nil then
    local Encoded = { ['$'] = 't', i = ReferenceIdentifier, k = Kind, v = Data }
    State.Definitions[ReferenceIdentifier] = Encoded
    return Encoded
  end

  if Kind == 'm' then
    return { ['$'] = 'm', v = Data }
  end

  if Kind == 'o' and rawget(Data, '$') ~= nil then
    return { ['$'] = 'o', v = Data }
  end

  return Data
end

EncodeNode = function(Node, State)
  State.Frames += 1

  if State.Frames > State.Options.MaxDecodeFrames then
    Fail('encoding dependency chain exceeds MaxDecodeFrames')
  end

  if State.Frames - 1 > State.Options.MaxDepth then
    Fail('maximum depth exceeded: ' .. State.Options.MaxDepth)
  end

  local Result = EncodeNodeBody(Node, State)
  State.Frames -= 1
  return Result
end

local function CheckReferenceIdentifier(Value, State)
  if not IsPositiveInteger(Value) or Value > State.Options.MaxNodes then
    Fail('invalid reference ID')
  end

  return Value
end

local function CheckNewReferenceIdentifier(Value, State)
  local ReferenceIdentifier = CheckReferenceIdentifier(Value, State)

  if State.Objects[ReferenceIdentifier] ~= nil then
    Fail('duplicate object ID: ' .. ReferenceIdentifier)
  end

  return ReferenceIdentifier
end

local function OnlyFields(Node, Tag, Fields)
  for Key in pairs(Node) do
    if not Fields[Key] then
      Fail('unexpected field in ' .. Tag .. ' node: ' .. tostring(Key))
    end
  end
end

local AllowedNodeFields = {
  z = { ['$'] = true },
  x = { ['$'] = true, v = true },
  r = { ['$'] = true, i = true },
  o = { ['$'] = true, v = true },
  m = { ['$'] = true, v = true },
  t = { ['$'] = true, i = true, k = true, v = true },
  u = { ['$'] = true, n = true, i = true, s = true, v = true },
}

local InspectNode

local function InspectContent(Kind, Data, State, Depth)
  if typeof(Data) ~= 'table' then
    Fail('table payload must be a table')
  end

  if State.WireSeen[Data] then
    Fail('cyclic or reused wire container')
  end

  State.WireSeen[Data] = true
  CountTable(State)
  if Kind == 'a' then
    local Count = DenseLength(Data, 'array')

    for Index = 1, Count do
      CountEntry(State)
      Touch(State, Depth + 1)
      InspectNode(Data[Index], State, Depth + 1)
    end
  elseif Kind == 'o' then
    local Keys = {}

    for Key, Item in pairs(Data) do
      if typeof(Key) ~= 'string' then
        Fail('object has a non-string key')
      end

      Keys[#Keys + 1] = Key

      CountEntry(State)
      Touch(State, Depth + 1)
      CheckStringBudget(State, Key)
      InspectNode(Item, State, Depth + 1)
    end

    table.sort(Keys)
    State.SortedKeys[Data] = Keys
  elseif Kind == 'm' then
    local Count = DenseLength(Data, 'map entries')

    for Index = 1, Count do
      CountEntry(State)
      local Pair = Data[Index]
      AssertArray(Pair, 'map entry', 2)
      if State.WireSeen[Pair] then
        Fail('reused map entry')
      end

      State.WireSeen[Pair] = true
      InspectNode(Pair[1], State, Depth + 1)
      InspectNode(Pair[2], State, Depth + 1)
    end
  else
    Fail('invalid table kind: ' .. tostring(Kind))
  end
end

local function RegisterDefinition(Node, State, IsTable)
  local ReferenceIdentifier = CheckReferenceIdentifier(Node.i, State)

  if State.Definitions[ReferenceIdentifier] ~= nil then
    Fail('duplicate object ID: ' .. ReferenceIdentifier)
  end

  State.Definitions[ReferenceIdentifier] = Node

  if IsTable then
    State.Objects[ReferenceIdentifier] = {}
  end
end

InspectNode = function(Value, State, Depth)
  Touch(State, Depth)
  local ValueType = typeof(Value)

  if ValueType == 'string' then
    CheckStringBudget(State, Value)
    return
  end

  if ValueType == 'number' or ValueType == 'boolean' then
    return
  end

  if ValueType ~= 'table' then
    Fail('invalid wire node type: ' .. ValueType)
  end

  if State.WireSeen[Value] then
    Fail('cyclic or reused wire node')
  end

  local Tag = rawget(Value, '$')

  if Tag == nil then
    local HasNumericKeys, HasStringKeys = false, false

    for Key in pairs(Value) do
      local KeyType = typeof(Key)

      if KeyType == 'number' then
        HasNumericKeys = true
      elseif KeyType == 'string' then
        HasStringKeys = true
      else
        Fail('unsupported plain JSON object key')
      end
    end

    if HasNumericKeys and HasStringKeys then
      Fail('mixed plain JSON object keys')
    end
    InspectContent((HasNumericKeys or not HasStringKeys) and 'a' or 'o', Value, State, Depth)
    return
  end

  if typeof(Tag) ~= 'string' or AllowedNodeFields[Tag] == nil then
    Fail('unknown wire marker: ' .. tostring(Tag))
  end

  State.WireSeen[Value] = true
  OnlyFields(Value, Tag, AllowedNodeFields[Tag])
  if Tag == 'z' then
    return
  end

  if Tag == 'x' then
    if Value.v ~= 'nan' and Value.v ~= '+inf' and Value.v ~= '-inf' then
      Fail('invalid special number')
    end
    return
  end

  if Tag == 'r' then
    local ReferenceIdentifier = CheckReferenceIdentifier(Value.i, State)
    State.Referenced[ReferenceIdentifier] = true
    return
  end

  if Tag == 'o' or Tag == 'm' then
    InspectContent(Tag, Value.v, State, Depth)
    return
  end

  if Tag == 't' then
    RegisterDefinition(Value, State, true)
    InspectContent(Value.k, Value.v, State, Depth)
    return
  end

  if typeof(Value.n) ~= 'string' or Value.n == '' then
    Fail('invalid custom type name')
  end

  CheckStringBudget(State, Value.n)

  if TypeHandlers[Value.n] == nil then
    Fail('unknown serialized type: ' .. Value.n)
  end

  if Value.s ~= nil then
    if State.WireVersion < 3 then
      Fail('type schema version requires v3 snapshot')
    end

    if not IsPositiveInteger(Value.s) then
      Fail('invalid type schema version')
    end
  end

  if Value.v == nil then
    Fail('missing type payload for ' .. Value.n)
  end

  CountTypedObject(State)

  if Value.n == 'buffer' then
    if typeof(Value.v) ~= 'string'
      or #Value.v > math.ceil(State.Options.MaxBufferBytes / 3) * 4
    then
      Fail('buffer payload exceeds MaxBufferBytes or is not a string')
    end
  end

  if Value.i ~= nil then
    RegisterDefinition(Value, State, false)
  end

  InspectNode(Value.v, State, Depth + 1)
end

local function CallDeserialize(Handler, Name, Payload, SchemaVersion)
  local Success, Result = pcall(Handler.Deserialize, Payload, SchemaVersion)

  if not Success then
    Fail('failed to deserialize ' .. Name .. ': ' .. tostring(Result))
  end

  if Result == nil then
    Fail('deserializer for ' .. Name .. ' returned nil')
  end

  return Result
end

local DecodeNode
local ResolveReferenceIdentifier

local function FillContent(Result, Kind, Data, State)
  if Kind == 'a' then
    for Index = 1, #Data do
      local Item = DecodeNode(Data[Index], State)

      if Item == nil then
        Fail('array cannot contain nil')
      end

      Result[Index] = Item
    end
  elseif Kind == 'o' then
    for _, Key in ipairs(State.SortedKeys[Data]) do
      local Item = Data[Key]
      local Decoded = DecodeNode(Item, State)

      if Decoded == nil then
        Fail('object cannot contain nil')
      end

      Result[Key] = Decoded
    end
  elseif Kind == 'm' then
    for Index = 1, #Data do
      local Pair = Data[Index]
      local Key = DecodeNode(Pair[1], State)
      local Item = DecodeNode(Pair[2], State)

      if Key == nil or (typeof(Key) == 'number' and Key ~= Key) then
        Fail('invalid map key at ' .. Index)
      end

      if Item == nil then
        Fail('map cannot contain nil')
      end

      if rawget(Result, Key) ~= nil then
        Fail('duplicate map key at ' .. Index)
      end

      Result[Key] = Item
    end
  else
    Fail('invalid table kind: ' .. tostring(Kind))
  end
end

local function DecodeTyped(Node, State)
  local Name = Node.n
  local Handler = TypeHandlers[Name]
  local SchemaVersion = Node.s or 1

  if SchemaVersion > Handler.SchemaVersion then
    Fail('unsupported schema version for ' .. Name .. ': ' .. SchemaVersion)
  end

  local PreviousTypedDecodeStart = State.TypedDecodeStart
  State.TypedDecodeStart = State.ResolveOrderCounter
  local Payload = DecodeNode(Node.v, State)
  State.TypedDecodeStart = PreviousTypedDecodeStart

  if Name == 'buffer' then
    if typeof(Payload) ~= 'string'
      or #Payload > math.ceil(State.Options.MaxBufferBytes / 3) * 4
    then
      Fail('buffer payload exceeds MaxBufferBytes or is not a string')
    end
  end

  local Result = CallDeserialize(Handler, Name, Payload, SchemaVersion)

  if Name == 'buffer' then
    if typeof(Result) ~= 'buffer' or buffer.len(Result) > State.Options.MaxBufferBytes then
      Fail('buffer exceeds MaxBufferBytes')
    end
  end

  return Result
end

ResolveReferenceIdentifier = function(ReferenceIdentifier, State)
  local Node = State.Definitions[ReferenceIdentifier]

  if Node == nil then
    Fail('missing reference: ' .. ReferenceIdentifier)
  end

  local Status = State.Status[ReferenceIdentifier]

  if Status == 'complete' then
    return State.Objects[ReferenceIdentifier]
  end

  if Status == 'resolving' then
    if Node['$'] == 't' then
      local ActiveTableOrder = State.ResolveOrder[ReferenceIdentifier]

      if State.WireVersion >= 4
        and State.TypedDecodeStart ~= nil
        and ActiveTableOrder <= State.TypedDecodeStart
      then
        Fail('custom-type payload references an incomplete table')
      end

      return State.Objects[ReferenceIdentifier]
    end
    Fail('cyclic dependency through custom type: ' .. ReferenceIdentifier)
  end

  State.Status[ReferenceIdentifier] = 'resolving'
  State.ResolveOrderCounter += 1
  State.ResolveOrder[ReferenceIdentifier] = State.ResolveOrderCounter

  local Result

  if Node['$'] == 't' then
    Result = State.Objects[ReferenceIdentifier]
    FillContent(Result, Node.k, Node.v, State)
  else
    Result = DecodeTyped(Node, State)
    State.Objects[ReferenceIdentifier] = Result
  end

  State.Status[ReferenceIdentifier] = 'complete'
  return Result
end

DecodeNode = function(Value, State)
  State.DecodeFrames += 1

  if State.DecodeFrames > State.Options.MaxDecodeFrames then
    Fail('dependency chain exceeds MaxDecodeFrames')
  end

  local Result
  local ValueType = typeof(Value)

  if ValueType ~= 'table' then
    Result = Value
  else
    local Tag = rawget(Value, '$')

    if Tag == nil then
      Result = {}
      local Kind = 'o'

      if next(Value) == nil then
        Kind = 'a'
      else
        for Key in pairs(Value) do
          if typeof(Key) == 'number' then
            Kind = 'a'
          end
          break
        end
      end

      FillContent(Result, Kind, Value, State)
    elseif Tag == 'z' then
      Result = nil
    elseif Tag == 'x' then
      if Value.v == 'nan' then
        Result = 0 / 0
      elseif Value.v == '+inf' then
        Result = math.huge
      else
        Result = -math.huge
      end
    elseif Tag == 'r' then
      Result = ResolveReferenceIdentifier(Value.i, State)
    elseif Tag == 't' then
      Result = ResolveReferenceIdentifier(Value.i, State)
    elseif Tag == 'o' or Tag == 'm' then
      Result = {}
      FillContent(Result, Tag, Value.v, State)
    elseif Tag == 'u' then
      if Value.i ~= nil then
        Result = ResolveReferenceIdentifier(Value.i, State)
      else
        Result = DecodeTyped(Value, State)
      end
    else
      Fail('invalid wire node')
    end
  end

  State.DecodeFrames -= 1
  return Result
end

local function InspectWire(Data, Options, WireVersion)
  local State = {
    Options = Options,
    WireVersion = WireVersion,
    Nodes = 0,
    Tables = 0,
    Entries = 0,
    TypedObjects = 0,
    TotalStringBytes = 0,

    Objects = {},
    Definitions = {},
    Status = {},
    ResolveOrder = {},
    ResolveOrderCounter = 0,
    TypedDecodeStart = nil,
    Referenced = {},
    WireSeen = {},
    SortedKeys = {},
    DecodeFrames = 0,
  }
  InspectNode(Data, State, 0)
  for ReferenceIdentifier in pairs(State.Referenced) do
    if State.Definitions[ReferenceIdentifier] == nil then
      Fail('missing reference definition: ' .. ReferenceIdentifier)
    end
  end

  return State
end

local function ValidateDecodeFrames(Data, State)
  local WalkNode
  local WalkReferenceIdentifier

  local function WalkContent(Kind, Content)
    if Kind == 'a' then
      for Index = 1, #Content do
        WalkNode(Content[Index])
      end
    elseif Kind == 'o' then
      local Keys = State.SortedKeys[Content]

      if Keys == nil then
        Keys = {}
        for Key in pairs(Content) do
          Keys[#Keys + 1] = Key
        end
        table.sort(Keys)
        State.SortedKeys[Content] = Keys
      end

      for _, Key in ipairs(Keys) do
        WalkNode(Content[Key])
      end
    else
      for Index = 1, #Content do
        local Pair = Content[Index]
        WalkNode(Pair[1])
        WalkNode(Pair[2])
      end
    end
  end

  WalkReferenceIdentifier = function(ReferenceIdentifier)
    local Node = State.Definitions[ReferenceIdentifier]
    local Status = State.WalkStatus[ReferenceIdentifier]

    if Status == 'complete' then
      return
    end

    if Status == 'resolving' then
      if Node['$'] == 't' then
        local ActiveTableOrder = State.WalkResolveOrder[ReferenceIdentifier]

        if State.TypedWalkStart ~= nil and ActiveTableOrder <= State.TypedWalkStart then
          Fail('custom-type payload references an incomplete table')
        end

        return
      end
      Fail('cyclic dependency through custom type: ' .. ReferenceIdentifier)
    end

    State.WalkStatus[ReferenceIdentifier] = 'resolving'
    State.WalkResolveOrderCounter += 1
    State.WalkResolveOrder[ReferenceIdentifier] = State.WalkResolveOrderCounter

    if Node['$'] == 't' then
      WalkContent(Node.k, Node.v)
    else
      local PreviousTypedWalkStart = State.TypedWalkStart
      State.TypedWalkStart = State.WalkResolveOrderCounter
      WalkNode(Node.v)
      State.TypedWalkStart = PreviousTypedWalkStart
    end

    State.WalkStatus[ReferenceIdentifier] = 'complete'
  end

  WalkNode = function(Value)
    State.WalkFrames += 1

    if State.WalkFrames > State.Options.MaxDecodeFrames then
      Fail('dependency chain exceeds MaxDecodeFrames')
    end

    if typeof(Value) == 'table' then
      local Tag = rawget(Value, '$')

      if Tag == nil then
        if next(Value) ~= nil then
          local FirstKey = next(Value)
          WalkContent(typeof(FirstKey) == 'number' and 'a' or 'o', Value)
        end
      elseif Tag == 'r' or Tag == 't' then
        WalkReferenceIdentifier(Value.i)
      elseif Tag == 'o' or Tag == 'm' then
        WalkContent(Tag, Value.v)
      elseif Tag == 'u' then
        if Value.i ~= nil then
          WalkReferenceIdentifier(Value.i)
        else
          local PreviousTypedWalkStart = State.TypedWalkStart
          State.TypedWalkStart = State.WalkResolveOrderCounter
          WalkNode(Value.v)
          State.TypedWalkStart = PreviousTypedWalkStart
        end
      end
    end

    State.WalkFrames -= 1
  end

  State.WalkStatus = {}
  State.WalkResolveOrder = {}
  State.WalkResolveOrderCounter = 0
  State.TypedWalkStart = nil
  State.WalkFrames = 0
  WalkNode(Data)
end

local function DecodeWire(Data, Options, WireVersion)
  local State = InspectWire(Data, Options, WireVersion)
  return DecodeNode(Data, State)
end

local function ValidateV1Payload(Value, State, Depth, Active)
  Touch(State, Depth)
  local ValueType = typeof(Value)

  if ValueType == 'string' then
    CheckStringBudget(State, Value)
    return
  end

  if ValueType == 'number' or ValueType == 'boolean' or ValueType == 'nil' then
    return
  end

  if ValueType ~= 'table' then
    Fail('invalid v1 datatype payload value')
  end

  if Active[Value] then
    Fail('cyclic v1 datatype payload')
  end
  Active[Value] = true
  CountTable(State)
  for Key, Item in pairs(Value) do
    CountEntry(State)
    if typeof(Key) ~= 'string' and typeof(Key) ~= 'number' then
      Fail('invalid v1 payload key type')
    end
    ValidateV1Payload(Key, State, Depth + 1, Active)
    ValidateV1Payload(Item, State, Depth + 1, Active)
  end
  Active[Value] = nil
end

local DecodeV1Node
DecodeV1Node = function(Value, State, Depth)
  Touch(State, Depth)
  local ValueType = typeof(Value)

  if ValueType == 'string' then
    CheckStringBudget(State, Value)
    return Value
  end

  if ValueType ~= 'table' then
    if ValueType == 'nil' or ValueType == 'boolean' or ValueType == 'number' then
      return Value
    end
    Fail('unsupported v1 encoded type: ' .. ValueType)
  end

  local Tag = Value.__Type

  if Tag == 'Nil' then
    return nil
  end

  if Tag == 'Number' then
    if Value.Value == 'NaN' then
      return 0 / 0
    end

    if Value.Value == 'Infinity' then
      return math.huge
    end

    if Value.Value == '-Infinity' then
      return -math.huge
    end
    Fail('invalid v1 special number')
  end

  if Tag == 'Reference' then
    local ReferenceIdentifier = CheckReferenceIdentifier(Value.ID, State)

    if State.Objects[ReferenceIdentifier] == nil then
      Fail('missing v1 reference: ' .. ReferenceIdentifier)
    end

    return State.Objects[ReferenceIdentifier]
  end

  if Tag == 'Table' then
    local ReferenceIdentifier = CheckNewReferenceIdentifier(Value.ID, State)
    CountTable(State)
    local Result = {}
    State.Objects[ReferenceIdentifier] = Result

    local Count = DenseLength(Value.Entries, 'v1 table entries')

    for Index = 1, Count do
      CountEntry(State)
      local Entry = Value.Entries[Index]

      if typeof(Entry) ~= 'table'
        or rawget(Entry, 'Key') == nil
        or rawget(Entry, 'Value') == nil
      then
        Fail('invalid v1 entry at ' .. Index)
      end

      local Key = DecodeV1Node(Entry.Key, State, Depth + 1)
      local Item = DecodeV1Node(Entry.Value, State, Depth + 1)

      if Key == nil or (typeof(Key) == 'number' and Key ~= Key) then
        Fail('invalid v1 key at ' .. Index)
      end

      if Item == nil then
        Fail('v1 map cannot contain nil')
      end

      if rawget(Result, Key) ~= nil then
        Fail('duplicate v1 map key')
      end

      Result[Key] = Item
    end

    return Result
  end

  if typeof(Tag) ~= 'string' then
    Fail('missing v1 __Type')
  end

  local Handler = TypeHandlers[Tag]

  if Handler == nil then
    Fail('unknown v1 serialized type: ' .. Tag)
  end

  if rawget(Value, 'Value') == nil then
    Fail('missing v1 type payload')
  end
  CountTypedObject(State)

  if Tag == 'buffer' then
    if typeof(Value.Value) ~= 'string'
      or #Value.Value > math.ceil(State.Options.MaxBufferBytes / 3) * 4
    then
      Fail('buffer payload exceeds MaxBufferBytes or is not a string')
    end
  end

  ValidateV1Payload(Value.Value, State, Depth + 1, {})
  local Result = CallDeserialize(Handler, Tag, Value.Value, 1)

  if Tag == 'buffer' and buffer.len(Result) > State.Options.MaxBufferBytes then
    Fail('buffer exceeds MaxBufferBytes')
  end

  return Result
end

local function NewState(Options)
  return {
    Options = Options,
    Nodes = 0,
    Tables = 0,
    Entries = 0,
    TypedObjects = 0,
    TotalStringBytes = 0,

    Objects = {},
    Seen = {},
    ActiveTyped = {},
    ActiveTables = {},
    CaptureOrder = 0,
    TypedCaptureStart = nil,
    HasReferences = false,
  }
end

VersionDecoders[1] = function(Data, Options)
  return DecodeV1Node(Data, NewState(Options), 0)
end
VersionDecoders[2] = function(Data, Options)
  return DecodeWire(Data, Options, 2)
end
VersionDecoders[3] = function(Data, Options)
  return DecodeWire(Data, Options, 3)
end
VersionDecoders[4] = function(Data, Options)
  return DecodeWire(Data, Options, 4)
end

function Serializer:RegisterType(Name, Serialize, Deserialize, Predicate, SourceType, SchemaVersion)
  if typeof(Name) ~= 'string' or Name == '' then
    Fail('type name must be a nonempty string')
  end

  if ReservedTypeNames[Name] or TypeHandlers[Name] ~= nil then
    Fail('type name is reserved or already registered: ' .. Name)
  end

  if typeof(Serialize) ~= 'function' or typeof(Deserialize) ~= 'function' then
    Fail('serialize and deserialize must be functions')
  end

  if Predicate ~= nil and typeof(Predicate) ~= 'function' then
    Fail('predicate must be a function')
  end

  if SourceType ~= nil then
    if Predicate == nil or typeof(SourceType) ~= 'string' or SourceType == '' then
      Fail('source type requires a predicate and a nonempty typeof name')
    end

    if SourceType == 'nil'
      or SourceType == 'boolean'
      or SourceType == 'number'
      or SourceType == 'string'
    then
      Fail('custom predicates cannot target primitive source types')
    end
  end

  if SchemaVersion ~= nil and (not IsPositiveInteger(SchemaVersion) or SchemaVersion > 65535) then
    Fail('schema version must be an integer from 1 to 65535')
  end

  local Handler = CreateTypeHandler(Serialize, Deserialize, Predicate, SchemaVersion)
  TypeHandlers[Name] = Handler
  if Predicate ~= nil then
    PredicateHandlers[#PredicateHandlers + 1] = {
      Name = Name,
      Handler = Handler,
      Predicate = Predicate,
      SourceType = SourceType,
    }
    PredicateDispatchCache = {}
  end
end

function Serializer:RegisterVersionDecoder(Version, Decoder)
  if typeof(Version) ~= 'number'
    or Version < 0
    or Version % 1 ~= 0
    or Version >= SerializationVersion
  then
    Fail('legacy version must be a nonnegative integer below current version')
  end

  if VersionDecoders[Version] ~= nil then
    Fail('version decoder already registered: ' .. Version)
  end

  if typeof(Decoder) ~= 'function' then
    Fail('decoder must be a function')
  end
  VersionDecoders[Version] = Decoder
end

function Serializer:GetVersion()
  return SerializationVersion
end

local function SerializeWithEffectiveOptions(Value, EffectiveOptions, EnforceMaxBytes)
  local State = NewState(EffectiveOptions)

  if EnforceMaxBytes then
    State.MaxEncodedBytes = EffectiveOptions.MaxBytes
  end

  local Root = Capture(Value, State, 0)
  local EncodeState = {
    Options = EffectiveOptions,
    Frames = 0,
    ReferenceIdentifiers = {},
    Definitions = {},
    NextReferenceIdentifier = 0,
  }
  local Encoded = EncodeNode(Root, EncodeState)

  if State.HasReferences then
    ValidateDecodeFrames(Encoded, {
      Options = EffectiveOptions,
      Definitions = EncodeState.Definitions,
      SortedKeys = {},
    })
  end
  return {
    __Version = SerializationVersion,
    Data = Encoded,
  }
end

function Serializer:Serialize(Value, Options)
  return SerializeWithEffectiveOptions(Value, ResolveOptions(Options), false)
end

function Serializer:Deserialize(Serialized, Options)
  local EffectiveOptions = ResolveOptions(Options)

  if typeof(Serialized) ~= 'table' then
    Fail('serialized data must be a table')
  end

  local Version = Serialized.__Version

  if not IsPositiveInteger(Version) and Version ~= 0 then
    Fail('invalid serialization version')
  end

  local Decoder = VersionDecoders[Version]

  if Decoder == nil then
    Fail('unsupported serialization version: ' .. Version)
  end

  if rawget(Serialized, 'Data') == nil then
    Fail('serialized data is missing Data')
  end

  return Decoder(Serialized.Data, EffectiveOptions)
end

function Serializer:Upgrade(Serialized, Options)
  return self:Serialize(self:Deserialize(Serialized, Options), Options)
end

function Serializer:Encode(Value, Options)
  local EffectiveOptions = ResolveOptions(Options)
  local Serialized = SerializeWithEffectiveOptions(Value, EffectiveOptions, true)
  local Success, JsonText = pcall(HttpService.JSONEncode, HttpService, Serialized)

  if not Success then
    Fail('JSONEncode failed: ' .. tostring(JsonText))
  end

  if #JsonText > EffectiveOptions.MaxBytes then
    Fail('JSON exceeds MaxBytes')
  end

  return JsonText
end

function Serializer:Decode(JsonText, Options)
  local EffectiveOptions = ResolveOptions(Options)

  if typeof(JsonText) ~= 'string' then
    Fail('JSON must be a string')
  end

  if #JsonText > EffectiveOptions.MaxBytes then
    Fail('JSON exceeds MaxBytes')
  end

  local Success, Serialized = pcall(HttpService.JSONDecode, HttpService, JsonText)

  if not Success then
    Fail('JSONDecode failed: ' .. tostring(Serialized))
  end

  return self:Deserialize(Serialized, EffectiveOptions)
end

return Serializer
