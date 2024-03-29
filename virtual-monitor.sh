#!/bin/bash

AVAILABLE_METHODS="{install|host|check|start|stop|help}"
my_hostname='virtual.monitor'

install_dependencies() {
    echo "Installing dependencies..."
    install_needed=0
    if ! command -v avahi-daemon &> /dev/null; then
        install_needed=1
    fi
    if ! command -v x11vnc &> /dev/null; then
        install_needed=2
    fi
    if ! command -v pulseaudio &> /dev/null; then
        install_needed=3
    fi
    if ! command -v ffmpeg &> /dev/null; then
        install_needed=4
    fi
    if ! command -v nginx &> /dev/null; then
        install_needed=5
    fi

    command -v git > /dev/null 2>&1 && git update-index --skip-worktree ./tmp/ffmpeg.log
    package_manager=""

    if command -v apt &> /dev/null; then
        package_manager="apt"
    elif command -v apt-get &> /dev/null; then
        package_manager="apt-get"
    elif [ $install_needed -lt 1 ]; then
        package_manager="none"
    else
        error_package
    fi

    if [ $package_manager != "none" ] && [ $install_needed -gt 0 ]; then
      echo "Updating packages lists..."
      sudo bash -c "$package_manager update"
      echo "Installing $install_needed packages..."
    fi

    if [ $install_needed -gt 0 ]; then
      install_package avahi-daemon $package_manager
      install_package x11vnc $package_manager
      install_package pulseaudio $package_manager
      install_package ffmpeg $package_manager
      install_package nginx $package_manager
    fi

    set_hostname
}

set_hostname() {
    echo "Setting hostname..."
    hostname_controller=""
    current_hostname="$my_hostname"
    if command -v hostnamectl &> /dev/null; then
        hostname_controller="hostnamectl"
        current_hostname=$(hostnamectl --static)
    elif [ -f /etc/hostname ]; then
        hostname_controller="hostname"
        current_hostname=$(cat /etc/hostname)
    else
        current_hostname="localhost"
        error_host
    fi

    echo "Current hostname is set as $current_hostname"

    if [ "$current_hostname" == "localhost" ]; then
        echo "Changing hostname to $my_hostname"
        if [ "$hostname_controller" == "hostnamectl" ]; then
          sudo hostnamectl set-hostname "$my_hostname"
          sudo systemctl restart avahi-daemon
        elif [ "$hostname_controller" == "hostname" ]; then
          sudo hostname "$my_hostname"
          sudo systemctl restart avahi-daemon
        else
          error_host
        fi
    else
        my_hostname="$current_hostname"
    fi

    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    update_site "$base_dir" $my_hostname
    update_conf "$base_dir" $my_hostname

    echo "Installation finished. Your hostname is $my_hostname"
}

