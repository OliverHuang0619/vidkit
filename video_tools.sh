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
    local comment=""
    local files=()
    
    if [ $# -eq 0 ]; then
        echo "Usage: modify_creation_time [comment] file1 [file2 ...]"
        echo "  comment: Optional. The comment text to set in video metadata"
        echo "          If not provided, uses current timestamp"
        return 1
    fi
    
    if [ $# -gt 1 ] && [ ! -f "$1" ]; then
        comment="$1"
        shift
    fi
    
    files=("$@")
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "Error: No files specified"
        return 1
    fi
    
    if [ -z "$comment" ]; then
        comment=$(date "+%Y-%m-%d %H:%M:%S")
    fi
    
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo "Error: ffmpeg not found. Please install ffmpeg."
        return 1
    fi
    
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            echo "File $file does not exist"
            continue
        fi
        
        local file_dir=$(dirname "$file")
        local file_basename=$(basename "$file")
        local temp_file="${file_dir}/.${file_basename}.tmp"
        
        local error_output
        error_output=$(ffmpeg -i "$file" -map_metadata 0 -metadata comment="$comment" -c:v copy -c:a copy -c:s copy -f mp4 "$temp_file" -y 2>&1)
        local ffmpeg_exit_code=$?
        
        if [ $ffmpeg_exit_code -eq 0 ] && [ -f "$temp_file" ]; then
            if [ -s "$temp_file" ]; then
                mv "$temp_file" "$file"
                echo "Modified comment metadata of $file to: $comment"
            else
                echo "Error: Created file is empty for $file"
                echo "ffmpeg output: $error_output"
                rm -f "$temp_file"
            fi
        else
            echo "Error: Failed to modify metadata for $file"
            echo "ffmpeg error output:"
            echo "$error_output" | tail -n 10
            [ -f "$temp_file" ] && rm -f "$temp_file"
        fi
    done
}

extract_speech() 
{
    if [ $# -eq 0 ]; then
        echo "Usage: extract_speech [options] file1 [file2 ...]"
        echo "  options:"
        echo "    --language LANG    Language code (e.g., zh, en, auto). Default: auto"
        echo "    --model MODEL      Whisper model size (tiny, base, small, medium, large). Default: base"
        echo "    --output DIR       Output directory for transcriptions. Default: transcriptions"
        echo "    --format FORMAT    Output format (txt, srt, vtt, json). Default: txt"
        return 1
    fi
    
    local language="auto"
    local model="base"
    local output_dir="transcriptions"
    local format="txt"
    local files=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --language)
                language="$2"
                shift 2
                ;;
            --model)
                model="$2"
                shift 2
                ;;
            --output)
                output_dir="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --)
                shift
                files+=("$@")
                break
                ;;
            -*)
                echo "Unknown option: $1"
                return 1
                ;;
            *)
                files+=("$1")
                shift
                ;;
        esac
    done
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "Error: No files specified"
        return 1
    fi
    
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo "Error: ffmpeg not found. Please install ffmpeg."
        return 1
    fi
    
    if ! command -v whisper >/dev/null 2>&1 && ! python3 -c "import whisper" 2>/dev/null; then
        echo "Error: Whisper not found."
        echo "Please install Whisper:"
        echo "  pip install openai-whisper"
        echo "Or install whisper-ctranslate2:"
        echo "  pip install whisper-ctranslate2"
        return 1
    fi
    
    mkdir -p "$output_dir"
    
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            echo "File $file does not exist"
            continue
        fi
        
        echo "Processing: $file"
        
        local file_dir=$(dirname "$file")
        local file_basename=$(basename "$file" .mp4)
        local file_basename_no_ext="${file_basename%.*}"
        local temp_audio="${file_dir}/.${file_basename_no_ext}.wav"
        local output_file="${output_dir}/${file_basename_no_ext}.${format}"
        
        echo "  Extracting audio..."
        local error_output
        error_output=$(ffmpeg -i "$file" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$temp_audio" -y 2>&1)
        local ffmpeg_exit_code=$?
        
        if [ $ffmpeg_exit_code -ne 0 ] || [ ! -f "$temp_audio" ]; then
            echo "  Error: Failed to extract audio from $file"
            echo "$error_output" | tail -n 5
            continue
        fi
        
        echo "  Transcribing audio..."
        
        if command -v whisper >/dev/null 2>&1; then
            local whisper_cmd="whisper"
            if [ "$language" != "auto" ]; then
                whisper_cmd="$whisper_cmd --language $language"
            fi
            whisper_cmd="$whisper_cmd --model $model --output_format $format --output_dir $output_dir $temp_audio"
            
            if eval "$whisper_cmd" 2>&1; then
                if [ -f "${output_dir}/${file_basename_no_ext}.${format}" ]; then
                    echo "  Transcription saved to: ${output_dir}/${file_basename_no_ext}.${format}"
                fi
            else
                echo "  Error: Whisper transcription failed"
            fi
        elif python3 -c "import whisper" 2>/dev/null; then
            python3 -c "
import whisper
import sys
import os

model_name = '$model'
audio_file = '$temp_audio'
output_file = '$output_file'
language = '$language' if '$language' != 'auto' else None
output_format = '$format'

try:
    model = whisper.load_model(model_name)
    result = model.transcribe(audio_file, language=language)
    
    if output_format == 'txt':
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(result['text'])
    elif output_format == 'srt':
        with open(output_file, 'w', encoding='utf-8') as f:
            for i, segment in enumerate(result['segments'], 1):
                start = segment['start']
                end = segment['end']
                text = segment['text'].strip()
                f.write(f\"{i}\n\")
                f.write(f\"{int(start//3600):02d}:{int((start%3600)//60):02d}:{int(start%60):02d},{int((start%1)*1000):03d} --> {int(end//3600):02d}:{int((end%3600)//60):02d}:{int(end%60):02d},{int((end%1)*1000):03d}\n\")
                f.write(f\"{text}\n\n\")
    elif output_format == 'vtt':
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(\"WEBVTT\n\n\")
            for segment in result['segments']:
                start = segment['start']
                end = segment['end']
                text = segment['text'].strip()
                f.write(f\"{int(start//3600):02d}:{int((start%3600)//60):02d}:{int(start%60):02d}.{int((start%1)*1000):03d} --> {int(end//3600):02d}:{int((end%3600)//60):02d}:{int(end%60):02d}.{int((end%1)*1000):03d}\n\")
                f.write(f\"{text}\n\n\")
    elif output_format == 'json':
        import json
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
    
    print(f\"Transcription saved to: {output_file}\")
except Exception as e:
    print(f\"Error: {e}\", file=sys.stderr)
    sys.exit(1)
"
            if [ $? -ne 0 ]; then
                echo "  Error: Python Whisper transcription failed"
            fi
        fi
        
        rm -f "$temp_audio"
        echo "  Done: $file"
        echo ""
    done
}

show_whisper_models() 
{
    local cache_dir="${HOME}/.cache/whisper"
    
    echo "=== Whisper Model Storage Location ==="
    echo "Cache directory: $cache_dir"
    echo ""
    
    if [ ! -d "$cache_dir" ]; then
        echo "Cache directory does not exist yet."
        echo "Models will be downloaded here when first used."
        return 0
    fi
    
    echo "=== Downloaded Models ==="
    local model_count=0
    
    if [ -d "$cache_dir" ]; then
        for model_file in "$cache_dir"/*.pt "$cache_dir"/*.bin "$cache_dir"/*.ggml "$cache_dir"/*.pt.*; do
            if [ -f "$model_file" ] 2>/dev/null; then
                model_count=$((model_count + 1))
                local model_name=$(basename "$model_file")
                local model_size=$(du -h "$model_file" 2>/dev/null | cut -f1)
                echo "  $model_name ($model_size)"
            fi
        done 2>/dev/null
    fi
    
    if [ $model_count -eq 0 ]; then
        echo "  No models found in cache directory."
        echo "  Models will be automatically downloaded when first used."
    else
        echo ""
        echo "Total: $model_count model(s)"
    fi
    
    echo ""
    echo "=== Model Sizes Reference ==="
    echo "  tiny:   ~39 MB"
    echo "  base:   ~74 MB"
    echo "  small:  ~244 MB"
    echo "  medium: ~769 MB"
    echo "  large:  ~1550 MB"
    echo ""
    echo "To download a specific model manually:"
    echo "  python3 -c \"import whisper; whisper.load_model('base')\""
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
                parsed_output=$(echo "$json_output" | python3 <<'PYTHON_SCRIPT' 2>/dev/null
import json, sys
try:
    data = json.load(sys.stdin)
    format_info = data.get('format', {})
    print(f"Format name: {format_info.get('format_name', 'N/A')}")
    print(f"Format long name: {format_info.get('format_long_name', 'N/A')}")
    print(f"Duration: {format_info.get('duration', 'N/A')} seconds")
    print(f"Size: {format_info.get('size', 'N/A')} bytes")
    print(f"Bitrate: {format_info.get('bit_rate', 'N/A')} bps")
    print()
    
    tags = format_info.get('tags', {})
    if tags:
        print('--- Metadata Tags ---')
        for key, value in sorted(tags.items()):
            print(f"{key}: {value}")
        print()
    
    streams = data.get('streams', [])
    if streams:
        print('--- Stream Information ---')
        for i, stream in enumerate(streams):
            codec_type = stream.get('codec_type', 'unknown')
            codec_name = stream.get('codec_name', 'N/A')
            print(f"Stream #{i} ({codec_type}):")
            print(f"  Codec: {codec_name} ({stream.get('codec_long_name', 'N/A')})")
            if codec_type == 'video':
                print(f"  Resolution: {stream.get('width', 'N/A')}x{stream.get('height', 'N/A')}")
                print(f"  Frame rate: {stream.get('r_frame_rate', 'N/A')}")
                print(f"  Bitrate: {stream.get('bit_rate', 'N/A')} bps")
            elif codec_type == 'audio':
                print(f"  Sample rate: {stream.get('sample_rate', 'N/A')} Hz")
                print(f"  Channels: {stream.get('channels', 'N/A')}")
                print(f"  Bitrate: {stream.get('bit_rate', 'N/A')} bps")
            print()
except Exception as e:
    sys.exit(1)
PYTHON_SCRIPT
)
                
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
        COMPREPLY=($(compgen -W "delete_all_metadata modify_creation_time extract_speech show_whisper_models show_metadata" -- "$cur"))
    elif [ "$prev" = "extract_speech" ] || [[ "${COMP_WORDS[@]}" =~ --(language|model|output|format) ]]; then
        if [ "$prev" = "--language" ]; then
            COMPREPLY=($(compgen -W "auto zh en ja ko es fr de it pt ru ar hi" -- "$cur"))
        elif [ "$prev" = "--model" ]; then
            COMPREPLY=($(compgen -W "tiny base small medium large" -- "$cur"))
        elif [ "$prev" = "--format" ]; then
            COMPREPLY=($(compgen -W "txt srt vtt json" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "--language --model --output --format" -- "$cur"))
            COMPREPLY+=($(compgen -f -X '!*.mp4' -- "$cur"))
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
