#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")
PYTHON_SCRIPT="${SCRIPT_DIR}/utils.py"

if [ ! -f "${PYTHON_SCRIPT}" ]; then
    PYTHON_SCRIPT="utils.py"
fi

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

extract_audio() 
{
    if [ $# -eq 0 ]; then
        echo "Usage: extract_audio [options] file1 [file2 ...]"
        echo "  options:"
        echo "    --output DIR       Output directory for audio files. Default: same as input file directory"
        echo "    --output-file FILE Output file path (overrides --output and --format)"
        echo "    --format FORMAT   Audio format (wav, mp3, aac). Default: wav"
        return 1
    fi
    
    local output_dir=""
    local output_file=""
    local format="wav"
    local files=()
    local silent_mode=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output)
                output_dir="$2"
                shift 2
                ;;
            --output-file)
                output_file="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --silent)
                silent_mode=1
                shift
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
    
    if [ -n "$output_file" ] && [ ${#files[@]} -gt 1 ]; then
        echo "Error: --output-file can only be used with a single input file"
        return 1
    fi
    
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo "Error: ffmpeg not found. Please install ffmpeg."
        return 1
    fi
    
    local success_count=0
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            [ $silent_mode -eq 0 ] && echo "File $file does not exist"
            [ $silent_mode -eq 1 ] && return 1
            continue
        fi
        
        local file_dir=$(dirname "$file")
        local file_basename=$(basename "$file")
        local file_basename_no_ext="${file_basename%.*}"
        
        local output_audio=""
        local actual_format="$format"
        if [ -n "$output_file" ]; then
            output_audio="$output_file"
            mkdir -p "$(dirname "$output_audio")"
            if [[ "$output_audio" == *.wav ]]; then
                actual_format="wav"
            elif [[ "$output_audio" == *.mp3 ]]; then
                actual_format="mp3"
            elif [[ "$output_audio" == *.aac ]]; then
                actual_format="aac"
            fi
        else
            if [ -z "$output_dir" ]; then
                output_dir="$file_dir"
            fi
            mkdir -p "$output_dir"
            output_audio="${output_dir}/${file_basename_no_ext}.${format}"
        fi
        
        [ $silent_mode -eq 0 ] && echo "Extracting audio from: $file"
        
        local error_output
        if [ "$actual_format" = "wav" ] || [[ "$output_audio" == *.wav ]]; then
            error_output=$(ffmpeg -i "$file" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$output_audio" -y 2>&1)
        elif [ "$actual_format" = "mp3" ] || [[ "$output_audio" == *.mp3 ]]; then
            error_output=$(ffmpeg -i "$file" -vn -acodec libmp3lame -ar 44100 -ac 2 -b:a 192k "$output_audio" -y 2>&1)
        elif [ "$actual_format" = "aac" ] || [[ "$output_audio" == *.aac ]]; then
            error_output=$(ffmpeg -i "$file" -vn -acodec aac -ar 44100 -ac 2 -b:a 192k "$output_audio" -y 2>&1)
        else
            [ $silent_mode -eq 0 ] && echo "Error: Unsupported format: $actual_format"
            continue
        fi
        
        local ffmpeg_exit_code=$?
        
        if [ $ffmpeg_exit_code -eq 0 ] && [ -f "$output_audio" ] && [ -s "$output_audio" ]; then
            [ $silent_mode -eq 0 ] && echo "Audio extracted to: $output_audio"
            success_count=$((success_count + 1))
        else
            [ $silent_mode -eq 0 ] && echo "Error: Failed to extract audio from $file"
            if [ $silent_mode -eq 0 ]; then
                echo "$error_output" | tail -n 5
            else
                echo "$error_output" | tail -n 5 >&2
            fi
            [ -f "$output_audio" ] && rm -f "$output_audio"
            if [ $silent_mode -eq 1 ]; then
                return 1
            fi
        fi
        [ $silent_mode -eq 0 ] && echo ""
    done
    
    if [ $success_count -eq 0 ] && [ ${#files[@]} -gt 0 ]; then
        return 1
    fi
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
        local extract_output
        extract_output=$(extract_audio "$file" --output-file "$temp_audio" --format wav --silent 2>&1)
        local extract_exit_code=$?
        
        if [ $extract_exit_code -ne 0 ] || [ ! -f "$temp_audio" ] || [ ! -s "$temp_audio" ]; then
            echo "  Error: Failed to extract audio from $file"
            if [ -n "$extract_output" ]; then
                echo "  Details: $extract_output" | tail -n 3
            fi
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
            local cmd_args=("${PYTHON_SCRIPT}" "transcribe" "$temp_audio" "$output_file" "--model" "$model")
            if [ "$language" != "auto" ]; then
                cmd_args+=("--language" "$language")
            fi
            cmd_args+=("--format" "$format")
            
            if python3 "${cmd_args[@]}" 2>&1; then
                if [ -f "$output_file" ]; then
                    echo "  Transcription saved to: $output_file"
                fi
            else
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
                parsed_output=$(echo "$json_output" | python3 "${PYTHON_SCRIPT}" parse-metadata 2>/dev/null)
                
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

_vidkit_complete()
{
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [ $COMP_CWORD -eq 1 ]; then
        COMPREPLY=($(compgen -W "delete_all_metadata modify_creation_time extract_audio extract_speech show_whisper_models show_metadata" -- "$cur"))
    elif [ "$prev" = "extract_audio" ] || [[ "${COMP_WORDS[@]}" =~ extract_audio.*--(output|format|output-file) ]]; then
        if [ "$prev" = "--format" ]; then
            COMPREPLY=($(compgen -W "wav mp3 aac" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "--output --output-file --format" -- "$cur"))
            COMPREPLY+=($(compgen -f -X '!*.mp4' -- "$cur"))
        fi
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
    complete -F _vidkit_complete vidkit.sh
    complete -F _vidkit_complete ./vidkit.sh
    return 0
fi

$1 "${@:2}"
