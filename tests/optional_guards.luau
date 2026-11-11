local function length(value: string?): number
    if value == nil then return 0 end
    return #value
end
local function describe(value: string?): string
    if value then return value .. "!" else return "missing" end
end
local function present(value: string?): boolean
    return value ~= nil and #value > 0
end
local function empty(value: string?): boolean
    return value == nil or #value == 0
end
local function count(value: string?): number
    return if value then #value else 0
end
print(length(nil), length("amc"), describe(nil), describe("native"))
print(present(nil), present("yes"), empty(nil), empty(""), count("abcd"))
