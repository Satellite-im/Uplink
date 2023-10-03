import argparse
import fluent.syntax.ast as FTL
from fluent.syntax.serializer import FluentSerializer
from fluent.syntax.parser import FluentParser

def load_locale_data(file_path):
    with open(file_path, 'r', encoding='utf-8') as file:
        return file.read()

def save_locale_data(file_path, resource):
    with open(file_path, 'w', encoding='utf-8') as file:
        serializer = FluentSerializer()
        file.write(serializer.serialize(resource))

def add_missing_keys(source_file, target_files):
    source_data = load_locale_data(source_file)
    parser = FluentParser()

    source_resource = parser.parse(source_data)

    for target_file in target_files:
        target_data = load_locale_data(target_file)
        target_resource = parser.parse(target_data)

        missing_keys = []

        for entry in source_resource.body:
            if isinstance(entry, FTL.Message):
                target_entry = next(
                    (e for e in target_resource.body if isinstance(e, FTL.Message) and e.id.name == entry.id.name),
                    None
                )

                if target_entry is None:
                    missing_keys.append(entry)

        if missing_keys:
            target_resource.body.extend(missing_keys)
            save_locale_data(target_file, target_resource)
            print(f"Added missing keys to {target_file}: {[entry.id.name for entry in missing_keys]}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Add missing keys to other locale files")
    parser.add_argument("--source-lang", help="The source lang file (en-US)", 
                        type=str, default='./common/locales/en-US/main.ftl', required=False)
    parser.add_argument("--target-locales", nargs='+', help="List of target locale files", 
                        type=str, default=['./common/locales/pt-PT/main.ftl', './common/locales/pt-BR/main.ftl', './common/locales/de/main.ftl', './common/locales/es-MX/main.ftl'], required=False)
    
    args = parser.parse_args()

    add_missing_keys(args.source_lang, args.target_locales)
