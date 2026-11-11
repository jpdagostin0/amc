local function compose(f: (number) -> number, g: (number) -> number): (number) -> number
    return function(x: number): number return f(g(x)) end
end
local function twice(f: (number) -> number): (number) -> number
    return function(x: number): number return f(f(x)) end
end
local offset: number = 5
local function apply(g: (number) -> number, x: number): number return g(x) end
print(apply(function(x: number): number return x + offset end, 2))
print(compose(function(x: number): number return x * 2 end, function(x: number): number return x + 1 end)(3))
print(twice(twice(function(x: number): number return x + 1 end))(0))
local operations: {[string]: (number, number) -> number} = {
    add = function(a: number, b: number): number return a + b end,
    mul = function(a: number, b: number): number return a * b end,
}
local add = operations.add
local mul = operations["mul"]
if add and mul then print(add(2, 3), mul(2, 3)) end
local upper: (string) -> string = string.upper
local floor = math.floor
local show: (number) -> () = print
show(floor(2.5))
print(upper("x"))
local same = apply
print(same == apply, apply == compose, type(apply))