update_site() {
    echo "Updating Web Resources..."

    html_msg=$(<"$1/templates/html.template")
    html_msg=${html_msg//my_hostname_placeholder/$2}
    html_dir="$1/tmp/html"
    html_path="$html_dir/index.html"
    sudo rm -r -f "$html_dir"
    mkdir "$html_dir"
    sudo chmod 1777 "$html_dir"
    echo "$html_msg" | sudo tee "$html_path" > /dev/null 2>&1

    diff_result=$(diff -B <(echo "$html_msg") <(cat "$html_path") 2>&1)
    if [ -z "$diff_result" ]; then
        echo "Wrote index page to $html_path"
    else
        echo "Could not write to $html_path"
        exit 1
    fi
}

update_conf() {
    echo "Updating Server Configuration..."
    nginx_msg=$(<"$1/templates/conf.template")
    nginx_msg=${nginx_msg//my_basedir_placeholder/$1}
    nginx_base="/etc/nginx"
    nginx_available="$nginx_base/sites-available"
    nginx_enabled="$nginx_base/sites-enabled"

    sudo rm -f "$nginx_available/$2"
    sudo rm -f "$nginx_available/default"
    sudo rm -f "$nginx_enabled/default"

    echo "$nginx_msg" | sudo tee "$nginx_available/$2" > /dev/null 2>&1

    diff_result=$(diff -B <(echo "$nginx_msg") <(cat "$nginx_available/$2") 2>&1)
    if [ -z "$diff_result" ]; then
        echo "Wrote nginx config to $nginx_available/$2"
    else
        echo "Could not write to $nginx_available/$2"
        exit 1
    fi

    sudo rm -f "$nginx_enabled/$2"
    sudo ln -s "$nginx_available/$2" "$nginx_enabled/"

    if command -v nginx &> /dev/null; then
        sudo systemctl restart nginx
    fi
}

start_stream() {
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    video_dir="$base_dir/tmp/video"
    sudo rm -r -f "$video_dir"
    mkdir "$video_dir"
    sudo chmod 1777 "$video_dir"
    current_hostname=$my_hostname
    if command -v hostnamectl &> /dev/null; then
        hostname_controller="hostnamectl"
        current_hostname=$(hostnamectl --static)
    elif [ -f /etc/hostname ]; then
        hostname_controller="hostname"
        current_hostname=$(cat /etc/hostname)
    else
        current_hostname="localhost"
        error_host
    fi
    primary=$(xrandr | awk '/ connected primary/, EOF' | grep -v ' connected \(primary\| disconnected\)' | grep '[0-9]\*')
    screen_resolution=$(echo "$primary" | awk '{print $1}')
    frame_rate=$(echo "$primary" | awk '{print $2}' | sed 's/\*//')
    monitor=0
    sound=0
    logging=1

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -s|--sound)
                sound=1
                shift
                ;;
            -l|--logging)
                logging=1
                shift
                ;;
            -m|--mirror)
                monitor=1
                shift
                ;;
            -e|--extend)
                monitor=2
                monitor=1
                shift
                ;;
            -r|--resolution)
                if [ "$monitor" == 2 ]; then
                    echo "Mirroring is not supported with custom resolution."
                    exit 1
                fi
                screen_resolution=$2
                shift
                ;;
            -f|--frame-rate)
                if [ "$monitor" == 2 ]; then
                    echo "Mirroring is not supported with custom frame rate."
                    exit 1
                fi
                frame_rate=$2
                shift
                ;;
            *)
                echo "Starting with default options."
                monitor=1
                ;;
        esac
        shift
    done

    echo "Starting x11vnc..."
    start_x11vnc "$monitor" "$screen_resolution"

    echo "Starting FFmpeg..."
    start_ffmpeg "$screen_resolution" "$frame_rate" "$base_dir" "$sound" "$logging"

    sleep 5
    if pgrep -f "ffmpeg.*stream.m3u8" >/dev/null; then
        echo "Streaming is now available at http://$current_hostname:8080/ or http://<ip-address>:8080/ (or any individual name you might have set)."
    elif [ "$logging" == 1 ]; then
        echo "Failed to start the stream. Check $base_dir/tmp/ffmpeg.log for details."
        exit 1
    else
        echo "Failed to start the stream."
        exit 1
    fi
}

start_x11vnc() {
    if [ "$1" == 1 ]; then
        x11vnc -clip "$2" -display :0 -nopw -xkb -noxrecord -noxfixes -noxdamage -forever &
    else
        x11vnc -display :0 -nopw -xkb -noxrecord -noxfixes -noxdamage -forever &
    fi

    x11vnc_pid=$!
    trap 'kill $x11vnc_pid' EXIT

    x11vnc_status=$?
    if [ $x11vnc_status -eq 0 ]; then
        echo "x11vnc started successfully with PID $x11vnc_pid. Waiting for FFmpeg to start..."
    else
        echo "Failed to start x11vnc. Exiting."
        exit 1
    fi

    sleep 5
}

start_ffmpeg() {
    video_source="-f x11grab"
    video_input="-i :0.0+0,0"
    video_dimensions="-s $1"
    frame_rate="-r $2"
    probe_size="-probesize 200M"
    video_codec="-c:v libx264"
    #sound_source_pulse="-f pulse -ac 2"
    #sound_input_pulse="-i default"
    sound_source_alsa="-f alsa -ac 2"
    sound_input_alsa="-i hw:0"
    sound_codec="-c:a aac -strict experimental"
    encoding_settings="-preset ultrafast -tune zerolatency"
    #hls_settings="-hls_time 2 -hls_wrap 5 -start_number 0"
    hls_settings="-f hls -hls_time 5 -hls_list_size 2 -hls_flags delete_segments"
    stream_target="$3/tmp/video/stream.m3u8"
    #log_level="-loglevel verbose"
    log_file="$3/tmp/ffmpeg.log"

    ffmpeg_cmd="ffmpeg"
    #ffmpeg_cmd="$ffmpeg_cmd $log_level"
    #video_cmd="$video_dimensions $frame_rate $video_source $video_input $probe_size $video_codec"
    #video_cmd="$video_dimensions $frame_rate $video_source $video_input"
    ffmpeg_cmd="$ffmpeg_cmd $video_dimensions $frame_rate $video_source $probe_size $video_input $video_codec"
    #sound_cmd="$sound_source $sound_input $sound_codec $encoding_settings"
    #sound_cmd="$sound_source_alsa $sound_input_alsa"
    if [ "$4" == 1 ]; then
        ffmpeg_cmd="$ffmpeg_cmd $sound_source_alsa $sound_input_alsa"
    fi
    ffmpeg_cmd="$ffmpeg_cmd $encoding_settings $sound_codec"
    #stream_cmd="$hls_settings $stream_target"
    ffmpeg_cmd="$ffmpeg_cmd $hls_settings $stream_target"

    #ffmpeg_cmd="ffmpeg $log_level $video_cmd $sound_cmd $encoding_settings $stream_cmd > $log_file 2>&1 &"
    if  [ "$5" == 1 ]; then
        echo "Executing $ffmpeg_cmd."
        ffmpeg_cmd="$ffmpeg_cmd > $log_file 2>&1 &"
    else
        ffmpeg_cmd="$ffmpeg_cmd > /dev/null 2>&1 &"
    fi

    sudo bash -c "$ffmpeg_cmd"
    ffmpeg_pid=$!
    trap 'kill $ffmpeg_pid' EXIT

    ffmpeg_status=$?
    if [ $ffmpeg_status -eq 0 ]; then
        echo "FFmpeg started successfully with PID $ffmpeg_pid."
    else
        echo "Failed to start FFmpeg. Exiting."
        exit 1
    fi

    sleep 5
}

