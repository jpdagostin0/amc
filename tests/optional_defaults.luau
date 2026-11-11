local absent: string?
local function label(value: string?): string
    return value or "missing"
end
local function maybe(value: number?): number?
    if value then return value end
end
local function none(): string?
    return
end
print(absent, label(), maybe(), (none()))
local function first(values: {number}): number
    return values[1] or 0
end
print(first({}), first({7}))
