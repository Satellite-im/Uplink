#!/bin/sh

# Check if 'gum' is available in the system
if ! command -v gum &> /dev/null; then
    echo "'gum' is not found. Attempting to install it using Homebrew..."
    
    # Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
        echo "Homebrew is not installed. Please install Homebrew (https://brew.sh/) and try again."
        exit 1
    fi

    # Install 'gum' using Homebrew
    brew install gum

    # Check if the installation was successful
    if ! command -v gum &> /dev/null; then
        echo "Failed to install 'gum'. Please install it manually and try again."
        exit 1
    fi
fi

echo "Select an action:"
echo "1. Build Extensions"
echo "2. Build UI"
echo "3. Help"
echo "4. Run Clippy"
echo "5. Run Fmt"
echo "6. Auto-fix Clippy"
echo "7. Auto-fix Fmt"

read -p "Enter your choice (1/2/3/4/5/6/7): " choice

case $choice in
  1)
    FLAGS=$(echo " --profile=rapid" " --profile=dev" " --profile=release" | xargs -n1 | gum choose)
    echo "cargo build --all ${FLAGS}"
    if [ "$FLAGS" != " --profile=release" ]; then
      echo "cp -r target/debug/*.dylib ~/.uplink/extensions"
    else
      echo "cp -r target/release/*.dylib ~/.uplink/extensions"
    fi
    ;;
  2)
    echo "Building UI..."
    cargo run
    ;;
  3)
    echo "Usage: $0"
    echo "Options:"
    echo "  1. Build Extensions: Build extensions for the specified profile"
    echo "  2. Build UI: Build the user interface"
    echo "  3. Help: Show this help message"
    echo "  4. Run Clippy: Run the Clippy linter"
    echo "  5. Run Fmt: Run the Rust formatter in check mode"
    echo "  6. Auto-fix Clippy: Automatically fix Clippy warnings"
    echo "  7. Auto-fix Fmt: Automatically format the code using Rust fmt"
    ;;
  4)
    echo "Running Clippy..."
    cargo clippy
    ;;
  5)
    echo "Running Fmt..."
    cargo fmt --check
    ;;
  6)
    echo "Auto-fixing Clippy warnings..."
    cargo clippy --fix
    ;;
  7)
    echo "Auto-fixing Fmt..."
    cargo fmt
    ;;
  *)
    echo "Invalid choice. Please select a valid option."
    ;;
esac
