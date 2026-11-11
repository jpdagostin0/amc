type MaybeText = string | nil
local function choose(value: MaybeText): string?
    return value
end
local missing: string? = nil
local present: string? = choose("compiler")
local count: number? = nil
local flag: boolean? = false
print(missing, present, count, flag)
print(missing == nil, present ~= nil, present == "compiler", present == choose("compiler"))
print(missing or "fallback", present or "fallback", count or 7, flag or true)
print(not missing, not present, not 0, not "")
missing = "ready"
count = 0
flag = nil
print(missing, count, flag, nil == 1, nil ~= "")
