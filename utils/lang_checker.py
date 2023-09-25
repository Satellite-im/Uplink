import glob

# Determines unused lang keys
# Run by going to the root dir and using `python ./utils/lang_checker.py`
# It will print out all unused lang keys

# The en lang file
lang = open('./common/locales/en-US/main.ftl', 'r')

# Read all keys from lang file
keys = []
previous = ""
for line in lang.readlines():
    stripped = line.strip()
    if not stripped:
        continue
    if stripped.startswith('.'):
        split = stripped.split(' = ')
        keys.append(previous + split[0])
    else:
        previous = stripped.split(' = ')[0]
        keys.append(previous)

# Collect all rust files
files = glob.glob('./**/*.rs', 
                   recursive = True)

# Remove build rs files
files = [f for f in files if not f.startswith("./target/")]

# Remove dynamic created keys
# E.g. toast action keys
keys = [x for x in keys if not x.startswith('toast_actions')]

# Check rust files if the language key is used
for file in files:
    with open(file) as f:
        content = f.read()
        keys = [x for x in keys if not x in content] 

# Unused keys
print("\n".join(keys))