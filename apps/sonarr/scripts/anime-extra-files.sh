#!/usr/bin/env bash

# Set the following location to your completed download location for Anime.
# Usually one of the following paths:
# Dockers => /data/{usenet|torrents}/anime
# Cloudbox => /mnt/local/downloads/nzbs/nzbget/completed/sonarranime
location="/data/downloads/sonarr"

find $location -type f \( -iname "*op[0-9]*" -o -iname "*nced*" -o -iname "*ncop*" -o -iname "*music video*" \) -exec rm -rf {} \;
