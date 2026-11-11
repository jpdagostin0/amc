local function counter(): () -> number
    local n: number = 0
    return function(): number
        n += 1
        return n
    end
end
local first = counter()
local second = counter()
print(first(), first(), second())
local loops: {() -> number} = {}
for i = 1, 3 do
    loops[i] = function(): number return i end
end
local blocks: {() -> number} = {}
local j: number = 0
while j < 3 do
    j += 1
    local captured: number = j
    blocks[j] = function(): number return captured * 10 end
end
local one = loops[1]
local three = loops[3]
local ten = blocks[1]
if one and three and ten then print(one(), three(), ten(), j) end
local shared: number = 1
local function increment(): () shared += 1 end
local function read(): number return shared end
increment()
print(read(), shared)
local function make(): {get: () -> number, set: (number) -> ()}
    local value: number = 0
    return {get = function(): number return value end, set = function(next: number): () value = next end}
end
local object = make()
object.set(42)
print(object.get())
do
    local function fib(n: number): number
        if n < 2 then return n end
        return fib(n - 1) + fib(n - 2)
    end
    print(fib(10))
end
