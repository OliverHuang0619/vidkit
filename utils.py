#!/usr/bin/env python3

import json
import sys
import argparse


def transcribe_audio(audio_file, output_file, model_name, language=None, output_format='txt'):
    """
    Transcribe audio file using Whisper model.
    
    Args:
        audio_file: Path to audio file
        output_file: Path to output file
        model_name: Whisper model name (tiny, base, small, medium, large)
        language: Language code (None for auto-detection)
        output_format: Output format (txt, srt, vtt, json)
    """
    try:
        import whisper
    except ImportError:
        print("Error: Whisper not found. Please install: pip install openai-whisper", file=sys.stderr)
        sys.exit(1)
    
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
                    f.write(f"{i}\n")
                    f.write(f"{int(start//3600):02d}:{int((start%3600)//60):02d}:{int(start%60):02d},{int((start%1)*1000):03d} --> {int(end//3600):02d}:{int((end%3600)//60):02d}:{int(end%60):02d},{int((end%1)*1000):03d}\n")
                    f.write(f"{text}\n\n")
        elif output_format == 'vtt':
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write("WEBVTT\n\n")
                for segment in result['segments']:
                    start = segment['start']
                    end = segment['end']
                    text = segment['text'].strip()
                    f.write(f"{int(start//3600):02d}:{int((start%3600)//60):02d}:{int(start%60):02d}.{int((start%1)*1000):03d} --> {int(end//3600):02d}:{int((end%3600)//60):02d}:{int(end%60):02d}.{int((end%1)*1000):03d}\n")
                    f.write(f"{text}\n\n")
        elif output_format == 'json':
            with open(output_file, 'w', encoding='utf-8') as f:
                json.dump(result, f, ensure_ascii=False, indent=2)
        
        print(f"Transcription saved to: {output_file}")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def parse_metadata_json(json_input):
    """
    Parse ffprobe JSON output and format it for display.
    
    Args:
        json_input: JSON string from ffprobe
        
    Returns:
        Formatted string with metadata information
    """
    try:
        data = json.loads(json_input)
        format_info = data.get('format', {})
        
        output_lines = []
        output_lines.append(f"Format name: {format_info.get('format_name', 'N/A')}")
        output_lines.append(f"Format long name: {format_info.get('format_long_name', 'N/A')}")
        output_lines.append(f"Duration: {format_info.get('duration', 'N/A')} seconds")
        output_lines.append(f"Size: {format_info.get('size', 'N/A')} bytes")
        output_lines.append(f"Bitrate: {format_info.get('bit_rate', 'N/A')} bps")
        output_lines.append("")
        
        tags = format_info.get('tags', {})
        if tags:
            output_lines.append('--- Metadata Tags ---')
            for key, value in sorted(tags.items()):
                output_lines.append(f"{key}: {value}")
            output_lines.append("")
        
        streams = data.get('streams', [])
        if streams:
            output_lines.append('--- Stream Information ---')
            for i, stream in enumerate(streams):
                codec_type = stream.get('codec_type', 'unknown')
                codec_name = stream.get('codec_name', 'N/A')
                output_lines.append(f"Stream #{i} ({codec_type}):")
                output_lines.append(f"  Codec: {codec_name} ({stream.get('codec_long_name', 'N/A')})")
                if codec_type == 'video':
                    output_lines.append(f"  Resolution: {stream.get('width', 'N/A')}x{stream.get('height', 'N/A')}")
                    output_lines.append(f"  Frame rate: {stream.get('r_frame_rate', 'N/A')}")
                    output_lines.append(f"  Bitrate: {stream.get('bit_rate', 'N/A')} bps")
                elif codec_type == 'audio':
                    output_lines.append(f"  Sample rate: {stream.get('sample_rate', 'N/A')} Hz")
                    output_lines.append(f"  Channels: {stream.get('channels', 'N/A')}")
                    output_lines.append(f"  Bitrate: {stream.get('bit_rate', 'N/A')} bps")
                output_lines.append("")
        
        return '\n'.join(output_lines)
    except Exception as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description='Video tools Python utilities')
    subparsers = parser.add_subparsers(dest='command', help='Command to execute')
    
    transcribe_parser = subparsers.add_parser('transcribe', help='Transcribe audio using Whisper')
    transcribe_parser.add_argument('audio_file', help='Path to audio file')
    transcribe_parser.add_argument('output_file', help='Path to output file')
    transcribe_parser.add_argument('--model', default='base', help='Whisper model name')
    transcribe_parser.add_argument('--language', default=None, help='Language code (None for auto)')
    transcribe_parser.add_argument('--format', default='txt', choices=['txt', 'srt', 'vtt', 'json'], help='Output format')
    
    parse_parser = subparsers.add_parser('parse-metadata', help='Parse ffprobe JSON metadata')
    parse_parser.add_argument('json_file', nargs='?', help='Path to JSON file (or read from stdin)')
    
    args = parser.parse_args()
    
    if args.command == 'transcribe':
        language = args.language if args.language and args.language != 'auto' else None
        transcribe_audio(args.audio_file, args.output_file, args.model, language, args.format)
    elif args.command == 'parse-metadata':
        if args.json_file:
            with open(args.json_file, 'r', encoding='utf-8') as f:
                json_input = f.read()
        else:
            json_input = sys.stdin.read()
        result = parse_metadata_json(json_input)
        print(result)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()

