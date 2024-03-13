import glob
import argparse

# Determines unused lang keys
# Run by going to the root dir and using `python ./utils/lang_checker.py`
# It will print out all unused lang keys
# Can also automatically remove unused lang keys

parser = argparse.ArgumentParser("lang_checker")
parser.add_argument("--lang", help="The lang file to check", 
                    type=str, default='./common/locales/en-US/main.ftl', required=False)
parser.add_argument("--remove", help="If true removes those lines from the file", 
                    action=argparse.BooleanOptionalAction)
                    
args = parser.parse_args()

# The en lang file
lang = open(args.lang, 'r')
lines = []
# Read all keys from lang file
keys = []
root_key = ""
for line in lang.readlines():
    stripped = line.strip()
    if not stripped:
        lines.append(("", line))
        continue
    lang_key = ""
    if stripped.startswith('.'):
        split = stripped.split(' = ')
        lang_key = root_key + split[0]
        keys.append(lang_key)
    else:
        root_key = stripped.split(' = ')[0]
        lang_key = root_key
        keys.append(root_key)
    lines.append((lang_key, line))

# Collect all rust files
files = glob.glob('./**/*.rs', 
                   recursive = True)

# Remove build rs files
files = [f for f in files if not f.startswith("./target/")]

# Remove dynamic created keys
# E.g. toast action keys
keys = [x for x in keys if not (x.startswith('toast_actions') or x.startswith('settings-profile.status-'))]

# Check rust files if the language key is used
for file in files:
    with open(file) as f:
        content = f.read()
        keys = [x for x in keys if not x in content] 

# Unused keys
print("\n".join(keys))

if args.remove:
    root_key = ""
    with open(args.lang, 'w') as file:
        for (lang_key, line) in lines:
            if lang_key in keys:
                continue
            file.write(line)
        