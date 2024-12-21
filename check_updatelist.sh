#!/bin/bash
# Written by Gemini Advanced.

# Use US region by default.
ps5_updatelist_url="http://fus01.ps5.update.playstation.net/update/ps5/official/tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/list/us/updatelist.xml"
mylist_path="README.md"

# Load local README.md.
# Because it's run on GitHub Action, this file should always be up-to-date.
mylist_content=$(<$mylist_path)

# Fetch the web page's content using curl
page_content=$(curl -s "$ps5_updatelist_url")
# Extract SHA-256 hashes from the page content
hashes=$(echo "$page_content" | grep -oE '[a-fA-F0-9]{64}')

# Update the README file
# echo "Updated on $(date)\n" >> README.md

# Flag to check if all hashes are present
all_hashes_found=true
# Loop through each extracted hash
for hash in $hashes; do
    echo "Checking $hash"
    if [[ ! "$mylist_content" =~ $hash ]]; then
        echo "Hash $hash not found in $mylist_path"
        all_hashes_found=false
        break  # Exit loop as we found a missing hash
    fi
done

# If all hashes are found, exit the script
if [ "$all_hashes_found" = true ]; then
    echo "All hashes found in $mylist_path. Exiting."
    exit 0
fi

# TODO: keep all history versions of updatelists.xml

# If not all hashes are found, download the file
echo "Not all hashes were found. Downloading the file..."
file_name="updatelist.latest.xml"
wget -q "$ps5_updatelist_url" -O "updatelists/$file_name"
echo "File downloaded as updatelists/$file_name"

# TODO: Update the README.md as well.