stop_stream() {
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "Stopping stream..."
    pkill x11vnc
    pkill ffmpeg

    sleep 5
    sudo rm -r "$base_dir/tmp/video"
    echo "Streaming stopped."
}

check_dependencies() {
    if ! command -v avahi-daemon &> /dev/null; then
        error_install "Avahi"
    elif ! command -v x11vnc &> /dev/null; then
        error_install "x11vnc"
    elif ! command -v pulseaudio &> /dev/null; then
        error_install "pulseaudio"
    elif ! command -v ffmpeg &> /dev/null; then
        error_install "FFmpeg"
    elif ! command -v nginx &> /dev/null; then
        error_install "Nginx"
    fi

    current_hostname="localhost"
    if command -v hostnamectl &> /dev/null; then
        current_hostname=$(hostnamectl --static)
    elif [ -f /etc/hostname ]; then
        current_hostname=$(cat /etc/hostname)
    else
        error_host
    fi

    if [ "$current_hostname" == "" ] || [ "$current_hostname" == "localhost" ]; then
        echo "Hostname is not set. Please run 'sudo $0 host (<name>)' first."
    else
        echo "All necessary packages are installed, hostname was set to $current_hostname."
    fi
}

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "This command must be run with sudo. Please use 'sudo $0 $1' instead."
        exit 1
    fi
}

install_package() {
        package=$1
        if ! command -v "$package" &> /dev/null; then
            echo "$package is not installed. Installing..."
            if [ "$2" == "apt" ]; then
                sudo apt install -y "$package" > /dev/null
            elif [ "$2" == "apt-get" ]; then
                sudo apt-get install -y "$package" > /dev/null
            else
                error_package
            fi
        fi
    }

help() {
    echo "Usage: $0 $AVAILABLE_METHODS"
    echo "  install        Install dependencies and set up the virtual monitor."
    echo "  host (<name>)  Set the hostname, default is your machine's name or virtual.monitor."
    echo "  check          Check if all dependencies are set up."
    echo "  start          Start the virtual monitor stream. By default as --mirror, all arguments are optional."
    echo "  start  (-l | --logging)  Start the virtual monitor stream with logging enabled (by default off)."
    echo "  start  (-s | --sound)  Start the virtual monitor stream with sound (by default off)."
    echo "  start  (-m | --mirror)  Start the virtual monitor stream as mirror with same resolution and frame rate."
    echo "  start  (-e | --extend)  Start the virtual monitor stream as extension of main display with same resolution and frame rate."
    echo "  start  -e (-r | --resolution)  Start the virtual monitor stream as extension with specific resolution."
    echo "  start  -e (-f | --frame-rate)  Start the virtual monitor stream as extension with specific frame rate."
    echo "  stop           Stop the virtual monitor stream."
    echo "  help           Display this help message."
}

error_install() {
    echo "$1 is not installed. Please run 'sudo $0 install' first."
    exit 1
}

error_package() {
    echo "Neither 'apt' nor 'apt-get' commands found. Please install a package manager on your system."
    exit 1
}

error_host() {
    echo "Please check your system configuration for the presence of 'hostnamectl' or '/etc/hostname'."
    echo "If neither is available, you may need to set the hostname manually somehow."
    echo "Meanwhile, you can still access the stream via 'http://<this machine's ip address>:8080'."
}

case "$1" in
    install)
        check_sudo "install"
        install_dependencies
        ;;
    host)
        check_sudo "host"
        my_hostname="${2:$my_hostname}"
        set_hostname
        ;;
    check)
        check_dependencies
        ;;
    start)
        check_sudo "start"
        start_stream "$@"
        ;;
    stop)
        check_sudo "stop"
        stop_stream
        ;;
    help)
        help
        ;;
    *)
        echo "Usage: $0 $AVAILABLE_METHODS"
        exit 1
        ;;
esac

exit 0
