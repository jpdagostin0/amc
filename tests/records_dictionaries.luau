type Point = {x: number, y: number}
type Node = {value: number, next: Node?}
local point: Point = {x = 1, y = 2}
local alias: Point = point
alias.x += 10
local function length2(p: Point): number return p.x * p.x + p.y * p.y end
print(point.x, point.y, length2({x = 3, y = 4}))
local counts: {[string]: number} = {apple = 1}
counts.pear = (counts.pear or 0) + 5
counts["plum"] = 2
print(counts.apple, counts.pear, counts["plum"], counts.missing)
local names: {[number]: string} = {[10] = "ten"}
names[20] = "twenty"
print(names[10], names[20], names[30])
local list: Node = {value = 1, next = {value = 2, next = {value = 3}}}
local cursor: Node? = list
local total: number = 0
while cursor do
    total += cursor.value
    cursor = cursor.next
end
local nested = {inner = {deep = {v = 1}}}
nested.inner.deep.v = 5
print(total, nested.inner.deep.v)
