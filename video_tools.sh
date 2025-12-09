#!/bin/bash

delete_all_metadata() 
{
    mkdir -p no_metadata
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            echo "File $file does not exist"
            continue
        fi
        filename=$(basename "$file" .mp4)
        ffmpeg -i "$file" -map_metadata -1 -c copy "no_metadata/$filename.mp4"
    done
}

modify_creation_time() 
{
    local timestamp=""
    local files=()
    
    if [ $# -eq 0 ]; then
        echo "Usage: modify_creation_time [timestamp] file1 [file2 ...]"
        echo "  timestamp: Optional. Format: YYYYMMDDHHMM.SS or YYYY-MM-DD HH:MM:SS"
        echo "            If not provided, uses current time"
        return 1
    fi
    
    if [[ "$1" =~ ^[0-9]{8}[0-9]{4}\.[0-9]{2}$ ]] || [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        timestamp="$1"
        shift
    fi
    
    files=("$@")
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "Error: No files specified"
        return 1
    fi
    
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            echo "File $file does not exist"
            continue
        fi
        
        if [ -n "$timestamp" ]; then
            if [[ "$timestamp" =~ ^[0-9]{8}[0-9]{4}\.[0-9]{2}$ ]]; then
                touch -t "$timestamp" "$file"
            else
                touch -d "$timestamp" "$file"
            fi
            echo "Modified creation time of $file to $timestamp"
        else
            touch "$file"
            echo "Modified creation time of $file to current time"
        fi
    done
}

show_creation_time() 
{
    if [ $# -eq 0 ]; then
        echo "Usage: show_creation_time file1 [file2 ...]"
        return 1
    fi
    
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            echo "File $file does not exist"
            continue
        fi
        
        echo "=== $file ==="
        if command -v stat >/dev/null 2>&1; then
            if stat --version >/dev/null 2>&1; then
                mtime=$(stat -c "%y" "$file" 2>/dev/null)
                atime=$(stat -c "%x" "$file" 2>/dev/null)
                ctime=$(stat -c "%z" "$file" 2>/dev/null)
            else
                mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null)
                atime=$(stat -f "%Sa" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null)
                ctime=$(stat -f "%Sc" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null)
            fi
            echo "Modified time: $mtime"
            echo "Access time:   $atime"
            echo "Change time:   $ctime"
        else
            ls -l "$file" | awk '{print "Modified time: " $6 " " $7 " " $8}'
        fi
        echo
    done
}

show_metadata() 
{
    if [ $# -eq 0 ]; then
        echo "Usage: show_metadata file1 [file2 ...]"
        return 1
    fi
    
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            echo "File $file does not exist"
            continue
        fi
        
        echo "=== $file ==="
        
        if command -v ffprobe >/dev/null 2>&1; then
            local json_output
            json_output=$(ffprobe -v quiet -print_format json -show_format -show_streams "$file" 2>/dev/null)
            
            if [ -z "$json_output" ]; then
                echo "Error: Failed to read metadata from file"
                continue
            fi
            
            if command -v python3 >/dev/null 2>&1; then
                echo "--- Format Information ---"
                parsed_output=$(echo "$json_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    format_info = data.get('format', {})
    print(f\"Format name: {format_info.get('format_name', 'N/A')}\")
    print(f\"Format long name: {format_info.get('format_long_name', 'N/A')}\")
    print(f\"Duration: {format_info.get('duration', 'N/A')} seconds\")
    print(f\"Size: {format_info.get('size', 'N/A')} bytes\")
    print(f\"Bitrate: {format_info.get('bit_rate', 'N/A')} bps\")
    print()
    
    tags = format_info.get('tags', {})
    if tags:
        print('--- Metadata Tags ---')
        for key, value in sorted(tags.items()):
            print(f\"{key}: {value}\")
        print()
    
    streams = data.get('streams', [])
    if streams:
        print('--- Stream Information ---')
        for i, stream in enumerate(streams):
            codec_type = stream.get('codec_type', 'unknown')
            codec_name = stream.get('codec_name', 'N/A')
            print(f\"Stream #{i} ({codec_type}):\")
            print(f\"  Codec: {codec_name} ({stream.get('codec_long_name', 'N/A')})\")
            if codec_type == 'video':
                print(f\"  Resolution: {stream.get('width', 'N/A')}x{stream.get('height', 'N/A')}\")
                print(f\"  Frame rate: {stream.get('r_frame_rate', 'N/A')}\")
                print(f\"  Bitrate: {stream.get('bit_rate', 'N/A')} bps\")
            elif codec_type == 'audio':
                print(f\"  Sample rate: {stream.get('sample_rate', 'N/A')} Hz\")
                print(f\"  Channels: {stream.get('channels', 'N/A')}\")
                print(f\"  Bitrate: {stream.get('bit_rate', 'N/A')} bps\")
            print()
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
                
                if [ $? -eq 0 ] && [ -n "$parsed_output" ]; then
                    echo "$parsed_output"
                else
                    echo "--- Format Metadata (Raw JSON) ---"
                    echo "$json_output" | python3 -m json.tool 2>/dev/null | head -n 100
                fi
            else
                echo "--- Format Metadata (Raw JSON) ---"
                echo "$json_output" | head -n 100
            fi
        elif command -v ffmpeg >/dev/null 2>&1; then
            echo "--- Metadata (from ffmpeg) ---"
            ffmpeg -i "$file" 2>&1 | grep -E "(Duration|Stream|Metadata|Input)" | head -n 50
        else
            echo "Error: ffprobe or ffmpeg not found. Please install ffmpeg."
            return 1
        fi
        
        echo ""
    done
}

_video_tools_complete()
{
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [ $COMP_CWORD -eq 1 ]; then
        COMPREPLY=($(compgen -W "delete_all_metadata modify_creation_time show_creation_time show_metadata" -- "$cur"))
    elif [ "$prev" = "modify_creation_time" ]; then
        if [[ "$cur" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || [[ "$cur" =~ ^[0-9]{8}[0-9]{4}\.[0-9]{2}$ ]]; then
            COMPREPLY=($(compgen -f -X '!*.mp4' -- "$cur"))
        else
            COMPREPLY=($(compgen -f -X '!*.mp4' -- "$cur"))
        fi
    else
        COMPREPLY=($(compgen -f -X '!*.mp4' -- "$cur"))
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    complete -F _video_tools_complete video_tools.sh
    complete -F _video_tools_complete ./video_tools.sh
    return 0
fi

$1 "${@:2}"
