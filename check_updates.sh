#!/bin/bash
# Written by Gemini Advanced.

# The URL of the web page to check
ps5_updates_url="https://www.playstation.com/en-us/support/hardware/ps5/system-software/"
mylist_url="https://raw.githubusercontent.com/MewX/ps5-official-firmware-list/main/README.md"

mylist_content=$(curl -s "$mylist_url")

# Extract the first SHA-256 hash using grep and regular expressions.
# The string to search for within the web page's contents.
search_string=$(echo "$mylist_content" | grep -oE '[a-fA-F0-9]{64}' | head -n 1)

# Fetch the web page's content using curl
page_content=$(curl -s "$ps5_updates_url")

# Check if the page content contains the search string
if [[ $page_content == *"$search_string"* ]]; then
    echo "Firmware list is up-to-date because '$search_string' was found on the page."
else
    echo "Firmware list is outdated because '$search_string' was not found."
fi

