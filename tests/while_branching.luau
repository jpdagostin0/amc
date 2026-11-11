local function sum(n: number, unused: string): number
    local total: number = 0
    while n > 0 do
        n -= 1
        if n == 4 then
            continue
        elseif n == 1 then
            break
        else
            total = total + n
        end
    end
    return total
end
print(sum(6, "ignored"))
