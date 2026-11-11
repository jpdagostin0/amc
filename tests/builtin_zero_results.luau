local values: {number} = {}
print("first", string.byte("", 1))
print(string.byte("", 1), "last")
print((string.byte("", 1)))
print("first", table.remove(values))
print(table.remove(values), "last")
print((table.remove(values)))
