#!/bin/bash

# Ensure we are in a uv-managed environment or use uv run for portability
echo "------------------------------------------"
echo "   UV Project Management Menu"
echo "------------------------------------------"

options=("Run Aider (AI Pair Programmer)"
         "View Dependency Tree (pipdeptree)"
         "Scan for Vulnerabilities (Safety)"
         "Update/Sync Environment"
         "Quit")

select opt in "${options[@]}"
do
    case $opt in
        "Run Aider (AI Pair Programmer)")
            echo "Launching Aider..."
            # Using uvx (uv run) to ensure Aider is available
            uvx aider-chat
            ;;
        "View Dependency Tree (pipdeptree)")
            echo "Generating dependency tree..."
            uvx pipdeptree
            ;;
        "Scan for Vulnerabilities (Safety)")
            echo "Scanning requirements.txt with Safety..."
            # Using the new 'scan' command as requested
            uvx safety scan --file requirements.txt
            ;;
        "Update/Sync Environment")
            echo "Syncing environment with requirements.txt..."
            uv pip sync requirements.txt
            ;;
        "Quit")
            break
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done
