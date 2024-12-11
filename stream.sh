#!/bin/bash

# @Description: sort video files and pass parameters to ffmpeg
# start_time, search
##

function show_usage (){
    printf "Usage: $0 [options [parameters]]\n"
    printf "\n"
    printf "Options:\n"
    printf " -s|--search [string], return items with string\n"
    printf " -t|--start_time, specify starting time\n"
    printf " -v|--volume, boost or reduce volume ie +10dB -10 dB \n"
    printf " -h|--help, Print help\n"

return 0
}

#if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]];then
#    show_usage
#else
#    echo "Incorrect input provided"
#    show_usage
#fi

optstring=":vts:"

while [ ! -z "$1" ]
do
    case "$1" in
        --volume|-v)
            shift
            echo "setting volume for $1"
            volume=$1
            ;;
        --start_time|-t)
            shift
            echo "start time set to: $1"
	        start_time=$1
            ;;
        --search|-s)
            shift
            echo "searching for: $1"
	        search=$1
            ;;
        :)
            ;;
        *)
            show_usage
            ;;
    esac
shift
done


echo "${start_time}"

if [ ! -n "$start_time" ]
then
        start_time="0:00:00"
        echo "Default: start time "$start_time""
fi

if [ ! -n "$search" ]
then
        search=""
        echo "Default: no search"
fi

if [ ! -n "$volume" ]
then
        volume="0"
        echo "Default: 0dB adjustment"
fi

echo "Enter the number of the file you want to play:  'quit' to exit"

PS3="Your choice: "
QUIT="QUIT THIS PROGRAM"
touch "$QUIT"
work_dir=${PWD}

#declare -a media_list=("")
#for entry in "$work_dir"/* "$work_dir"/**/* "$work_dir"/**/**/*
#do
#    if [[ "$entry" == *".mkv" ]] || [[ "$entry" == *".mp4" ]] || [[ "$entry" == *".avi" ]]
#    then
#        media_list+=("$entry")
##        echo "$entry"
#    fi
#done

#make a list of the media
declare -a media_list=("")
for entry in "$work_dir"/*
do
    if [[ "$entry" = *".mkv" ]] || [[ "$entry" = *".mp4" ]] || [[ "$entry" = *".avi" ]]
    then
        media_list+=("$entry")
        #echo "$entry"
    fi
    if [ -d "$entry" ]
    then
        for sub_entry in "$entry"/*
        do
#media types
            if [[ "$sub_entry" = *".mkv" ]] || [[ "$sub_entry" = *".mp4" ]] || [[ "$sub_entry" = *".avi" ]]
                then
                    media_list+=("$sub_entry")
                    #echo "$sub_entry"
            fi
        done
    fi
done

#compare list items for search terms
declare -a final_list=("")
for value in "${media_list[@]}"
do
    if [[ "${value,,}" == *"${search,,}"* ]]
    then
	    final_list+=("$value")
    else
	    continue
    fi
done

#echo $final_list

select FILENAME in ${final_list[@]} quit;
do
    case $FILENAME in
        quit)
          break
          return
          ;;
        *)
          rm "$QUIT"
          echo "You picked $FILENAME ($REPLY)"
          ffmpeg \
          -ss "$start_time" \
          -re \
          -i "$FILENAME" \
          -vcodec libx264 \
          -preset:v medium \
          -r 30 \
          -g 60 \
          -keyint_min 60 \
          -sc_threshold 0 \
          -b:v 2500k \
          -maxrate 2500k \
          -bufsize 2500k \
          -filter:a volume="$volume"dB \
          -f flv rtmp://localhost/live_stream
	      break
          ;;
    esac
done
