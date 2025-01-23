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

# If not all hashes are found, download the file
echo "Not all hashes were found. Downloading the file..."
folder_name="updatelists"
file_name="updatelist.latest.xml"
file_path="$folder_name/$file_name"
wget -q "$ps5_updatelist_url" -O "$file_path"
echo "File downloaded as $file_path"
echo ""
echo "Please run check_and_download_updates.sh to download all the binaries."
echo ""

# Extract necessary information and build markdown table row.
# Find the system_pup line and extract both label and upd_version from it
system_pup_line=$(grep '<system_pup' "$file_path")

# Extract label from system_pup element
label=$(echo "$system_pup_line" | grep -o 'label="[^"]*"' | sed 's/label="//;s/"//')
# Extract upd_version from the same system_pup element and trim to first three sections
upd_version_full=$(echo "$system_pup_line" | grep -o 'upd_version="[^"]*"' | sed 's/upd_version="//;s/"//')
upd_version=$(echo "$upd_version_full" | awk -F. '{print $1"."$2"."$3}')

# Extract image element content
image_line=$(grep -o '<image.*>.*</image>' "$file_path")
# Extract size from image element
size=$(echo "$image_line" | grep -o 'size="[0-9]*"' | sed 's/size="//;s/"//')

# Extract build date from image URL path segment
url=$(echo "$image_line" | sed -e 's/<image[^>]*>//;s/<\/image>//;s/ //g')
build_date=$(echo "$url" | awk -F/ '{ for(i=1; i<=NF; i++) { if ($i == "image") { print $(i+1); break; } } }')

# Create markdown table row with new Size column
echo "Copy below to the README.md"
echo "| $label | $upd_version        | 🆙 Update   | $build_date       | TODO_SHA256 | TODO_MD5 | $size B |"
echo "| $label | $upd_version        | ❤️‍🩹 Recovery | $build_date       | TODO_SHA256 | TODO_MD5 | TODO B |"

# Make a copy of the latest updatelists.xml and make it a separate file.
copied_file_path="$folder_name/updatelist.$build_date.$upd_version.xml"
echo "File copied to as $copied_file_path"
cp -f "$file_path" "$copied_file_path"

# TODO: Update the README.md as well.
