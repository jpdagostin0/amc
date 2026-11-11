type Shape = {kind: "circle", r: number} | {kind: "square", s: number}
type Result = {ok: true, value: number} | {ok: false, err: string}
type Value = number | string | {items: {number}}
local function area(shape: Shape): number
    if shape.kind == "circle" then return shape.r * shape.r * 3 end
    return shape.s * shape.s
end
local function divide(a: number, b: number): Result
    if b == 0 then return {ok = false, err = "division by zero"} end
    return {ok = true, value = a / b}
end
local function describe(v: Value): string
    if type(v) == "number" then return "number " .. v end
    if typeof(v) == "string" then return "string " .. v end
    local total: number = 0
    for i = 1, #v.items do total += v.items[i] or 0 end
    return "items " .. total
end
print(area({kind = "circle", r = 2}), area({kind = "square", s = 3}))
local failed = divide(1, 0)
if failed.ok then print(failed.value) else print(failed.err) end
local passed = divide(6, 3)
if passed.ok == true then print(passed.value) end
print(describe(4), describe("x"), describe({items = {1, 2, 3}}))
local mixed: number | boolean | string = true
print(mixed, type(mixed))
mixed = "text"
print(mixed, type(mixed))
local array = {1, "two", true}
print(array[1], array[2], array[3])
