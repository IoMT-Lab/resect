def setVariable(name, value):
    globals()[name] = value

def getVariable(name, defaultValue=None):
    if name not in globals():
        globals()[name] = defaultValue
    return globals()[name]

def incrementVariable(name, defaultValue=0, increment=1):
    value = getVariable(name, defaultValue)
    value = value + increment
    setVariable(name, value)
    return value