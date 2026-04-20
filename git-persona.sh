#!/bin/bash

echo "--- Git Identity Setup (Local Repo) ---"

# Prompt user for input
read -p "Enter your Full Name: " gitname
read -p "Enter your Email: " gitemail

# Check if we are inside a git repository
if [ -d .git ] || git rev-parse --git-dir > /dev/null 2>&1; then

    # Validate email format before setting
    if ! [[ "$gitemail" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "❌ Error: Invalid email format."
        exit 1
    fi

    # Set local configuration
    git config user.name "$gitname"
    git config user.email "$gitemail"

    echo "✅ Success! Local repo settings updated:"
    echo "Name: $gitname"
    echo "Email: $gitemail"
else
    echo "❌ Error: This directory is not a Git repository."
    echo "Please run this script inside a project folder."
    exit 1
fi
