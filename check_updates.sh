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
    exit 0
else
    echo "Firmware list is outdated because '$search_string' was not found."
fi

quoted_strings=$(echo "$page_content" | grep -oE '"[^"]*PS5UPDATE\.PUP"' | tr -d '"')
if [[ -n "$quoted_strings" ]]; then
  for string in $quoted_strings; do
    echo "Downloading $string"

    # Extract YYYY_MMDD and TYPE using regular expression
    if [[ "$string" =~ https://[^/]+/update/ps5/official/[^/]+/image/([0-9]{4}_[0-9]{4})/([^_]+)_ ]]; then
      YYYY_MMDD="${BASH_REMATCH[1]}"
      TYPE="${BASH_REMATCH[2]}"

      # Create custom folder
      folder_name="${YYYY_MMDD} ${TYPE}"
      # Normalize the folder names: Replace 'rec' with 'Recovery' and 'sys' with 'Update'.
      folder_name="${folder_name//rec/Recovery}"
      folder_name="${folder_name//sys/Update}"

      # Check if folder already exists
      if [[ -d "$folder_name" ]]; then
        echo "Error: Folder '$folder_name' already exists. Exiting."
        exit 0
      fi
      # Otherwise, we definitely want to create the folder.
      mkdir -p "$folder_name"

      # Download the file into the folder
      curl -s -L "$string" -o "$folder_name/PS5UPDATE.PUP"
      echo "Downloaded to: $folder_name/PS5UPDATE.PUP"

      # Calculate SHA256 and MD5 checksums
      sha256sum=$(sha256sum "$folder_name/PS5UPDATE.PUP" | awk '{print $1}')
      md5sum=$(md5sum "$folder_name/PS5UPDATE.PUP" | awk '{print $1}')

      # Show checksums in the output
      echo "SHA256: $sha256sum"
      echo "MD5   : $md5sum"

      # Save checksums to files
      echo "$sha256sum" > "$folder_name/PS5UPDATE.PUP.sha256"
      echo "$md5sum" > "$folder_name/PS5UPDATE.PUP.md5"
    else
      echo "ERROR: Unable to parse URL: $string"
    fi
  done
else
  echo "ERROR: No matching strings found."
fi
