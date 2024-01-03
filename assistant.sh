#!/bin/sh

MODE=$(gum choose "Build Extensions" "Build UI")
FLAGS=$(gum choose " --profile=rapid" " --profile=dev" " --profile=release")

case $MODE in
  "Build Extensions")
        echo "cargo build --all ${FLAGS}"
        if [ $FLAGS != " --profile=release" ]
        then
            echo "cp -r target/debug/*.dylib ~/.uplink/extensions"
        else
            echo "cp -r target/release/*.dylib ~/.uplink/extensions"
        fi
    ;;
  *)
    # TODO: help here
    echo "sorry, this isn't built yet."
    ;;
esac